# Deploy → Test → Uninstall — Verified Procedure

A single, start-to-finish procedure for the `monitoring-stack` chart, with the
**actual output captured from a real run** so you can compare against what you see.

- **Cluster:** `k8s-ha` — Kubernetes v1.36.3, 2 nodes (`k8s-cp-0`, `k8s-w-0`)
- **Run date:** 2026-08-15
- **Result:** deployed in 1m29s · **35/35 verified** · uninstalled clean
- **Companion doc:** `RUNBOOK.md` (deeper reference — design rationale, traps, troubleshooting)

Everything below was executed in order. Nothing is aspirational.

---

## 0. Preconditions

```bash
cd /root/prom-grafana-loki-vectoria

kubectl config current-context          # kubernetes-admin@k8s-ha
kubectl get nodes                       # both nodes Ready
ls monitoring-stack/charts/             # 5 .tgz files must be present
```

**Observed:**

```
  k8s-cp-0     Ready
  k8s-w-0      Ready
  monitoring ns: absent (clean slate)

alloy-1.11.1.tgz  grafana-10.5.15.tgz  loki-7.3.0.tgz
prometheus-29.24.0.tgz  victoria-metrics-single-0.44.0.tgz
```

If `charts/` is empty, vendor the dependencies first — needs internet, once only:

```bash
make deps
```

---

## STEP 1 — Pre-flight

```bash
make lint
make dryrun
```

**Observed:**

```
==> Linting monitoring-stack
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed

server-side dry run OK
CRDs this chart would create (must be 0): 0
```

`make dryrun` validates the rendered manifests against the **live** API server,
so it catches schema errors `helm template` alone cannot. The CRD count must be
`0` — that is what makes the uninstall in step 5 leave nothing behind.

---

## STEP 2 — Deploy

```bash
make install
```

Runs:

```bash
helm install monitoring ./monitoring-stack \
  --namespace monitoring --create-namespace \
  --wait --timeout 15m
```

**Observed — between 1m29s and 1m59s across four runs:**

```
NAME: monitoring
LAST DEPLOYED: Sat Aug 15 01:28:41 2026
NAMESPACE: monitoring
STATUS: deployed
REVISION: 1
```

`REVISION: 1` and `STATUS: deployed` are the parts that must match. Treat the
duration as **~1–2 minutes**; it varies with image cache and how busy the cluster
is.

> The release **must** be named `monitoring`. The chart refuses to render under
> any other name, because the cross-component service URLs are hardcoded in
> `values.yaml` (Helm cannot template a values file) and a different name would
> start every pod successfully while leaving every dashboard silently empty.

### 2a. Confirm what came up

```bash
kubectl get pods -n monitoring -o wide
kubectl get pvc  -n monitoring
kubectl get ds   -n monitoring
```

**Observed — 10 pods, spread across both nodes:**

```
monitoring-alertmanager-0                        1/1  Running  k8s-cp-0
monitoring-alloy-7fmrf                           2/2  Running  k8s-w-0
monitoring-alloy-9z7pk                           2/2  Running  k8s-cp-0
monitoring-grafana-77cbbcf6c4-g9mlp              2/2  Running  k8s-w-0
monitoring-kube-state-metrics-79b4f7bf9f-9szvm   1/1  Running  k8s-w-0
monitoring-loki-0                                2/2  Running  k8s-w-0
monitoring-prometheus-node-exporter-4kp8w        1/1  Running  k8s-w-0
monitoring-prometheus-node-exporter-58zkx        1/1  Running  k8s-cp-0
monitoring-prometheus-server-55c6795cf6-n6vzq    2/2  Running  k8s-w-0
monitoring-victoriametrics-server-0              1/1  Running  k8s-cp-0
```

**4 PVCs, all Bound:**

```
monitoring-grafana                                   Bound  2Gi
monitoring-prometheus-server                         Bound  5Gi
server-volume-monitoring-victoriametrics-server-0    Bound  10Gi
storage-monitoring-loki-0                            Bound  10Gi
```

**Both DaemonSets at 2/2 — the single most important check:**

```
monitoring-alloy                         desired=2 ready=2
monitoring-prometheus-node-exporter      desired=2 ready=2
```

