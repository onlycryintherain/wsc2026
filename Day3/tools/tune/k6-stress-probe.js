// stress-only capacity probe: 가변 VU로 stress endpoint 처리량/latency 측정
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const endpoint = __ENV.ENDPOINT || 'http://127.0.0.1';
const length = Number(__ENV.STRESS_LENGTH || 80);
const vus = Number(__ENV.PROBE_VUS || 4);
const duration = Number(__ENV.PROBE_DURATION || 60);

const stress_requests = new Counter('stress_requests');

export const options = {
  scenarios: {
    stress: {
      executor: 'constant-vus',
      vus: vus,
      duration: `${duration}s`,
    },
  },
  thresholds: {
    stress_requests: ['count>=0'],
  },
};

let seq = 0;
function requestId() {
  const t = Date.now();
  return `${t}-${seq++}`;
}

function uuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export default function () {
  const payload = JSON.stringify({ requestid: requestId(), uuid: uuid(), length });
  const res = http.post(`${endpoint}/v1/stress`, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '10s',
    tags: { app: 'stress' },
  });
  check(res, { 'status 201': (r) => r.status === 201 });
  stress_requests.add(1);
}