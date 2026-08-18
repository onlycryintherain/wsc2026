#!/usr/bin/env bash
# tune.sh - 3과제 리소스 튜닝 (채점 기준 연동, ~20분)
set -euo pipefail

CLUSTER=${CLUSTER:-wsi2026-cluster}
REGION=${REGION:-ap-northeast-2}
UUID=${UUID:-7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729}
NS=${NS:-app}
DATA_FILE=${LOAD_USER_DUMP:-application/load_user.dump}
PRODUCT_ID=${CHECK_PRODUCT_ID:-dbdump500001}
read -r USER_ID USER_EMAIL < <(python3 - "$DATA_FILE" <<'PY'
import re,sys
try: raw=open(sys.argv[1],encoding='utf-8').read()
except Exception: raw=''
e=re.findall(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}',raw)
i=re.findall(r'(?i)\b(?:dbdump|user)[A-Za-z0-9_-]*\d+\b',raw)
print((i[0] if i else 'dbdump1'),(e[0] if e else 'dbdump1@example.org'))
PY
)
USER_ID=${USER_ID:-dbdump1}; USER_EMAIL=${USER_EMAIL:-dbdump1@example.org}
TRIALS=1
DUR=60s

PERF_SLO_USER=0.2
PERF_SLO_PRODUCT=0.2
PERF_SLO_STRESS=1.0

# 원본 채점 프록시: 성능을 우선하되 평균 노드가 baseline(2개)을 넘으면 비용 감점
AVAIL_GATE=99
COST_BASELINE_NODES=2
COST_PENALTY=6
RESULTS=${RESULTS:-/tmp/autotune-results.csv}
echo "combo,user_perf,product_perf,stress_perf,avg_perf,min_avail,nodes_avg,score" > "$RESULTS"

SEEDS=(
  "POST|/v1/user|{\"requestid\":\"1\",\"uuid\":\"$UUID\",\"username\":\"$USER_ID\",\"email\":\"$USER_EMAIL\"}"
  "POST|/v1/product|{\"requestid\":\"1\",\"uuid\":\"$UUID\",\"id\":\"$PRODUCT_ID\",\"name\":\"$PRODUCT_ID\",\"price\":1}"
)

LOAD_USER="user|30|10|GET|/v1/user?email=$USER_EMAIL&requestid=1&uuid=$UUID|"
LOAD_PRODUCT="product|30|10|GET|/v1/product?id=$PRODUCT_ID&requestid=1&uuid=$UUID|"
LOAD_STRESS="stress|12|2|POST|/v1/stress|{\"requestid\":\"1\",\"uuid\":\"$UUID\",\"length\":64}"

# 원본 후보 형식:
# name | user_cpu | product_cpu | stress_cpu | user_util | product_util |
# stress_util | user_min | user_max | product_min | product_max | stress_min | stress_max
# 모든 API를 동시에 부하해 조합 전체를 평가하며, max는 patch_app()에서도 재차 제한한다.
COMBOS=(
  "baseline|200m|200m|750m|55|55|60|2|6|1|5|2|8"
  "lean|150m|150m|600m|60|60|65|2|6|1|5|2|8"
  "balanced|200m|200m|750m|60|60|65|2|6|1|5|2|7"
  "cost-min|150m|150m|600m|65|65|70|2|5|1|4|2|6"
  # stress 부하는 c=12, q=2로 약 24 req/s이므로 최소 4개 pod를 미리 확보한다.
  "stress-warm|200m|200m|750m|55|55|60|2|6|1|5|4|8"
  "stress-lean-warm|150m|150m|600m|60|60|65|2|6|1|5|4|8"
  "stress-high-capacity|200m|200m|1000m|55|55|55|3|6|1|5|6|8"
  # stress 24 concurrent에서 1초 SLO를 통과한 용량 조합(검증: 32 replicas)
  "stress-very-warm|200m|200m|750m|50|55|60|3|8|1|5|32|36"
)

# ============================================================
echo "============================================"
echo " 3과제 튜닝 (~20분)"
echo " 시작: $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')"
echo "============================================"
echo ""

