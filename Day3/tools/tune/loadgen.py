#!/usr/bin/env python3
"""Bounded local HTTP measurement process used by tools/tune.ps1.

This module only schedules HTTP requests and writes JSON evidence. It never
reads Kubernetes state and never calculates tuning values.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import signal
import sys
import time
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import aiohttp

HARD_MAX_WORKERS = 64
HARD_MAX_CONNECTIONS = 96
HARD_MAX_QUEUE = 256
HARD_MAX_SCHEDULED = 250_000
DEFAULT_TIMEOUT = 5.0


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * quantile
    low = math.floor(index)
    high = math.ceil(index)
    if low == high:
        return round(ordered[low], 3)
    return round(ordered[low] + (ordered[high] - ordered[low]) * (index - low), 3)


def new_bucket() -> dict[str, Any]:
    return {
        "requests": 0,
        "sent": 0,
        "completed": 0,
        "success": 0,
        "slo_success": 0,
        "failed": 0,
        "timeouts": 0,
        "dropped": 0,
        "latencies": [],
        "failure_codes": Counter(),
    }


@dataclass(slots=True)
class RequestItem:
    app: str
    phase_index: int
    spec: dict[str, Any]


class Metrics:
    def __init__(self, apps: list[str], phase_count: int) -> None:
        self.scheduled = 0
        self.sent = 0
        self.completed = 0
        self.success = 0
        self.slo_success = 0
        self.failed = 0
        self.timeouts = 0
        self.dropped = 0
        self.active = 0
        self.max_active = 0
        self.scheduler_lag_events = 0
        self.max_scheduler_lag_ms = 0.0
        self.concurrency_ceiling_hits = 0
        self.failure_codes: Counter[str] = Counter()
        self.latencies: list[float] = []
        self.apps = {name: new_bucket() for name in apps}
        self.phases = [{name: new_bucket() for name in apps} for _ in range(phase_count)]
        self._lock = asyncio.Lock()

    def _buckets(self, app: str, phase_index: int) -> tuple[dict[str, Any], dict[str, Any]]:
        return self.apps[app], self.phases[phase_index][app]

    async def scheduled_one(self, app: str, phase_index: int) -> None:
        async with self._lock:
            self.scheduled += 1
            for bucket in self._buckets(app, phase_index):
                bucket["requests"] += 1

    async def dropped_one(self, app: str, phase_index: int) -> None:
        async with self._lock:
            self.dropped += 1
            for bucket in self._buckets(app, phase_index):
                bucket["dropped"] += 1

    async def note_scheduler_lag(self, lag_seconds: float) -> None:
        async with self._lock:
            lag_ms = max(0.0, lag_seconds * 1000.0)
            self.max_scheduler_lag_ms = max(self.max_scheduler_lag_ms, lag_ms)
            if lag_ms > 250.0:
                self.scheduler_lag_events += 1

    async def sent_one(self, app: str, phase_index: int, worker_limit: int) -> None:
        async with self._lock:
            self.sent += 1
            self.active += 1
            self.max_active = max(self.max_active, self.active)
            if self.active >= worker_limit:
                self.concurrency_ceiling_hits += 1
            for bucket in self._buckets(app, phase_index):
                bucket["sent"] += 1

    async def completed_one(
        self,
        app: str,
        phase_index: int,
        latency_ms: float,
        status: int | None,
        timed_out: bool,
        expected_status: int,
        slo_ms: float,
    ) -> None:
        async with self._lock:
            self.completed += 1
            self.active = max(0, self.active - 1)
            self.latencies.append(latency_ms)
            buckets = self._buckets(app, phase_index)
            for bucket in buckets:
                bucket["completed"] += 1
                bucket["latencies"].append(latency_ms)
            if timed_out:
                self.timeouts += 1
                self.failed += 1
                self.failure_codes["timeout"] += 1
                for bucket in buckets:
                    bucket["timeouts"] += 1
                    bucket["failed"] += 1
                    bucket["failure_codes"]["timeout"] += 1
                return
            if status == expected_status:
                self.success += 1
                for bucket in buckets:
                    bucket["success"] += 1
                if latency_ms <= slo_ms:
                    self.slo_success += 1
                    for bucket in buckets:
                        bucket["slo_success"] += 1
                return
            self.failed += 1
            code = str(status if status is not None else "connection_error")
            self.failure_codes[code] += 1
            for bucket in buckets:
                bucket["failed"] += 1
                bucket["failure_codes"][code] += 1

    @staticmethod
    def latency_summary(values: list[float]) -> dict[str, float | None]:
        return {
            "avg": round(sum(values) / len(values), 3) if values else None,
            "p50": percentile(values, 0.50),
            "p90": percentile(values, 0.90),
            "p95": percentile(values, 0.95),
            "p99": percentile(values, 0.99),
            "max": round(max(values), 3) if values else None,
        }

    @classmethod
    def bucket_snapshot(cls, bucket: dict[str, Any]) -> dict[str, Any]:
        requests = int(bucket["requests"])
        return {
            "requests": requests,
            "sent": int(bucket["sent"]),
            "completed": int(bucket["completed"]),
            "success": int(bucket["success"]),
            "slo_success": int(bucket["slo_success"]),
            "failed": int(bucket["failed"]),
            "timeouts": int(bucket["timeouts"]),
            "dropped": int(bucket["dropped"]),
            "success_rate": round(100.0 * bucket["success"] / requests, 3) if requests else 0.0,
            "slo_success_rate": round(100.0 * bucket["slo_success"] / requests, 3) if requests else 0.0,
            "timeout_rate": round(100.0 * bucket["timeouts"] / requests, 3) if requests else 0.0,
            "latency_ms": cls.latency_summary(bucket["latencies"]),
            "failure_codes": dict(bucket["failure_codes"]),
        }

    async def snapshot(self, phase_specs: list[dict[str, Any]]) -> dict[str, Any]:
        async with self._lock:
            phases = []
            for index, phase in enumerate(phase_specs):
                phases.append({
                    "index": index,
                    "kind": str(phase.get("kind", "load")),
                    "start_rps": float(phase.get("start_rps", phase.get("rps", 0.0))),
                    "target_rps": float(phase.get("rps", 0.0)),
                    "duration_sec": float(phase["duration_sec"]),
                    "apps": {name: self.bucket_snapshot(value) for name, value in self.phases[index].items()},
                })
            return {
                "scheduled": self.scheduled,
                "sent": self.sent,
                "completed": self.completed,
                "success": self.success,
                "slo_success": self.slo_success,
                "failed": self.failed,
                "timeouts": self.timeouts,
                "dropped": self.dropped,
                "latency_ms": self.latency_summary(self.latencies),
                "apps": {name: self.bucket_snapshot(value) for name, value in self.apps.items()},
                "phases": phases,
                "failure_codes": dict(self.failure_codes),
                "scheduler_lag_events": self.scheduler_lag_events,
                "max_scheduler_lag_ms": round(self.max_scheduler_lag_ms, 3),
                "concurrency_ceiling_hits": self.concurrency_ceiling_hits,
                "max_active": self.max_active,
            }


def build_request(spec: dict[str, Any]) -> tuple[str, str, dict[str, str], str | None]:
    method = str(spec.get("method", "GET")).upper()
    path = str(spec["path"])
    headers = {str(key): str(value) for key, value in spec.get("headers", {}).items()}
    body = spec.get("body")
    body_text = json.dumps(body, separators=(",", ":")) if body is not None else None
    return method, path, headers, body_text


async def worker(
    queue: asyncio.Queue[RequestItem | None],
    session: aiohttp.ClientSession,
    metrics: Metrics,
    base_url: str,
    semaphore: asyncio.Semaphore,
    worker_limit: int,
) -> None:
    while True:
        item = await queue.get()
        try:
            if item is None:
                return
            method, path, headers, body = build_request(item.spec)
            started = time.perf_counter()
            status: int | None = None
            timed_out = False
            async with semaphore:
                await metrics.sent_one(item.app, item.phase_index, worker_limit)
                try:
                    async with session.request(method, f"{base_url}{path}", headers=headers, data=body) as response:
                        status = response.status
                        await response.read()
                except asyncio.TimeoutError:
                    timed_out = True
                except (aiohttp.ClientError, OSError):
                    status = None
            await metrics.completed_one(
                item.app,
                item.phase_index,
                (time.perf_counter() - started) * 1000.0,
                status,
                timed_out,
                int(item.spec.get("expected_status", 200)),
                float(item.spec.get("slo_ms", 1000.0)),
            )
        finally:
            queue.task_done()


async def scheduler(
    app: str,
    phase_index: int,
    spec: dict[str, Any],
    start_rate: float,
    end_rate: float,
    duration: float,
    queue: asyncio.Queue[RequestItem | None],
    metrics: Metrics,
    stop_event: asyncio.Event,
) -> None:
    if max(start_rate, end_rate) <= 0 or duration <= 0:
        await asyncio.sleep(max(0.0, duration))
        return
    phase_start = time.perf_counter()
    next_send = phase_start
    end = phase_start + duration
    while not stop_event.is_set() and time.perf_counter() < end:
        now = time.perf_counter()
        if now < next_send:
            await asyncio.sleep(min(next_send - now, 0.05))
            continue
        progress = min(1.0, max(0.0, (now - phase_start) / duration))
        current_rate = start_rate + (end_rate - start_rate) * progress
        interval = 1.0 / max(0.001, current_rate)
        lag = now - next_send
        await metrics.note_scheduler_lag(lag)
        missed = max(0, int(lag / interval))
        due = 1 + min(missed, 2)
        for _ in range(due):
            await metrics.scheduled_one(app, phase_index)
            try:
                queue.put_nowait(RequestItem(app, phase_index, spec))
            except asyncio.QueueFull:
                await metrics.dropped_one(app, phase_index)
            next_send += interval
        if missed > 2:
            skipped = missed - 2
            for _ in range(skipped):
                await metrics.scheduled_one(app, phase_index)
                await metrics.dropped_one(app, phase_index)
                next_send += interval


def bounded_int(value: Any, default: int, minimum: int, maximum: int) -> int:
    parsed = default if value is None else int(value)
    return max(minimum, min(maximum, parsed))


async def run(config: dict[str, Any]) -> dict[str, Any]:
    started_at = now_iso()
    base_url = str(config["endpoint"]).rstrip("/")
    profile = str(config["profile"])
    phases = list(config["phases"])
    app_specs = dict(config["apps"])
    if not phases or not app_specs:
        raise ValueError("phases and apps are required")
    estimated = sum(float(phase.get("rps", 0.0)) * float(phase["duration_sec"]) for phase in phases)
    if estimated > HARD_MAX_SCHEDULED:
        raise ValueError(f"scheduled request safety cap exceeded: {estimated}>{HARD_MAX_SCHEDULED}")

    safety = dict(config.get("safety", {}))
    worker_cap = bounded_int(safety.get("workers"), HARD_MAX_WORKERS, 1, HARD_MAX_WORKERS)
    connection_cap = bounded_int(safety.get("connections"), HARD_MAX_CONNECTIONS, 1, HARD_MAX_CONNECTIONS)
    queue_cap = bounded_int(safety.get("queue"), HARD_MAX_QUEUE, 1, HARD_MAX_QUEUE)
    timeout = float(config.get("timeout_sec", DEFAULT_TIMEOUT))
    peak_rps = max(float(phase.get("rps", 0.0)) for phase in phases)
    workers = min(worker_cap, max(4 if worker_cap >= 4 else 1, math.ceil(max(1.0, peak_rps * timeout * 1.25))))
    connections = min(connection_cap, max(1, workers * 2))
    queue_size = min(queue_cap, max(8 if queue_cap >= 8 else 1, workers * 3))

    metrics = Metrics(list(app_specs), len(phases))
    queue: asyncio.Queue[RequestItem | None] = asyncio.Queue(maxsize=queue_size)
    semaphore = asyncio.Semaphore(workers)
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    interrupted = False

    def request_stop() -> None:
        nonlocal interrupted
        interrupted = True
        stop_event.set()

    for sig in (getattr(signal, "SIGINT", None), getattr(signal, "SIGTERM", None)):
        if sig is not None:
            try:
                loop.add_signal_handler(sig, request_stop)
            except (NotImplementedError, RuntimeError):
                pass

    connector = aiohttp.TCPConnector(
        limit=connections,
        limit_per_host=connections,
        ttl_dns_cache=300,
        keepalive_timeout=30,
        enable_cleanup_closed=True,
    )
    timeout_obj = aiohttp.ClientTimeout(total=timeout)
    workers_tasks: list[asyncio.Task[Any]] = []
    scheduler_tasks: list[asyncio.Task[Any]] = []
    async with aiohttp.ClientSession(timeout=timeout_obj, connector=connector, raise_for_status=False) as session:
        workers_tasks = [
            asyncio.create_task(worker(queue, session, metrics, base_url, semaphore, workers))
            for _ in range(workers)
        ]
        try:
            for phase_index, phase in enumerate(phases):
                if stop_event.is_set():
                    break
                duration = float(phase["duration_sec"])
                target_rps = float(phase.get("rps", 0.0))
                scheduler_tasks = [
                    asyncio.create_task(
                        scheduler(
                            app,
                            phase_index,
                            spec,
                            float(phase.get("start_rps", target_rps)) * float(spec.get("share", 0.0)),
                            target_rps * float(spec.get("share", 0.0)),
                            duration,
                            queue,
                            metrics,
                            stop_event,
                        )
                    )
                    for app, spec in app_specs.items()
                ]
                await asyncio.gather(*scheduler_tasks)
                scheduler_tasks.clear()
        finally:
            for task in scheduler_tasks:
                task.cancel()
            if scheduler_tasks:
                await asyncio.gather(*scheduler_tasks, return_exceptions=True)
            stop_event.set()
            await queue.join()
            for _ in workers_tasks:
                await queue.put(None)
            await asyncio.gather(*workers_tasks, return_exceptions=True)

    result = await metrics.snapshot(phases)
    reasons: list[str] = []
    if result["dropped"] > 0:
        reasons.append("QUEUE_FULL")
    if result["scheduler_lag_events"] >= max(3, len(phases)):
        reasons.append("SCHEDULER_LAG")
    if result["concurrency_ceiling_hits"] > 0 and result["sent"] < result["scheduled"]:
        reasons.append("CONCURRENCY_CEILING")
    result.update({
        "profile": profile,
        "started_at": started_at,
        "ended_at": now_iso(),
        "duration_sec": sum(float(phase["duration_sec"]) for phase in phases),
        "peak_target_rps": peak_rps,
        "workers": workers,
        "connections": connections,
        "queue_max": queue_size,
        "max_outstanding": workers,
        "generator_limited": bool(reasons),
        "generator_limit_reason": ",".join(reasons) if reasons else None,
        "stopped_by_signal": interrupted,
    })
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    parser.add_argument("--output")
    parser.add_argument("--version-check", action="store_true")
    return parser.parse_args()


def write_result(path: str, result: dict[str, Any]) -> None:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(output)


def main() -> int:
    args = parse_args()
    if args.version_check:
        print(sys.version.split()[0])
        return 0 if sys.version_info[:2] == (3, 14) else 2
    if not args.config or not args.output:
        print("--config and --output are required", file=sys.stderr)
        return 2
    try:
        config = json.loads(Path(args.config).read_text(encoding="utf-8-sig"))
        write_result(args.output, asyncio.run(run(config)))
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        write_result(args.output, {
            "profile": "unknown",
            "generator_limited": True,
            "generator_limit_reason": "LOADGEN_ERROR",
            "error": str(exc),
        })
        print(f"loadgen error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
