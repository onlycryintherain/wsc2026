import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import exec from 'k6/execution';

const endpoint = (__ENV.ENDPOINT || '').replace(/\/$/, '');
const requestId = __ENV.REQUEST_ID || '999999999999';
const uuid = __ENV.UUID || '7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729';
const hotProductId = __ENV.PRODUCT_ID || 'dbdump500001';
const productIds = (__ENV.PRODUCT_IDS || hotProductId).split(',').map((v) => v.trim()).filter(Boolean);
const stressLength = Number(__ENV.STRESS_LENGTH || 256);
const userRecords = JSON.parse(open(__ENV.USER_DATA_FILE || './user-data.json'));
if (!userRecords.length) throw new Error('USER_DATA_FILE has no user records');
const requestTimeout = __ENV.REQUEST_TIMEOUT || '5s';
// 진단: 실패한 요청의 첫 N건만 상세 로그를 남긴다(로그 폭탄 방지).
// k6는 --log-output=file로 실행되므로 이 로그는 결과 디렉토리의 *-k6.log에 남는다.
// 0이면 상세 로그를 끄고 status 집계 카운터만 남긴다.
const diagnoseFailures = Math.max(0, Number(__ENV.DIAGNOSE_FAILURES || 5));
let diagnosedFailures = 0;
const rateSteps = (__ENV.RATE_STEPS || '10,20,30,40,50,60').split(',').map((v) => Number(v.trim())).filter((v) => Number.isFinite(v));
const profileDuration = Number(__ENV.PROFILE_DURATION || 240);
const cooldownSeconds = Number(__ENV.COOLDOWN_DURATION || 60);
const warmupSeconds = Number(__ENV.WARMUP_DURATION || 30);
const steadySeconds = Number(__ENV.STEADY_DURATION || 30);
const peakRate = Math.max(...rateSteps);
// VU Retry 전용 warmup(초). tune.ps1이 포화 감지 후 설정한다.
// 0이면 동작 변화 없음(기존 프로필). >0이면 stages 맨 앞에 0→저부하 선형 ramp가 추가되고
// 그 구간의 요청은 본 평가 metric(requests/duration/success 등)에서 제외된다.
const retryWarmupSeconds = Math.max(0, Number(__ENV.RETRY_WARMUP_SECONDS || 0));
const retryWarmupLeadSeconds = retryWarmupSeconds > 0 ? retryWarmupSeconds + 1 : 0;
const loadWindowSeconds = profileDuration - cooldownSeconds;
const rampSeconds = Math.max(10, Math.floor((loadWindowSeconds - warmupSeconds - steadySeconds) / Math.max(1, rateSteps.length - 1)));
const steadyStartSeconds = retryWarmupLeadSeconds + warmupSeconds + rampSeconds * Math.max(0, rateSteps.length - 1);

// retry warmup 구간(0→저부하 ramp + 선행 1s) 여부. 이 구간은 VU/connection/HPA 변화의
// 초기 spike를 흡수하기 위한 것이므로 metric에서 제외한다.
function isRetryWarmup() {
  if (retryWarmupSeconds <= 0) return false;
  return (exec.instance.currentTestRunDuration / 1000) < retryWarmupLeadSeconds;
}

const metrics = {};
for (const app of ['user', 'product', 'stress']) {
  metrics[app] = {
    // 전체 latency (timeout ceiling 5001ms 포함). SLO 집계 참고용이다.
    duration: new Trend(`${app}_duration`, true),
    // 성공 응답만의 latency. Q/L(QualityScore의 성공 p95/p99)은 이 trend만 사용한다.
    // timeout ceiling 값이 절대 이 trend에 들어가지 않는다.
    successDuration: new Trend(`${app}_success_duration`, true),
    failed: new Rate(`${app}_failed`),
    requests: new Counter(`${app}_requests`),
    success: new Counter(`${app}_success`),
    failures: new Counter(`${app}_failures`),
    timeouts: new Counter(`${app}_timeouts`),
    timeoutRate: new Rate(`${app}_timeout_rate`),
    slo: new Rate(`${app}_slo`),
    // 실패 유형 집계: {code:timeout}, {code:500}, {code:403} 등 태그로 분리되어
    // summary-export에 남는다. tune.ps1이 이걸 읽어 timeout vs 5xx vs 4xx를 구분한다.
    failureBreakdown: new Counter(`${app}_failure_breakdown`),
    steadyDuration: new Trend(`${app}_steady_duration`, true),
    steadySuccessDuration: new Trend(`${app}_steady_success_duration`, true),
    steadyRequests: new Counter(`${app}_steady_requests`),
    steadySuccess: new Counter(`${app}_steady_success`),
    steadyFailures: new Counter(`${app}_steady_failures`),
    steadyTimeouts: new Counter(`${app}_steady_timeouts`),
    steadySlo: new Rate(`${app}_steady_slo`),
  };
}
const upstream5xx = new Counter('upstream_5xx');

