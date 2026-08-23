#!/usr/bin/env bash
#
# End-to-end verification of the monitoring stack.
#
# The point of this script is to prove DATA IS FLOWING, not merely that pods
# reached Running. A stack where every pod is green and every dashboard is empty
# looks healthy to kubectl and is useless to a human, so each check below
# queries a real API and asserts on the response.
#
# Usage: ./scripts/verify.sh [release] [namespace]

set -uo pipefail

RELEASE="${1:-monitoring}"
NS="${2:-monitoring}"

PASS=0
FAIL=0
declare -a FAILURES=()

# --- output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

section() { printf "\n%s── %s %s\n" "$B" "$1" "$N"; }

ok()   { PASS=$((PASS+1)); printf "  %s✔%s %s\n" "$G" "$N" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf "  %s✘%s %s\n" "$R" "$N" "$1"; [[ -n "${2:-}" ]] && printf "      %s\n" "$2"; }
info() { printf "  %s·%s %s\n" "$Y" "$N" "$1"; }

# --- in-cluster HTTP helper ------------------------------------------------
#
# Queries have to run from inside the cluster to reach ClusterIP services. The
# obvious approach — `kubectl run --rm` per query — is unusable here: pod
# startup races the output capture, so roughly half the calls return an empty
# string and the check reports a false failure. (That produced 20 bogus failures
# on the first run of this script, including "Loki is missing labels" sitting
# right next to "Loki returns real log lines".)
#
# Instead: start ONE long-lived pod, wait for it to be Ready, and exec into it.
HELPER="monitoring-verify-helper"

helper_up() {
  if ! kubectl get pod "$HELPER" -n "$NS" >/dev/null 2>&1; then
    kubectl run "$HELPER" -n "$NS" --image=curlimages/curl:8.11.1 \
      --restart=Never --command -- sleep 3600 >/dev/null 2>&1
  fi
  kubectl wait --for=condition=Ready "pod/$HELPER" -n "$NS" --timeout=120s >/dev/null 2>&1
}

helper_down() {
  kubectl delete pod "$HELPER" -n "$NS" --wait=false >/dev/null 2>&1 || true
}
trap helper_down EXIT

kexec() { kubectl exec -n "$NS" "$HELPER" -- sh -c "$1" 2>/dev/null; }

if ! helper_up; then
  printf "%s✘%s could not start the in-cluster helper pod; aborting\n" "$R" "$N"
  exit 1
fi

# ---------------------------------------------------------------------------
section "1. Workloads"

# Excludes our own helper pod and anything mid-Terminating, neither of which
# says anything about the health of the stack.
not_running=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
  | grep -v "^${HELPER}" \
  | awk '$3!="Running" && $3!="Completed" && $3!="Terminating" {print $1" ("$3")"}')
if [[ -z "$not_running" ]]; then
  ok "all pods Running ($(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l) total)"
else
  bad "some pods are not Running" "$not_running"
fi

# Containers ready, not just pod phase.
notready=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
  | grep -v "^${HELPER}" \
  | awk '$3=="Running" {split($2,a,"/"); if (a[1]!=a[2]) print $1" "$2}')
if [[ -z "$notready" ]]; then
  ok "all containers ready"
else
  bad "containers not ready" "$notready"
fi

section "2. Storage"

pvc_total=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | wc -l)
pvc_bound=$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | awk '$2=="Bound"' | wc -l)
if [[ "$pvc_total" -gt 0 && "$pvc_total" == "$pvc_bound" ]]; then
  ok "$pvc_bound/$pvc_total PVCs Bound"
else
  bad "PVCs not all Bound ($pvc_bound/$pvc_total)" \
      "$(kubectl get pvc -n "$NS" --no-headers 2>/dev/null | awk '$2!="Bound"')"
fi

section "3. Node coverage (the tainted control-plane node must be included)"

nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
ds_bad=""
while read -r name desired ready; do
  [[ -z "$name" ]] && continue
  if [[ "$desired" == "$nodes" && "$ready" == "$nodes" ]]; then
    ok "daemonset $name covers all $nodes nodes ($ready/$desired)"
  else
    ds_bad="yes"
    bad "daemonset $name covers $ready/$desired of $nodes nodes" \
        "missing a toleration for the control-plane taint?"
  fi
done < <(kubectl get ds -n "$NS" --no-headers 2>/dev/null | awk '{print $1, $2, $4}')
[[ -z "$(kubectl get ds -n "$NS" --no-headers 2>/dev/null)" ]] && bad "no DaemonSets found (node-exporter and alloy are missing)"