`2/2` proves the tainted control-plane node (`node-role.kubernetes.io/control-plane:NoSchedule`)
is being monitored. A persistent `1/2` means a toleration is missing and that node
is invisible in every dashboard.

> **A brief `1/2` right after install is normal, not a failure.** Alloy's
> readiness probe hits `:12345/-/ready`, and on a busy cluster it can time out
> while Alloy is still discovering and opening log tailers — so readiness may flap
> for a few seconds *after* `helm install --wait` has already returned. Observed
> on one run: `ready=1` immediately after install, `ready=2` ten seconds later.
> Re-check before treating it as broken:
>
> ```bash
> kubectl get ds -n monitoring -w
> ```
>
> If it is genuinely stuck, confirm the container is actually working before
> blaming tolerations — it may be running fine with only the probe failing:
>
> ```bash
> kubectl logs -n monitoring <alloy-pod> -c alloy --tail=20   # "start tailing file" lines
> ```

### 2b. Wait for the pipelines — do not test immediately

Pods reach `Running` well before data arrives. Prometheus must scrape, then
`remote_write` into VictoriaMetrics; Alloy must discover and tail log files. Allow
**2–3 minutes**, or block on the actual conditions:

```bash
kubectl run w2 -n monitoring --image=curlimages/curl:8.11.1 \
  --restart=Never --command -- sleep 900
kubectl wait --for=condition=Ready pod/w2 -n monitoring --timeout=180s

# metrics landed, with the node label the dashboards group by
until kubectl exec -n monitoring w2 -- curl -s -G \
  --data-urlencode 'query=count by(node) (container_memory_working_set_bytes)' \
  "http://monitoring-victoriametrics-server:8428/api/v1/query" \
  | grep -q '"node"'; do sleep 10; done

# logs landed, from BOTH nodes
# (the try/except matters: early on Loki may return an empty body, and an
#  unguarded json.load would print a JSONDecodeError plus a bash
#  "[: : integer expected" error on every iteration until it comes up)
until [ "$(kubectl exec -n monitoring w2 -- curl -s \
  "http://monitoring-loki:3100/loki/api/v1/label/node/values" \
  | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("data") or []))
except Exception: print(0)')" -ge 2 ]; \
  do sleep 10; done

kubectl delete pod w2 -n monitoring --wait=false
```

**Observed:**

```
  ✅ metrics flowing
  ✅ logs flowing from both nodes
```

---

## STEP 3 — Open Grafana

```
http://192.168.56.134:30300        (k8s-cp-0)
http://192.168.56.135:30300        (k8s-w-0 — either works)

user:     admin
password: admin        ← lab default; change grafana.adminPassword
```

```bash
make url        # URL + live password from the secret
```

Four dashboards are already provisioned — nothing to import:

| Dashboard | Panels | Filters |
|---|---|---|
| **Cluster Health** (home) | 15 | — |
| **Nodes** | 16 | `$node` |
| **Pods & Workloads** | 12 | `$namespace`, `$pod` |
| **Logs** | 10 | `$namespace`, `$pod`, `$search` |

Four datasources, bound by fixed UID: `victoriametrics` (default), `prometheus`,
`loki`, `alertmanager`.

Nine alert rules under **Alerting**, all loaded healthy:

```
  monitoring-stack   PrometheusTargetDown   health=ok
  monitoring-stack   RemoteWriteFailing     health=ok
  nodes              NodeNotReady           health=ok
  nodes              NodeHighCPU            health=ok
  nodes              NodeHighMemory         health=ok
  nodes              NodeDiskFillingUp      health=ok
  pods               PodCrashLooping        health=ok
  pods               PodNotReady            health=ok
  pods               ContainerOOMKilled     health=ok
```

No notification receivers are configured — alerts are visible, nothing pages you.

---

## STEP 4 — Test

```bash
make test
```

35 assertions. This is deliberately **not** a smoke test: a stack where every pod
is `Running` and every dashboard is empty looks perfectly healthy to `kubectl`, so
each check queries a real API and asserts on the response.

**Observed — full output, 35 passed / 0 failed:**