if ! command -v hey >/dev/null 2>&1; then
  echo "[setup] hey 설치..."
  sudo curl -sL -o /usr/local/bin/hey https://storage.googleapis.com/hey-releases/hey_linux_amd64
  sudo chmod +x /usr/local/bin/hey
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "[setup] kubectl 설치..."
  KV=$(curl -sL https://dl.k8s.io/release/stable.txt)
  sudo curl -sL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KV}/bin/linux/amd64/kubectl"
  sudo chmod +x /usr/local/bin/kubectl
fi

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1

if [ -n "${1:-}" ]; then EP="${1%/}"
else
  CF=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='wsi2026'].DomainName" --output text 2>/dev/null)
  [ -z "$CF" ] || [ "$CF" = "None" ] && CF=$(aws cloudfront list-distributions --query "DistributionList.Items[0].DomainName" --output text 2>/dev/null)
  [ -z "$CF" ] || [ "$CF" = "None" ] && { echo "❌ CloudFront 못 찾음"; exit 1; }
  EP="https://$CF"
fi
[[ "$EP" =~ ^https?:// ]] || EP="https://$EP"
echo "[setup] $EP"
kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '{printf "  %-40s %s\n", $1, $3}'
echo ""

# ============================================================
# FUNCTIONS
# ============================================================
seed_data() {
  for s in "${SEEDS[@]}"; do
    IFS='|' read -r m path body <<<"$s"
    if [ "$m" = GET ]; then curl -sL -o /dev/null "$EP$path" || true
    else curl -sL -o /dev/null -X "$m" "$EP$path" -H 'Content-Type: application/json' -d "$body" || true; fi
  done
}

load_app() { # $1=app $2=dur $3=outdir
  local load_var="LOAD_${1^^}"; local ld="${!load_var}"
  IFS='|' read -r _n _c _q _m _p _b <<<"$ld"
  mkdir -p "$3"
  # 조합별 평균 노드 수를 기록해 성능뿐 아니라 EC2 비용도 선택에 반영한다.
  ( while true; do echo "$(date +%s),$(kubectl get nodes --no-headers 2>/dev/null|grep -c Ready||true)"; sleep 5; done ) > "$3/nodes.csv" &
  local S=$!
  local rc=0
  if [ "$_m" = GET ]; then
    hey -z "$2" -c "$_c" -q "$_q" -o csv "$EP$_p" > "$3/$1.csv" 2>/dev/null || rc=$?
  else
    hey -z "$2" -c "$_c" -q "$_q" -m "$_m" -T application/json -d "$_b" -o csv "$EP$_p" > "$3/$1.csv" 2>/dev/null || rc=$?
  fi
  kill "$S" 2>/dev/null || true
  wait "$S" 2>/dev/null || true
  return "$rc"
}

load_all() { # $1=dur $2=label
  local out="/tmp/tune-$2"; mkdir -p "$out"; local pids=()
  ( while true; do echo "$(date +%s),$(kubectl get nodes --no-headers 2>/dev/null|grep -c Ready||true)"; sleep 5; done ) > "$out/nodes.csv" &
  local S=$!
  for ld in "$LOAD_USER" "$LOAD_PRODUCT" "$LOAD_STRESS"; do
    IFS='|' read -r _n _c _q _m _p _b <<<"$ld"
    if [ "$_m" = GET ]; then hey -z "$1" -c "$_c" -q "$_q" -o csv "$EP$_p" > "$out/$_n.csv" 2>/dev/null &
    else hey -z "$1" -c "$_c" -q "$_q" -m "$_m" -T application/json -d "$_b" -o csv "$EP$_p" > "$out/$_n.csv" 2>/dev/null &
    fi
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null||true; done
  kill $S 2>/dev/null||true; wait $S 2>/dev/null||true
}

run_trial() { # $1=dur $2=label; all APIs run concurrently
  local out="/tmp/tune-$2"; mkdir -p "$out"; local pids=() names=(user product stress)
  ( while true; do echo "$(date +%s),$(kubectl get nodes --no-headers 2>/dev/null|grep -c Ready||true)"; sleep 5; done ) > "$out/nodes.csv" &
  local S=$!
  for ld in "$LOAD_USER" "$LOAD_PRODUCT" "$LOAD_STRESS"; do
    IFS='|' read -r _n _c _q _m _p _b <<<"$ld"
    local err="$out/$_n.hey.stderr"
    : > "$err"
    if [ "$_m" = GET ]; then
      hey -z "$1" -c "$_c" -q "$_q" -o csv "$EP$_p" > "$out/$_n.csv" 2>"$err" &
    else
      hey -z "$1" -c "$_c" -q "$_q" -m "$_m" -T application/json -d "$_b" -o csv "$out/$_n.csv" 2>"$err" &
    fi
    pids+=($!)
  done
  for i in "${!pids[@]}"; do
    rc=0
    wait "${pids[$i]}" || rc=$?
    name="${names[$i]}"
    csv="$out/$name.csv"
    err="$out/$name.hey.stderr"
    bytes=$(wc -c < "$csv" 2>/dev/null || echo 0)
    rows=$(tail -n +2 "$csv" 2>/dev/null | wc -l || echo 0)
    if [ "$rc" -ne 0 ] || [ "$bytes" -eq 0 ] || [ -s "$err" ]; then
      echo "    [hey] app=$name exit=$rc csv_bytes=$bytes data_rows=$rows stderr=$err" >&2
      if [ -s "$err" ]; then sed -n '1,12p' "$err" >&2; fi
    fi
  done
  kill "$S" 2>/dev/null||true; wait "$S" 2>/dev/null||true
}

score_trial() { # $1=label -> u_perf p_perf s_perf avg_perf min_avail nodes_avg score
  python3 - "/tmp/tune-$1" "$AVAIL_GATE" "$COST_BASELINE_NODES" "$COST_PENALTY" <<'PY'
import csv,os,sys
from collections import Counter
out,gate,baseline,penalty=sys.argv[1],float(sys.argv[2]),float(sys.argv[3]),float(sys.argv[4])
slo={"user":0.2,"product":0.2,"stress":1.0}
perf={}; avail={}
for api,lim in slo.items():
    path=f"{out}/{api}.csv"
    rows=[]
    headers=[]
    try:
        with open(path, newline="") as f:
            reader=csv.DictReader(f)
            headers=reader.fieldnames or []
            rows=list(reader)
    except (FileNotFoundError,KeyError,OSError):
        pass
    valid=[]
    parse_errors=0
    status_counts=Counter()
    for row in rows:
        try:
            status=str(row.get("status-code","")).strip()
            response_time=float(str(row.get("response-time","")).strip())
            valid.append((status,response_time))
            status_counts[status]+=1
        except (TypeError,ValueError):
            parse_errors+=1
    ok=[(s,t) for s,t in valid if s.startswith("2") and t<=5.0]
    good=[(s,t) for s,t in ok if t<=lim]
    avail[api]=100*len(ok)/len(valid) if valid else 0.0
    perf[api]=100*len(good)/len(valid) if valid else 0.0
    times=[t for _,t in valid]
    rt_range=f"{min(times):.6g}..{max(times):.6g}" if times else "EMPTY"
    statuses=",".join(f"{k}:{v}" for k,v in sorted(status_counts.items())) or "EMPTY"
    try: size=os.path.getsize(path)
    except OSError: size=0
    print(f"    [diag] api={api} file_bytes={size} csv_rows={len(rows)} valid={len(valid)} parse_errors={parse_errors} statuses={statuses} response_time={rt_range} ok={len(ok)} slo_ok={len(good)} headers={','.join(headers) or 'EMPTY'}", file=sys.stderr)
try:
    ns=[int(line.strip().split(",")[1]) for line in open(f"{out}/nodes.csv") if line.strip()]
except OSError:
    ns=[]
navg=sum(ns)/len(ns) if ns else baseline
avg_perf=sum(perf.values())/3
min_avail=min(avail.values())

def pct_points(value):
    return 0.5 * sum(value >= threshold for threshold in (90,87.5,85,82.5,80,70,50,30))

availability_points=sum(pct_points(avail[api]) for api in slo)
performance_points=sum(pct_points(perf[api]) for api in slo)
# All current node types are t3.medium; average Ready nodes is the trial cost proxy.
cost_ratio=navg/baseline if baseline > 0 else 1.0
cost_points=sum(1.0 for threshold in (1.00,1.25,1.50,1.75,2.00,2.25,2.50,2.75,3.00,3.25,3.50,3.75) if 0.5 <= cost_ratio <= threshold)
score=availability_points+performance_points+cost_points
print(f"    [diag] points availability={availability_points:.1f} performance={performance_points:.1f} cost={cost_points:.1f} total={score:.1f} cost_ratio_proxy={cost_ratio:.2f}", file=sys.stderr)
print(f"{perf['user']:.1f} {perf['product']:.1f} {perf['stress']:.1f} {avg_perf:.1f} {min_avail:.1f} {navg:.2f} {score:.1f}")
PY
}

score_app() { # $1=dir $2=app $3=slo -> "avail perf"
  python3 - "$1" "$2" "$3" <<'PY'
import csv,sys
out,app,slo=sys.argv[1],sys.argv[2],float(sys.argv[3])
try: rows=list(csv.DictReader(open(f"{out}/{app}.csv")))
except: print("0.0 0.0");sys.exit()
if not rows: print("0.0 0.0");sys.exit()
h=list(rows[0].keys())
st=next((c for c in h if 'status' in c.lower()),None)
rt=next((c for c in h if 'response' in c.lower()),None)
if not st or not rt: print("0.0 0.0");sys.exit()
v=[(str(r[st]).strip(),float(r[rt])) for r in rows if r.get(rt)]
if not v: print("0.0 0.0");sys.exit()
ok=sum(1 for s,t in v if s.startswith("2") and t<=5.0)
perf=sum(1 for s,t in v if s.startswith("2") and t<=slo)
print(f"{100*ok/len(v):.1f} {100*perf/len(v):.1f}")
PY
}

pts() { # $1=pct -> points
  python3 -c "print(f'{sum(0.5 for t in [90,87.5,85,82.5,80,70,50,30] if $1>=t):.1f}')"
}

avg_nodes() { # $1=nodes.csv -> average Ready node count
  python3 - "$1" <<'PY'
import sys
values=[]
try:
    for line in open(sys.argv[1]):
        parts=line.strip().split(',')
        if parts and parts[-1].isdigit(): values.append(int(parts[-1]))
except OSError:
    pass
print(f"{sum(values)/len(values):.2f}" if values else "2.00")
PY
}

app_max_replicas() { # $1=app -> hard max replicas
  case "$1" in
    stress) echo 36 ;;
    user) echo 8 ;;
    product) echo 6 ;;
    *) echo 8 ;;
  esac
}