function rateFor(app, totalRate) {
  const userRate = Math.max(1, Math.round(totalRate * 0.50));
  const productRate = Math.max(1, Math.round(totalRate * 0.35));
  if (app === 'user') return userRate;
  if (app === 'product') return productRate;
  return Math.max(1, totalRate - userRate - productRate);
}

function scenario(app, share) {
  const upper = app.toUpperCase();
  const preAllocatedVUs = Math.max(1, Number(__ENV[`${upper}_PRE_ALLOCATED_VUS`] || Math.ceil(Number(__ENV.PRE_ALLOCATED_VUS || 32) * share)));
  const maxVUs = Math.max(preAllocatedVUs, Number(__ENV[`${upper}_MAX_VUS`] || Math.ceil(Number(__ENV.MAX_VUS || 32) * share)));
  return {
    executor: 'ramping-arrival-rate',
    exec: `${app}Load`,
    startRate: rateFor(app, rateSteps[0] || 10),
    timeUnit: '1s',
    // 한 API의 timeout이 다른 API의 VU를 고갈시키지 않도록 풀을 분리한다.
    preAllocatedVUs,
    maxVUs,
    stages: [
      // VU Retry warmup: 0 → 저부하 선형 ramp (이 구간 metric은 본 평가에서 제외).
      ...(retryWarmupSeconds > 0
        ? [
            { target: 0, duration: '1s' },
            { target: rateFor(app, rateSteps[0] || 10), duration: `${retryWarmupSeconds}s` },
          ]
        : []),
      // 첫 구간은 저부하 warm-up, 중간은 순차 ramp-up, 마지막은 peak 고정 steady-state다.
      { target: rateFor(app, rateSteps[0] || 10), duration: `${warmupSeconds}s` },
      ...rateSteps.slice(1).map((target) => ({ target: rateFor(app, target), duration: `${rampSeconds}s` })),
      { target: rateFor(app, peakRate), duration: `${steadySeconds}s` },
      { target: 0, duration: '1s' },
      { target: 0, duration: `${Math.max(1, cooldownSeconds - 1)}s` },
    ],
    gracefulStop: '5s',
  };
}

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    user_api: scenario('user', 0.50),
    product_api: scenario('product', 0.35),
    stress_api: scenario('stress', 0.15),
  },
  thresholds: {
    http_req_failed: ['rate<=0.10'],
    user_duration: ['p(95)<200', 'max<5000'],
    product_duration: ['p(95)<200', 'max<5000'],
    stress_duration: ['p(95)<1000', 'max<5000'],
    user_steady_duration: ['p(95)<200'],
    product_steady_duration: ['p(95)<200'],
    stress_steady_duration: ['p(95)<1000'],
    'dropped_iterations{scenario:user_api}': ['count>=0'],
    'dropped_iterations{scenario:product_api}': ['count>=0'],
    'dropped_iterations{scenario:stress_api}': ['count>=0'],
    'iterations{scenario:user_api}': ['count>=0'],
    'iterations{scenario:product_api}': ['count>=0'],
    'iterations{scenario:stress_api}': ['count>=0'],
    'vus{scenario:user_api}': ['value>=0'],
    'vus{scenario:product_api}': ['value>=0'],
    'vus{scenario:stress_api}': ['value>=0'],
  },
};

function headers() {
  return { 'User-Agent': 'wsi2026-k6/2.0', 'X-Request-ID': requestId };
}

function isSteadyState() {
  const elapsedSeconds = exec.instance.currentTestRunDuration / 1000;
  return elapsedSeconds >= steadyStartSeconds && elapsedSeconds < loadWindowSeconds;
}

