import asyncio
import json
import sys
import tempfile
import unittest
from pathlib import Path

from aiohttp import web

ROOT = Path(__file__).resolve().parent
LOADGEN = ROOT / "loadgen.py"


class LoadgenTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        async def ok(_request):
            return web.Response(status=200, text="ok")

        async def failure(_request):
            return web.Response(status=500, text="failure")

        async def slow(_request):
            await asyncio.sleep(0.2)
            return web.Response(status=200, text="slow")

        self.app = web.Application()
        self.app.router.add_get("/ok", ok)
        self.app.router.add_get("/failure", failure)
        self.app.router.add_get("/slow", slow)
        self.runner = web.AppRunner(self.app)
        await self.runner.setup()
        self.site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await self.site.start()
        self.port = self.site._server.sockets[0].getsockname()[1]

    async def asyncTearDown(self):
        await self.runner.cleanup()

    async def run_generator(
        self,
        path: str,
        *,
        timeout: float = 0.5,
        rps: int = 20,
        duration: float = 0.3,
        safety: dict | None = None,
        start_rps: int | None = None,
        kind: str = "load",
    ) -> dict:
        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            config = directory / "config.json"
            output = directory / "result.json"
            config.write_text(json.dumps({
                "profile": "mock",
                "endpoint": f"http://127.0.0.1:{self.port}",
                "timeout_sec": timeout,
                "safety": safety or {},
                "phases": [{"kind": kind, "start_rps": rps if start_rps is None else start_rps, "rps": rps, "duration_sec": duration}],
                "apps": {
                    "mock-app": {
                        "share": 1.0,
                        "slo_ms": 100.0,
                        "expected_status": 200,
                        "method": "GET",
                        "path": path,
                    }
                },
            }), encoding="utf-8")
            process = await asyncio.create_subprocess_exec(
                sys.executable,
                str(LOADGEN),
                "--config",
                str(config),
                "--output",
                str(output),
            )
            await asyncio.wait_for(process.wait(), timeout=10)
            self.assertEqual(process.returncode, 0)
            self.assertTrue(output.exists())
            return json.loads(output.read_text(encoding="utf-8"))

    async def test_success_json_schema_and_bounds(self):
        result = await self.run_generator("/ok")
        self.assertGreater(result["success"], 0)
        self.assertFalse(result["generator_limited"])
        self.assertLessEqual(result["workers"], 64)
        self.assertLessEqual(result["connections"], 96)
        self.assertLessEqual(result["queue_max"], 256)
        self.assertLessEqual(result["max_active"], result["workers"])
        self.assertIn("slo_success_rate", result["apps"]["mock-app"])
        self.assertEqual(len(result["phases"]), 1)
        self.assertEqual(result["phases"][0]["kind"], "load")

    async def test_linear_arrival_rate_phase_contract(self):
        result = await self.run_generator("/ok", start_rps=5, rps=20, duration=0.5, kind="ramp")
        phase = result["phases"][0]
        self.assertEqual(phase["kind"], "ramp")
        self.assertEqual(phase["start_rps"], 5.0)
        self.assertEqual(phase["target_rps"], 20.0)
        self.assertGreater(phase["apps"]["mock-app"]["requests"], 0)

    async def test_http_failure_is_counted(self):
        result = await self.run_generator("/failure")
        self.assertGreater(result["failed"], 0)
        self.assertGreater(result["failure_codes"].get("500", 0), 0)
        self.assertFalse(result["generator_limited"])

    async def test_timeout_is_application_evidence(self):
        result = await self.run_generator("/slow", timeout=0.01)
        self.assertGreater(result["timeouts"], 0)
        self.assertGreater(result["failure_codes"].get("timeout", 0), 0)
        self.assertFalse(result["generator_limited"])

    async def test_queue_overflow_is_bounded_and_generator_limited(self):
        result = await self.run_generator(
            "/slow",
            timeout=1.0,
            rps=500,
            duration=0.4,
            safety={"workers": 2, "connections": 2, "queue": 2},
        )
        self.assertEqual(result["workers"], 2)
        self.assertEqual(result["connections"], 2)
        self.assertEqual(result["queue_max"], 2)
        self.assertLessEqual(result["max_active"], 2)
        self.assertGreater(result["dropped"], 0)
        self.assertTrue(result["generator_limited"])
        self.assertIn("QUEUE_FULL", result["generator_limit_reason"])
        self.assertEqual(result["scheduled"], result["sent"] + result["dropped"])


if __name__ == "__main__":
    unittest.main()