section "4. Prometheus — scraping"

targets=$(kexec "curl -s 'http://${RELEASE}-kube-prometheus-prometheus:9090/api/v1/targets?state=active'")
if [[ -z "$targets" ]]; then
  bad "could not reach Prometheus API"
else
  # Down targets are split by namespace. A down target inside our own namespace
  # is our bug; one in someone else's namespace is a pre-existing cluster issue
  # that this chart merely surfaced, so it is reported without failing the run.
  # The heredoc is quoted ('PY') so the shell does not touch the Python, and the
  # namespace arrives via the environment rather than string interpolation.
  tfile=$(mktemp); echo "$targets" > "$tfile"
  eval "$(VERIFY_NS="$NS" python3 - "$tfile" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
ns = os.environ['VERIFY_NS']
t = d['data']['activeTargets']
up = [x for x in t if x['health'] == 'up']
dn = [x for x in t if x['health'] != 'up']
mine = [x for x in dn if x['labels'].get('namespace') == ns]
foreign = [x for x in dn if x['labels'].get('namespace') != ns]
def fmt(xs):
    return '; '.join('%s %s' % (x['labels'].get('job', '?'), x.get('scrapeUrl', '?')) for x in xs[:4])
print('UP=%d' % len(up))
print('DOWN_MINE=%d' % len(mine))
print('DOWN_FOREIGN=%d' % len(foreign))
print('DOWN_MINE_D=%s' % json.dumps(fmt(mine)))
print('DOWN_FOREIGN_D=%s' % json.dumps(fmt(foreign)))
PY
)"
  rm -f "$tfile"
  if [[ "${UP:-0}" -gt 0 ]]; then
    ok "${UP} scrape targets up"
  else
    bad "no scrape targets are up"
  fi
  if [[ "${DOWN_MINE:-0}" -eq 0 ]]; then
    ok "no down targets belonging to this stack"
  else
    bad "${DOWN_MINE} target(s) in the ${NS} namespace are DOWN" "${DOWN_MINE_D}"
  fi
  if [[ "${DOWN_FOREIGN:-0}" -gt 0 ]]; then
    info "${DOWN_FOREIGN} down target(s) outside ${NS} — pre-existing cluster services that advertise"
    info "  prometheus.io/scrape but do not serve metrics. Not caused by this chart: ${DOWN_FOREIGN_D}"
  fi
fi

section "5. VictoriaMetrics — is remote_write actually landing?"

vm_up=$(kexec "curl -s 'http://${RELEASE}-victoriametrics-server:8428/api/v1/query?query=up' | head -c 400")
if echo "$vm_up" | grep -q '"status":"success"' && echo "$vm_up" | grep -q '"result":\[{'; then
  ok "VictoriaMetrics is serving data (query 'up' returned series)"
else
  bad "VictoriaMetrics returned no series for 'up'" \
      "remote_write may not be flowing yet — it takes ~1 min after install. Response: ${vm_up:0:200}"
fi

rows=$(kexec "curl -s 'http://${RELEASE}-victoriametrics-server:8428/api/v1/query?query=sum(vm_rows_inserted_total)' | grep -o '\"value\":\[[0-9.]*,\"[0-9.]*\"\]' | grep -o '\"[0-9.]*\"]' | tr -d '\"]'")
if [[ -n "$rows" ]] && awk "BEGIN{exit !($rows > 0)}" 2>/dev/null; then
  ok "VictoriaMetrics has ingested rows (vm_rows_inserted_total = ${rows%%.*})"
else
  info "could not read vm_rows_inserted_total (non-fatal)"
fi

# The relabeling fix: cAdvisor series must carry a `node` label, or the node
# and pod dashboards cannot group by node.
node_label=$(kexec "curl -s -G --data-urlencode 'query=count by(node) (container_memory_working_set_bytes)' 'http://${RELEASE}-victoriametrics-server:8428/api/v1/query' | head -c 500")
node_count=$(echo "$node_label" | grep -o '"node":"[^"]*"' | sort -u | wc -l)
if [[ "$node_count" -ge 1 ]]; then
  ok "cAdvisor series carry a 'node' label ($node_count distinct node(s))"
else
  bad "cAdvisor series have no 'node' label" \
      "the kubernetes-nodes-cadvisor relabel_configs override did not take effect"
fi

section "6. Loki — are logs arriving?"

labels=$(kexec "curl -s 'http://${RELEASE}-loki:3100/loki/api/v1/labels'")
if echo "$labels" | grep -q '"namespace"' && echo "$labels" | grep -q '"pod"'; then
  ok "Loki knows the 'namespace' and 'pod' labels"