```
── 1. Workloads
  ✔ all pods Running (12 total)
  ✔ all containers ready

── 2. Storage
  ✔ 4/4 PVCs Bound

── 3. Node coverage (the tainted control-plane node must be included)
  ✔ daemonset monitoring-alloy covers all 2 nodes (2/2)
  ✔ daemonset monitoring-prometheus-node-exporter covers all 2 nodes (2/2)

── 4. Prometheus — scraping
  ✔ 17 scrape targets up
  ✔ no down targets belonging to this stack
  · 1 down target(s) outside monitoring — pre-existing cluster services that advertise
  ·   prometheus.io/scrape but do not serve metrics. Not caused by this chart:
  ·   kubernetes-service-endpoints http://10.244.183.138:9094/metrics

── 5. VictoriaMetrics — is remote_write actually landing?
  ✔ VictoriaMetrics is serving data (query 'up' returned series)
  ✔ VictoriaMetrics has ingested rows (vm_rows_inserted_total = 151138)
  ✔ cAdvisor series carry a 'node' label (2 distinct node(s))

── 6. Loki — are logs arriving?
  ✔ Loki knows the 'namespace' and 'pod' labels
  ✔ Loki returns real log lines for {namespace="kube-system"}
  ✔ logs arriving from all 2 node(s)

── 7. Grafana — datasources and dashboards
  ✔ Grafana is healthy
  ✔ datasource 'victoriametrics' provisioned and healthy
  ✔ datasource 'prometheus' provisioned and healthy
  ✔ datasource 'loki' provisioned and healthy
  ✔ datasource 'alertmanager' provisioned (no backend health endpoint; existence only)
  ✔ dashboard 'cluster-health' provisioned
  ✔ dashboard 'nodes' provisioned
  ✔ dashboard 'pods-workloads' provisioned
  ✔ dashboard 'logs' provisioned

── 8. Do the panels actually return data? (via Grafana's datasource proxy)
  ✔ nodes ready count
  ✔ per-node CPU (Nodes dashboard)
  ✔ per-node memory
  ✔ pod memory (Pods dashboard)
  ✔ pod CPU
  ✔ pod phases
  ✔ cluster allocatable
  ✔ deployment readiness
  ✔ Logs dashboard query returns lines through Grafana

── 9. External access
  ✔ Grafana exposed on NodePort 30300
  ✔ reachable at http://192.168.56.134:30300 (HTTP 200)
  ✔ reachable at http://192.168.56.135:30300 (HTTP 200)

── 10. Clean-uninstall guarantee
  ✔ no monitoring CRDs installed (uninstall will leave nothing behind)

────────────────────────────────────────
  35 passed, 0 failed
```

### Two notes on that output

**The pod count is not 10.** It has read 11 and 12 across runs, because it
includes `verify.sh`'s own short-lived helper pod plus any leftover diagnostic
pod. The **10 stack pods** are what matter; anything above that is scaffolding.

**The one informational line is expected and is not this chart's fault.**
`calico-kube-controllers` (`10.244.183.138:9094`, namespace `calico-system`) is a
pre-existing cluster service that advertises `prometheus.io/scrape: true` but does
not serve metrics on that port. `PrometheusTargetDown` will eventually fire for
it. That is true information about the cluster, so the rule is not silenced;
`verify.sh` reports foreign-namespace targets separately and does not count them
as failures. To stop it: fix the annotation on that service, or narrow the
`PrometheusTargetDown` expression in `values.yaml`.

### Section 8 is the check that matters most

It replays each dashboard's key query through Grafana's own datasource proxy and
asserts a non-empty result. Sections 1–7 can all pass while the dashboards render
blank; section 8 is what proves a panel will actually draw something.

### Measured footprint while running

```
  memory: 1114 MiB
  cpu: 1.40 cores
  distinct metric names: 1698
  loki labels: app, container, filename, instance, job, level,
               namespace, node, pod, service_name, stream
```

The presence of `pod`, `container`, `node` and `level` in that label list is the
proof that log collection is fully wired. If you only see `instance`, `job`,
`namespace`, `service_name`, then Alloy is tailing zero files and only the
Kubernetes-events stream is working — see the `__path__` trap in `RUNBOOK.md`.

---

## STEP 5 — Uninstall

```bash
make uninstall
```

Runs **both** commands, then verifies:

```bash
helm uninstall monitoring -n monitoring
kubectl delete ns monitoring
```