patch_app() { # $1=app $2=cpu_req $3=cpu_lim $4=mem $5=util $6=min $7=max
  local app="$1" requested_min="$6" requested_max="$7"
  local hard_max
  hard_max=$(app_max_replicas "$app")
  if [ "$requested_max" -gt "$hard_max" ]; then
    echo "  [guard] $app maxReplicas $requested_max -> $hard_max"
    requested_max="$hard_max"
  fi
  if [ "$requested_min" -gt "$requested_max" ]; then
    requested_min="$requested_max"
  fi
  kubectl -n "$NS" set resources deploy/"$app" --requests=cpu="$2",memory="$4" --limits=cpu="$3" >/dev/null 2>&1||true
  # 기본 HPA 동작(즉시 scale-up/scale-down 300초)은 짧은 부하 시험에서
  # replica와 Karpenter 노드를 과도하게 늘릴 수 있으므로 증감 속도를 제한한다.
  kubectl -n "$NS" patch hpa "$app" --type=merge -p \
    "{\"spec\":{\"minReplicas\":$requested_min,\"maxReplicas\":$requested_max,\"behavior\":{\"scaleUp\":{\"stabilizationWindowSeconds\":120,\"selectPolicy\":\"Min\",\"policies\":[{\"type\":\"Percent\",\"value\":50,\"periodSeconds\":60},{\"type\":\"Pods\",\"value\":2,\"periodSeconds\":60}]},\"scaleDown\":{\"stabilizationWindowSeconds\":120,\"selectPolicy\":\"Min\",\"policies\":[{\"type\":\"Percent\",\"value\":50,\"periodSeconds\":60},{\"type\":\"Pods\",\"value\":2,\"periodSeconds\":60}]}},\"metrics\":[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":$5}}}]}}" >/dev/null 2>&1||true
  # HPA 반영을 기다리지 않고 combo의 최소 replica를 즉시 기동한다.
  # 짧은 60초 부하 테스트에서 scale-out 지연과 cold start를 방지한다.
  kubectl -n "$NS" scale deploy/"$app" --replicas="$requested_min" >/dev/null 2>&1||true
  kubectl -n "$NS" rollout status deploy/"$app" --timeout=90s >/dev/null 2>&1||true
}