else
  bad "Loki is missing expected labels" "Alloy may not be shipping. Response: ${labels:0:200}"
fi

logq=$(kexec "curl -s -G 'http://${RELEASE}-loki:3100/loki/api/v1/query_range' --data-urlencode 'query={namespace=\"kube-system\"}' --data-urlencode 'limit=5' | head -c 400")
if echo "$logq" | grep -q '"values":\[\['; then
  ok "Loki returns real log lines for {namespace=\"kube-system\"}"
else
  bad "Loki returned no log lines" "Response: ${logq:0:200}"
fi

# Retried rather than asserted once. On a fresh install the DaemonSet members do
# not start shipping simultaneously, so a single check right after `helm install`
# can legitimately see one node before the other. Retrying keeps the assertion
# strict (all nodes must ship) without failing on a startup race.
ln_count=0
for _ in $(seq 1 12); do
  ln_count=$(kexec "curl -s 'http://${RELEASE}-loki:3100/loki/api/v1/label/node/values'" \
    | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("data") or []))
except Exception: print(0)')
  [[ "${ln_count:-0}" -ge "$nodes" ]] && break
  sleep 10
done
if [[ "${ln_count:-0}" -ge "$nodes" ]]; then
  ok "logs arriving from all $ln_count node(s)"
elif [[ "${ln_count:-0}" -gt 0 ]]; then
  bad "logs arriving from only $ln_count of $nodes nodes (waited 120s)" \
      "check the alloy DaemonSet pod on the missing node"
else
  bad "no logs arriving from any node (waited 120s)" "is the alloy DaemonSet running?"
fi

section "7. Grafana — datasources and dashboards"

gsec=$(kubectl get secret -n "$NS" "${RELEASE}-grafana" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)
guser=$(kubectl get secret -n "$NS" "${RELEASE}-grafana" -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d 2>/dev/null)
: "${guser:=admin}"
GA="${guser}:${gsec}"

health=$(kexec "curl -s 'http://${RELEASE}-grafana/api/health'")
if echo "$health" | grep -q '"database": *"ok"'; then
  ok "Grafana is healthy"
else
  bad "Grafana /api/health not ok" "${health:0:200}"
fi

for uid in victoriametrics prometheus loki; do
  ds=$(kexec "curl -s -u '${GA}' 'http://${RELEASE}-grafana/api/datasources/uid/${uid}'")
  if echo "$ds" | grep -q "\"uid\":\"${uid}\""; then
    dh=$(kexec "curl -s -u '${GA}' -X POST 'http://${RELEASE}-grafana/api/datasources/uid/${uid}/health'")
    if echo "$dh" | grep -qi '"status": *"OK"'; then
      ok "datasource '${uid}' provisioned and healthy"
    else
      bad "datasource '${uid}' exists but health check failed" "${dh:0:200}"
    fi
  else
    bad "datasource '${uid}' is missing"
  fi
done

# Alertmanager is checked for existence only. Grafana's built-in alertmanager
# datasource has no backend component, so POSTing to its /health endpoint always
# returns {"messageId":"plugin.unavailable"} even when the datasource is working
# fine in the UI. Asserting health there would be a permanently red check.
ds=$(kexec "curl -s -u '${GA}' 'http://${RELEASE}-grafana/api/datasources/uid/alertmanager'")
if echo "$ds" | grep -q '"uid":"alertmanager"'; then
  ok "datasource 'alertmanager' provisioned (no backend health endpoint; existence only)"
else
  bad "datasource 'alertmanager' is missing"
fi

search=$(kexec "curl -s -u '${GA}' 'http://${RELEASE}-grafana/api/search?type=dash-db'")
for dash in cluster-health nodes pods-workloads logs; do
  if echo "$search" | grep -q "\"uid\":\"${dash}\""; then
    ok "dashboard '${dash}' provisioned"
  else
    bad "dashboard '${dash}' not found in Grafana" "the sidecar may not have picked up its ConfigMap"
  fi
done

section "8. Do the panels actually return data? (via Grafana's datasource proxy)"