**Observed:**

```
release "monitoring" uninstalled
namespace "monitoring" deleted

removed. verifying nothing was left behind:
  cluster-scoped objects owned by this release: 0
  orphaned PVs from our namespace:              0
  CRDs added by this chart:                     0

  all three should be 0.
```

**Cluster state after:**

```
helm releases:  0
namespace:      gone
nodes:          k8s-cp-0 Ready, k8s-w-0 Ready
```

### Do not judge cleanup by absolute PV or CRD counts

One run showed `PVs 9 → 5` and `CRDs 45 → 45`, which is tempting to quote as the
expected result. It is not reliable — **other workloads share this cluster**
(`argocd`, `velero`, `velero-demo`, `velero-ui`, `minio`), and they create and
release PVs and CRDs independently of anything done here. Observed noise:

- one raw-uninstall run went `PVs 4 → 5`, an *increase*, entirely from a Velero
  demo creating static PVs while the uninstall ran
- the total CRD count moved 45 → 48 → 36 across the session with no involvement
  from this chart

Judge cleanup only by the **namespace- and ownership-scoped** checks, which is what
`make uninstall` prints and what actually held true on every run:

```bash
# all three must be 0
kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/instance=monitoring -o name | wc -l
kubectl get pv -o json | python3 -c "import json,sys; print(sum(1 for p in json.load(sys.stdin)['items'] if (p['spec'].get('claimRef') or {}).get('namespace')=='monitoring'))"
kubectl get crd -o name | grep -cE "monitoring\.grafana\.com|victoriametrics"
```

### Why two commands are needed

Helm does not own the PVC that VictoriaMetrics' StatefulSet creates via its
`volumeClaimTemplate`, so `helm uninstall` alone leaves a 10 GiB volume behind.
Deleting the namespace reclaims it. (Loki's StatefulSet sets
`enableStatefulSetAutoDeletePVC: true` and does clean itself up — deleting the
namespace covers both cases without you needing to remember which is which.)

### Why the residue check uses labels, not names

It matches `app.kubernetes.io/instance=monitoring`. Kubernetes ships **built-in**
`system:monitoring` ClusterRole and ClusterRoleBinding objects
(`kubernetes.io/bootstrapping: rbac-defaults`) that have nothing to do with this
chart; a name-substring check would report them as false leftovers forever.

### What is NOT removed

The chart source. `Makefile`, `README.md`, `RUNBOOK.md`, this file,
`monitoring-stack/` and `scripts/` all stay on disk. To remove those too:

```bash
make clean                                 # drop vendored .tgz + Chart.lock only
rm -rf /root/prom-grafana-loki-vectoria    # everything, incl. these docs
```

---

## The whole cycle, condensed

```bash
cd /root/prom-grafana-loki-vectoria

make deps        # once, needs internet
make lint        # 0 charts failed
make dryrun      # "server-side dry run OK" + "CRDs: 0"
make install     # ~1m30s
                 # wait 2-3 min for data
make test        # expect: 35 passed, 0 failed
make uninstall   # expect: three zeroes
```

Round trip: roughly **6 minutes** including the wait for data.

---

## Quick failure triage

| Symptom | Cause | Fix |
|---|---|---|
| A DaemonSet reads `1/2` | Missing control-plane toleration | `tolerations: [{operator: Exists}]` |
| PVCs stuck `Pending` | `local-path-provisioner` not Running | It needs a schedulable worker (no CP toleration) |
| Stateful pod `Pending` after reboot | `local-path` volumes are node-local | Bring that node back; unavoidable |
| Dashboards empty, pods healthy | Pipeline not flowing yet, or a wrong service URL | `make test` names the broken link |
| Loki has no `pod`/`node`/`level` labels | Alloy `__path__` broken, tailing 0 files | See the Go-regexp `${1}_${2}_${3}` trap in `RUNBOOK.md` |
| `helm install` refuses to render | Release not named `monitoring` | Use that name, or override the URLs it lists |
| Empty/contradictory verify results | `kubectl run --rm` per query races output capture | `verify.sh` uses one persistent helper pod |
| Alertmanager datasource health fails | It has no backend component | Expected; existence-only check |

Deeper context for every one of these is in `RUNBOOK.md`.