cost_ratio() {
  python3 - "$REGION" "$CLUSTER" <<'PY'
import subprocess,json,sys
region,cluster=sys.argv[1],sys.argv[2]
r=subprocess.run(["aws","ec2","describe-instances","--region",region,"--filters","Name=instance-state-name,Values=running","--query","Reservations[].Instances[].{Type:InstanceType,Tags:Tags}","--output","json"],capture_output=True,text=True)
insts=json.loads(r.stdout) if r.stdout.strip() else []
costs={"t3.medium":0.052,"t3.large":0.104,"t3.xlarge":0.208,"m5.large":0.118,"m5.xlarge":0.236,"c5.large":0.096,"c5.xlarge":0.192}
total=0
for i in insts:
    tags={t["Key"]:t["Value"] for t in (i.get("Tags") or [])}
    is_managed=tags.get("eks:nodegroup-name") is not None
    is_karpenter=tags.get("karpenter.sh/nodepool") is not None
    belongs=tags.get("aws:eks:cluster-name")==cluster or tags.get("eks:cluster-name")==cluster or tags.get("eks:eks-cluster-name")==cluster
    if belongs and (is_managed or is_karpenter):
        total+=costs.get(i["Type"],0.052)
base=2*0.052
print(f"{total/base:.2f}" if base>0 and total>0 else "1.00")
PY
}