# This is the check that distinguishes a working stack from a green-but-empty one.
# Retried, for one specific reason: several of these queries use rate(...[5m]),
# which needs at least TWO scrapes in the window before it can return anything.
# Run immediately after `helm install` the series already exist but every rate()
# query is legitimately empty, which looked like a real failure the first time.
# Retrying keeps the assertion strict while tolerating the warm-up.
check_query() {
  local label="$1" uid="$2" query="$3"
  local out=""
  for _ in $(seq 1 10); do
    out=$(kexec "curl -s -u '${GA}' -G --data-urlencode 'query=${query}' 'http://${RELEASE}-grafana/api/datasources/proxy/uid/${uid}/api/v1/query' | head -c 400")
    if echo "$out" | grep -q '"result":\[{'; then
      ok "$label"
      return
    fi
    sleep 10
  done
  bad "$label returned no data (waited 100s)" "${out:0:180}"
}

check_query "nodes ready count"      victoriametrics 'sum(kube_node_status_condition{condition="Ready",status="true"})'
check_query "per-node CPU (Nodes dashboard)" victoriametrics '100 - (avg by(node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'
check_query "per-node memory"        victoriametrics '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'
check_query "pod memory (Pods dashboard)"    victoriametrics 'sum by(namespace, pod) (container_memory_working_set_bytes{container!="",pod!=""})'
check_query "pod CPU"                victoriametrics 'sum by(namespace, pod) (rate(container_cpu_usage_seconds_total{container!="",pod!=""}[5m]))'
check_query "pod phases"             victoriametrics 'sum by(phase) (kube_pod_status_phase)'
check_query "cluster allocatable"    victoriametrics 'sum(kube_node_status_allocatable{resource="cpu"})'
check_query "deployment readiness"   victoriametrics 'kube_deployment_status_replicas_ready'

# Loki through the same proxy.
lout=$(kexec "curl -s -u '${GA}' -G --data-urlencode 'query={namespace=\"kube-system\"}' --data-urlencode 'limit=5' 'http://${RELEASE}-grafana/api/datasources/proxy/uid/loki/loki/api/v1/query_range' | head -c 400")
if echo "$lout" | grep -q '"values":\[\['; then
  ok "Logs dashboard query returns lines through Grafana"
else
  bad "Logs dashboard query returned nothing through Grafana" "${lout:0:180}"
fi

section "9. External access"

np=$(kubectl get svc -n "$NS" "${RELEASE}-grafana" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [[ -n "$np" ]]; then
  ok "Grafana exposed on NodePort ${np}"
  for ip in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://${ip}:${np}/login" 2>/dev/null)
    if [[ "$code" == "200" || "$code" == "302" ]]; then
      ok "reachable at http://${ip}:${np} (HTTP $code)"
    else
      bad "not reachable at http://${ip}:${np}" "got HTTP ${code:-no response}"
    fi
  done
else
  bad "Grafana service is not a NodePort"
fi

section "10. Clean-uninstall guarantee"

# The Prometheus Operator brings CRDs and Helm never deletes them, so this is
# no longer a "zero CRDs" check. What still has to hold is that every CRD
# present is one `make uninstall` knows to remove: the monitoring.coreos.com
# set. A grafana.com or victoriametrics CRD would be an operator nobody asked
# for, and would genuinely leak on uninstall.
operator_crds=$(kubectl get crd -o name 2>/dev/null | grep -c "monitoring\.coreos\.com" || true)
stray_crds=$(kubectl get crd -o name 2>/dev/null | grep -cE "monitoring\.grafana\.com|victoriametrics" || true)

if [[ "$operator_crds" -eq 10 ]]; then
  ok "10 Prometheus Operator CRDs present, all removed by 'make uninstall'"
else
  bad "expected 10 monitoring.coreos.com CRDs, found $operator_crds" \
      "the operator's CRD set is incomplete; ServiceMonitors may not work"
fi

if [[ "$stray_crds" -eq 0 ]]; then
  ok "no unmanaged CRDs (nothing will leak on uninstall)"
else
  bad "$stray_crds unmanaged CRD(s) present" "make uninstall does not remove these"
fi

# ---------------------------------------------------------------------------
printf "\n%s────────────────────────────────────────%s\n" "$B" "$N"
printf "  %s%d passed%s" "$G" "$PASS" "$N"
if [[ "$FAIL" -gt 0 ]]; then
  printf ", %s%d FAILED%s\n\n" "$R" "$FAIL" "$N"
  for f in "${FAILURES[@]}"; do printf "    %s✘%s %s\n" "$R" "$N" "$f"; done
  printf "\n"
  exit 1
fi
printf ", 0 failed%s\n\n" "$N"
printf "  Everything is flowing. Open Grafana:\n"
printf "    http://192.168.56.134:%s  (admin / %s)\n\n" "${np:-30300}" "${gsec:-admin}"