function record(app, response, expectedStatus, sloMs, steady) {
  const ok = response.status === expectedStatus;
  const timedOut = response.status === 0 || response.error_code === 1050;
  metrics[app].requests.add(1);
  metrics[app].duration.add(response.timings.duration);
  metrics[app].failed.add(!ok);
  metrics[app].timeoutRate.add(timedOut);
  metrics[app].slo.add(ok && response.timings.duration <= sloMs);
  if (ok) {
    metrics[app].success.add(1);
    metrics[app].successDuration.add(response.timings.duration);
  } else {
    metrics[app].failures.add(1);
    // 실패 유형을 raw status로 집계하고, 첫 N건만 상세 로그를 남긴다.
    // status=0/error_code=1050은 k6 클라이언트 timeout(요청을 서버가 5초 안에
    // 끝내지 못함)이며, 5xx는 서버 오류, 4xx는 요청 형식/WAF 차단이다.
    const code = timedOut ? 'timeout' : String(response.status);
    metrics[app].failureBreakdown.add(1, { code });
    if (diagnosedFailures < diagnoseFailures) {
      diagnosedFailures++;
      console.warn(
        `[${app}] status=${response.status}` +
        ` error=${response.error || ''}` +
        ` error_code=${response.error_code || ''}` +
        ` duration=${response.timings.duration}` +
        ` body=${response.body ? response.body.substring(0, 200) : ''}`
      );
    }
  }
  if (timedOut) metrics[app].timeouts.add(1);
  if (steady) {
    metrics[app].steadyRequests.add(1);
    metrics[app].steadyDuration.add(response.timings.duration);
    metrics[app].steadySlo.add(ok && response.timings.duration <= sloMs);
    if (ok) {
      metrics[app].steadySuccess.add(1);
      metrics[app].steadySuccessDuration.add(response.timings.duration);
    } else {
      metrics[app].steadyFailures.add(1);
    }
    if (timedOut) metrics[app].steadyTimeouts.add(1);
  }
  if (response.status >= 500 && response.status <= 599) upstream5xx.add(1);
  check(response, { [`${app} expected status`]: () => ok });
}

export function userLoad() {
  if (!endpoint) throw new Error('ENDPOINT is required');
  const iteration = exec.scenario.iterationInTest;
  const user = userRecords[iteration % userRecords.length];
  const steady = isSteadyState();
  const response = http.get(
    `${endpoint}/v1/user?email=${encodeURIComponent(user.email)}&requestid=${requestId}&uuid=${uuid}`,
    { headers: headers(), timeout: requestTimeout, tags: { app: 'user', endpoint: 'user_get' } },
  );
  // retry warmup 요청은 발생만 시키고 본 평가 metric에 기록하지 않는다.
  if (!isRetryWarmup()) record('user', response, 200, 200, steady);
  sleep(0.05);
}

export function productLoad() {
  if (!endpoint) throw new Error('ENDPOINT is required');
  const iteration = exec.scenario.iterationInTest;
  const useHot = productIds.length === 1 || (iteration % 10) !== 0;
  const id = useHot ? hotProductId : productIds[iteration % productIds.length];
  const steady = isSteadyState();
  const response = http.get(
    `${endpoint}/v1/product?id=${encodeURIComponent(id)}&requestid=${requestId}&uuid=${uuid}`,
    { headers: headers(), timeout: requestTimeout, tags: { app: 'product', endpoint: useHot ? 'product_hot_get' : 'product_random_get' } },
  );
  if (!isRetryWarmup()) record('product', response, 200, 200, steady);
  sleep(0.05);
}

export function stressLoad() {
  if (!endpoint) throw new Error('ENDPOINT is required');
  const steady = isSteadyState();
  const response = http.post(
    `${endpoint}/v1/stress`,
    JSON.stringify({ requestid: requestId, uuid, length: stressLength }),
    { headers: { ...headers(), 'Content-Type': 'application/json' }, timeout: requestTimeout, tags: { app: 'stress', endpoint: 'stress_post' } },
  );
  if (!isRetryWarmup()) record('stress', response, 201, 1000, steady);
  sleep(0.05);
}