# ============================================================
# MAIN
# ============================================================
seed_data

# --- 노드 2개로 초기화 (비용 baseline) ---
echo "[reset] 노드 2개로 축소..."
for app in user product stress; do
  kubectl -n "$NS" scale deploy/"$app" --replicas=1 >/dev/null 2>&1 || true
  kubectl -n "$NS" patch hpa "$app" --type=merge -p '{"spec":{"minReplicas":1,"maxReplicas":2,"behavior":{"scaleUp":{"stabilizationWindowSeconds":120,"selectPolicy":"Min","policies":[{"type":"Percent","value":50,"periodSeconds":60},{"type":"Pods","value":2,"periodSeconds":60}]},"scaleDown":{"stabilizationWindowSeconds":120,"selectPolicy":"Min","policies":[{"type":"Percent","value":50,"periodSeconds":60},{"type":"Pods","value":2,"periodSeconds":60}]}}}}' >/dev/null 2>&1 || true
done
echo "[reset] 60초 대기 (Karpenter consolidation)..."
sleep 60
NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo "?")
echo "[reset] 현재 노드: $NODES"
echo ""

# --- 원본 방식 통합 조합 튜닝 ---
# 세 API에 동시에 부하를 걸어 하나의 조합을 성능/가용성/노드 비용으로 평가한다.
echo "=== 통합 autotune: ${#COMBOS[@]} combos x $DUR ==="
best_score=-999999
best_row=""
for row in "${COMBOS[@]}"; do
  IFS='|' read -r name u_cpu p_cpu s_cpu u_util p_util s_util \
    u_min u_max p_min p_max s_min s_max <<<"$row"
  echo
  echo ">>> combo=$name user=$u_cpu/$u_util product=$p_cpu/$p_util stress=$s_cpu/$s_util"
  patch_app user "$u_cpu" "500m" "128Mi" "$u_util" "$u_min" "$u_max"
  patch_app product "$p_cpu" "500m" "128Mi" "$p_util" "$p_min" "$p_max"
  patch_app stress "$s_cpu" "1" "256Mi" "$s_util" "$s_min" "$s_max"
  echo "    waiting for rollouts..."
  for app in user product stress; do
    kubectl -n "$NS" rollout status deploy/"$app" --timeout=180s >/dev/null
  done
  # 이전 조합의 HPA scale 상태와 Karpenter 노드가 안정화될 시간
  sleep 45
  run_trial "$DUR" "$name"
  read -r up pp sp ap ma na sc <<<"$(score_trial "$name")"
  printf "    perf u/p/s=%s/%s/%s avg=%s avail_min=%s nodes_avg=%s SCORE=%s\n" \
    "$up" "$pp" "$sp" "$ap" "$ma" "$na" "$sc"
  echo "$name,$up,$pp,$sp,$ap,$ma,$na,$sc" >> "$RESULTS"
  if python3 -c "exit(0 if float('$sc') > float('$best_score') else 1)"; then
    best_score="$sc"
    best_row="$row"
  fi
done

if [ -z "$best_row" ]; then
  echo "❌ 유효한 튜닝 결과가 없습니다." >&2
  exit 1
fi

echo
echo "### winner: $(echo "$best_row" | cut -d'|' -f1) score=$best_score"
IFS='|' read -r name u_cpu p_cpu s_cpu u_util p_util s_util \
  u_min u_max p_min p_max s_min s_max <<<"$best_row"
echo "### applying winner to live cluster"
patch_app user "$u_cpu" "500m" "128Mi" "$u_util" "$u_min" "$u_max"
patch_app product "$p_cpu" "500m" "128Mi" "$p_util" "$p_min" "$p_max"
patch_app stress "$s_cpu" "1" "256Mi" "$s_util" "$s_min" "$s_max"
cat <<EOF

### winner settings
  user:    requests.cpu=$u_cpu HPA=$u_util min=$u_min max=$u_max
  product: requests.cpu=$p_cpu HPA=$p_util min=$p_min max=$p_max
  stress:  requests.cpu=$s_cpu HPA=$s_util min=$s_min max=$s_max
EOF

# --- 통합 검증 (~2분) ---
echo "=== 통합 검증 ==="
sleep 20
load_all "$DUR" "final"

read ua up <<< $(score_app "/tmp/tune-final" user "$PERF_SLO_USER")
read pa pp <<< $(score_app "/tmp/tune-final" product "$PERF_SLO_PRODUCT")
read sa sp <<< $(score_app "/tmp/tune-final" stress "$PERF_SLO_STRESS")
CR=$(cost_ratio)
NAV=$(avg_nodes "/tmp/tune-final/nodes.csv")

 echo ""
echo "============================================"
echo " 결과 (채점 기준 동일)"
echo "============================================"
printf "\n  [가용성 12점]\n"
printf "    user:    %5.1f%% → %s pts\n" "$ua" "$(pts $ua)"
printf "    product: %5.1f%% → %s pts\n" "$pa" "$(pts $pa)"
printf "    stress:  %5.1f%% → %s pts\n" "$sa" "$(pts $sa)"
AT=$(python3 -c "print(f'{$(pts $ua)+$(pts $pa)+$(pts $sa):.1f}')")
echo "    합계: $AT/12"

printf "\n  [성능 12점]\n"
printf "    user(≤0.2s):    %5.1f%% → %s pts\n" "$up" "$(pts $up)"
printf "    product(≤0.2s): %5.1f%% → %s pts\n" "$pp" "$(pts $pp)"
printf "    stress(≤1.0s):  %5.1f%% → %s pts\n" "$sp" "$(pts $sp)"
PT=$(python3 -c "print(f'{$(pts $up)+$(pts $pp)+$(pts $sp):.1f}')")
echo "    합계: $PT/12"

printf "\n  [비용 12점]\n"
CS=$(python3 -c "
r=$CR;up=$up;pp=$pp;sp=$sp
t=[1.00,1.25,1.50,1.75,2.00,2.25,2.50,2.75,3.00,3.25,3.50,3.75]
print('0.0' if up<30 or pp<30 or sp<30 else f'{sum(1.0 for x in t if 0.5<=r<=x):.1f}')
")
printf "    ratio: %s → %s pts\n" "$CR" "$CS"
printf "    avg Ready nodes during final test: %s\n" "$NAV"

TOTAL=$(python3 -c "print(f'{$AT+$PT+$CS:.1f}')")
printf "\n  ══════════════════\n"
printf "  총점: %s / 36\n" "$TOTAL"
printf "  ══════════════════\n\n"

echo "  설정:"
printf "    user:    cpu=%s/500m HPA=%s%% r=%s-%s\n" "$u_cpu" "$u_util" "$u_min" "$u_max"
printf "    product: cpu=%s/500m HPA=%s%% r=%s-%s\n" "$p_cpu" "$p_util" "$p_min" "$p_max"
printf "    stress:  cpu=%s/1 HPA=%s%% r=%s-%s\n" "$s_cpu" "$s_util" "$s_min" "$s_max"
echo ""
echo " 완료: $(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')"
echo "============================================"
