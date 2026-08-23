# monitoring-stack — Complete Runbook

Everything needed to deploy, verify, and remove the observability stack on the
`k8s-ha` cluster. This is the single reference: setup, install, verification,
teardown, the traps that cost real debugging time, and the exact configuration
that makes it work.

- **Stack:** Prometheus (scraper) → VictoriaMetrics (storage) + Alloy → Loki (logs) + Grafana (UI) + Alertmanager
- **Location:** `/root/prom-grafana-loki-vectoria`
- **Status:** built, deployed, verified 35/35, uninstall-tested, then torn down
- **Last verified:** 2026-08-15 on Kubernetes v1.36.3

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Cluster facts that shaped the design](#2-cluster-facts-that-shaped-the-design)
3. [File layout](#3-file-layout)
4. [Setup — one time](#4-setup--one-time)
5. [Deploy](#5-deploy)
6. [Access Grafana](#6-access-grafana)
7. [Verify](#7-verify)
8. [Uninstall / destroy](#8-uninstall--destroy)
9. [Upgrade / change config](#9-upgrade--change-config)
10. [The four traps](#10-the-four-traps-read-before-editing)
11. [Critical configuration](#11-critical-configuration-do-not-break-these)
12. [Troubleshooting](#12-troubleshooting)
13. [Known limitations](#13-known-limitations)
14. [Full command reference](#14-full-command-reference)

---

## 1. Prerequisites

| Requirement | Verified value |
|---|---|
| Kubernetes | v1.36.3 |
| `kubectl` | v1.36.3, working kubeconfig at `~/.kube/config` |
| `helm` | v3.21.3 |
| `python3` | used by `make uninstall` and `scripts/verify.sh` |
| Default StorageClass | `local-path` (WaitForFirstConsumer) |
| Internet access | needed once, for `make deps` only |
| Free capacity | ~1.3 GiB RAM, ~1 CPU, 27 GiB disk |

Context must point at the right cluster:

```bash
kubectl config current-context      # expect: kubernetes-admin@k8s-ha
kubectl get nodes
```

---

## 2. Cluster facts that shaped the design

These are why the chart looks the way it does. If you move it to another cluster,
re-check each one.

| Fact | Consequence in the chart |
|---|---|
| `k8s-cp-0` carries `node-role.kubernetes.io/control-plane:NoSchedule` | Both DaemonSets use `tolerations: [{operator: Exists}]`, or that node is invisible in every dashboard |
| `k8s-w-0` flapped `NotReady` twice (lab VM suspend/resume) | Every single-instance component also tolerates the control-plane taint, so the stack survives losing the worker |
| `local-path` is the only StorageClass, `allowVolumeExpansion: false` | PVC sizes are permanent; volumes are node-local |
| `local-path-provisioner` has no control-plane toleration | PVC provisioning needs at least one schedulable worker |
| scheduler + controller-manager bind `--bind-address=127.0.0.1` | No scrape jobs for them — avoids permanently-red targets |
| kubelet + cAdvisor reachable | Node and pod metrics work with no extra setup |
| Helm never deletes CRDs on uninstall | `make uninstall` deletes the operator's 10 CRDs by name; Alloy's CRD subchart stays force-disabled |
| 8 CPU / 7.4 GiB per node | Loki's default 8 GiB memcached had to be disabled |

---

## 3. File layout

```
/root/prom-grafana-loki-vectoria/
├── RUNBOOK.md                          this file
├── README.md                           user-facing overview
├── Makefile                            deps / install / test / uninstall
├── scripts/verify.sh                   36 end-to-end assertions
└── monitoring-stack/
    ├── Chart.yaml                      umbrella + 5 pinned deps
    ├── Chart.lock                       resolved dependency versions
    ├── values.yaml                     ALL configuration (702 lines, commented)
    ├── charts/*.tgz                    vendored subcharts (from `make deps`)
    ├── templates/
    │   ├── _helpers.tpl                labels + release-name guard
    │   ├── grafana-dashboards.yaml     one ConfigMap per dashboards/*.json
    │   └── NOTES.txt                   post-install access info
    └── dashboards/
        ├── cluster-health.json         15 panels
        ├── nodes.json                  16 panels
        ├── pods-workloads.json         12 panels
        └── logs.json                   10 panels
```

### Pinned versions

| Chart | Repo | Chart version | App version |
|---|---|---|---|
| `kube-prometheus-stack` | prometheus-community | 88.5.3 | operator v0.93.1 / prom v3.14.0 |
| `victoria-metrics-single` (alias `victoriametrics`) | vm | 0.44.0 | v1.149.0 |
| `loki` | grafana | 7.3.0 | 3.6.12 |
| `alloy` | grafana | 1.11.1 | v1.18.1 |
| `grafana` | grafana | 10.5.15 | 12.3.1 |

The `prometheus` chart also brings `kube-state-metrics`, `prometheus-node-exporter`
and `alertmanager` as its own subcharts — one dependency covers scraping, cluster
object state, node metrics and alerting. `prometheus-pushgateway` ships enabled by
default and is turned off.

---

## 4. Setup — one time

Adds the three Helm repos and vendors the subcharts into `monitoring-stack/charts/`.

```bash
cd /root/prom-grafana-loki-vectoria
make deps
```

Equivalent manual commands:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add vm https://victoriametrics.github.io/helm-charts
helm repo update prometheus-community grafana vm
cd monitoring-stack && helm dependency build
```

> **Important:** after extracting or inspecting a `.tgz` inside `charts/`, delete
> the extracted directory. Helm reads **both** `.tgz` files and directories in
> `charts/`, so leaving both loads every subchart twice.

### Pre-flight checks

```bash
make lint      # helm lint (waives the release-name guard, see trap 4)
make template  # render all manifests to stdout
make dryrun    # render AND validate against the live API + count CRDs
```

`make dryrun` must print:

```
server-side dry run OK
CRDs this chart installs (expected 10): 10
```

---

## 5. Deploy

```bash
make install
```

which runs:

```bash
helm install monitoring ./monitoring-stack \
  --namespace monitoring --create-namespace \
  --wait --timeout 15m
```

Takes about **1 minute** to install; allow **2–3 minutes** more before dashboards
fill in (Prometheus must scrape, then `remote_write` into VictoriaMetrics, and
Alloy must discover and tail log files).

### Expected result — 10 pods

```
monitoring-alertmanager-0                        1/1  Running
monitoring-alloy-<id>                            2/2  Running   (k8s-w-0)
monitoring-alloy-<id>                            2/2  Running   (k8s-cp-0)
monitoring-grafana-<id>                          2/2  Running
monitoring-kube-state-metrics-<id>               1/1  Running
monitoring-loki-0                                2/2  Running
monitoring-prometheus-node-exporter-<id>         1/1  Running   (k8s-w-0)
monitoring-prometheus-node-exporter-<id>         1/1  Running   (k8s-cp-0)
prometheus-monitoring-kube-prometheus-prometheus-0   2/2  Running
monitoring-victoriametrics-server-0              1/1  Running
```

### Expected 4 PVCs, all Bound

| PVC | Size |
|---|---|
| `monitoring-grafana` | 2Gi |
| `prometheus-monitoring-kube-prometheus-prometheus-db-...-0` | 5Gi |
| `server-volume-monitoring-victoriametrics-server-0` | 10Gi |
| `storage-monitoring-loki-0` | 10Gi |

### Both DaemonSets must read 2/2

```bash
kubectl get ds -n monitoring
```

This is the single most important check: `2/2` proves the tainted control-plane
node is being monitored. `1/2` means a toleration is missing.

### Measured footprint once running

~1265 MiB memory, ~0.90 CPU cores, 1702 distinct metric names stored.

---

## 6. Access Grafana

```
http://192.168.56.134:30300      (k8s-cp-0)
http://192.168.56.135:30300      (k8s-w-0 — either works)

user:     admin
password: admin
```

```bash
make url        # prints URL + live password from the secret
make password   # password only
```

> **Change `grafana.adminPassword` in `values.yaml` before using this anywhere
> that matters.** `admin/admin` is a lab default.

No port-forward needed. If you prefer one anyway:

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

### The four dashboards (provisioned automatically, no import)

| Dashboard | UID | Contents |
|---|---|---|
| **Cluster Health** | `cluster-health` | nodes ready, pods by phase, CPU/mem utilisation, requests vs allocatable, restarts, firing alerts, deployment readiness. Also the home dashboard. |
| **Nodes** | `nodes` | per-node CPU by mode, memory, disk fill, disk I/O, network, load vs core count, uptime, inventory. `$node` filter. |
| **Pods & Workloads** | `pods-workloads` | per-pod CPU/memory/network, restarts, top consumers, waiting/terminated reason table. `$namespace` + `$pod` filters. |
| **Logs** | `logs` | live logs from every node, log volume by level, noisiest pods, errors-only panel. `$namespace` + `$pod` + `$search` filters. |

### Datasources (fixed UIDs — dashboards bind to these)

| Name | UID | URL |
|---|---|---|
| VictoriaMetrics *(default)* | `victoriametrics` | `http://monitoring-victoriametrics-server:8428` |
| Prometheus | `prometheus` | `http://monitoring-kube-prometheus-prometheus:9090` |
| Loki | `loki` | `http://monitoring-loki:3100` |
| Alertmanager | `alertmanager` | `http://monitoring-kube-prometheus-alertmanager:9093` |

Renaming any UID breaks every panel bound to it.

### Alerting

9 rules under **Alerting** in Grafana: `NodeNotReady`, `NodeHighCPU`,
`NodeHighMemory`, `NodeDiskFillingUp`, `PodCrashLooping`, `PodNotReady`,
`ContainerOOMKilled`, `PrometheusTargetDown`, `RemoteWriteFailing`.

**No notification receivers are configured** — nothing will page you. Add one
under `prometheus.alertmanager.config` in `values.yaml` if you want that.

---

## 7. Verify

```bash
make test
```

36 assertions. This is not a smoke test — it proves data is *flowing*, because a
stack where every pod is `Running` and every dashboard is empty looks perfectly
healthy to `kubectl`.

What it checks:

| Section | Assertions |
|---|---|
| 1. Workloads | all pods Running, all containers ready |
| 2. Storage | all 4 PVCs Bound |
| 3. Node coverage | both DaemonSets at 2/2 (the taint-toleration proof) |
| 4. Prometheus | targets up; **no down targets belonging to this stack** |
| 5. VictoriaMetrics | `up` returns series, `vm_rows_inserted_total` rising, **cAdvisor series carry a `node` label** |
| 6. Loki | `namespace`/`pod` labels exist, real log lines returned, **logs from every node** (retried up to 120s) |
| 7. Grafana | healthy, 4 datasources, 4 dashboards provisioned |
| 8. Panel data | **each dashboard's key query replayed through Grafana's datasource proxy returns non-empty data** ← catches a green-but-empty stack |
| 9. External access | NodePort answers HTTP 200 from both node IPs |
| 10. Clean uninstall | exactly the operator's 10 CRDs present, no unmanaged CRD leaked |

Expected output ends with:

```
  36 passed, 0 failed

  Everything is flowing. Open Grafana:
    http://192.168.56.134:30300  (admin / admin)
```

### Manual spot checks

```bash
make status     # pods + PVCs + DaemonSet coverage

# temporary in-cluster curl pod for ad-hoc queries
kubectl run q -n monitoring --image=curlimages/curl:8.11.1 --restart=Never --command -- sleep 600
kubectl wait --for=condition=Ready pod/q -n monitoring --timeout=120s

# is remote_write landing?
kubectl exec -n monitoring q -- curl -s \
  'http://monitoring-victoriametrics-server:8428/api/v1/query?query=count(up)'

# do cAdvisor series carry the node label? (must list BOTH nodes)
kubectl exec -n monitoring q -- curl -s -G \
  --data-urlencode 'query=count by(node) (container_memory_working_set_bytes)' \
  'http://monitoring-victoriametrics-server:8428/api/v1/query'

# are logs arriving from both nodes?
kubectl exec -n monitoring q -- curl -s \
  'http://monitoring-loki:3100/loki/api/v1/label/node/values'

# scrape target health
kubectl exec -n monitoring q -- curl -s \
  'http://monitoring-kube-prometheus-prometheus:9090/api/v1/targets?state=active'

# alert rules loaded?
kubectl exec -n monitoring q -- curl -s \
  'http://monitoring-kube-prometheus-prometheus:9090/api/v1/rules'

kubectl delete pod q -n monitoring --wait=false
```

How many log files each Alloy pod is tailing (0 means log collection is broken):

```bash
IP=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=alloy \
      -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n monitoring q -- curl -s "http://$IP:12345/metrics" \
  | grep loki_source_file_files_active_total
```

---

## 8. Uninstall / destroy

```bash
make uninstall
```

which runs **both** of these, then verifies:

```bash
helm uninstall monitoring -n monitoring
kubectl delete ns monitoring
```

### Why two commands are required

Helm does not own the PVC that VictoriaMetrics' StatefulSet creates through its
`volumeClaimTemplate`, so `helm uninstall` alone leaves a 10 GiB volume behind.
Deleting the namespace reclaims it.

Loki's StatefulSet does set `enableStatefulSetAutoDeletePVC: true`, so that one
cleans itself up — but deleting the namespace covers both cases without you
having to remember which is which.

### Verified clean-teardown result

```
  cluster-scoped objects owned by this release: 0
  orphaned PVs from our namespace:              0
  CRDs added by this chart:                     0
```

`make uninstall` checks ownership by the `app.kubernetes.io/instance` label, not
by name substring — Kubernetes ships built-in `system:monitoring` ClusterRole and
ClusterRoleBinding objects (`kubernetes.io/bootstrapping: rbac-defaults`) that
have nothing to do with this chart and would otherwise show as false leftovers.

### Full destroy including the chart source

The chart directory is *not* touched by `make uninstall`. To remove it too:

```bash
make clean                                   # drop vendored .tgz + Chart.lock only
rm -rf /root/prom-grafana-loki-vectoria      # everything, including this runbook
```

### Rebuild from scratch after a full destroy

```bash
make deps && make install && make test
```

Measured: fresh install completes in **58 seconds**, then 36/36 once data flows.

---

## 9. Upgrade / change config

All configuration is in `monitoring-stack/values.yaml`, grouped per component.

```bash
vi monitoring-stack/values.yaml
make upgrade      # helm upgrade --wait
```

Most likely knobs:

| Value | Default | Notes |
|---|---|---|
| `grafana.adminPassword` | `admin` | change this |
| `grafana.service.nodePort` | `30300` | Grafana port on both nodes |
| `victoriametrics.server.retentionPeriod` | `15d` | a bare number means **months** to VictoriaMetrics — keep the `d` |
| `victoriametrics.server.persistentVolume.size` | `10Gi` | cannot be grown later |
| `loki.loki.limits_config.retention_period` | `168h` | 7 days of logs |
| `prometheus.server.retention` | `6h` | local only; VM holds long history |
| `<component>.enabled` | `true` | any of the 5 components can be switched off |

### ConfigMap-only changes do not restart pods

Changing Alloy's config, Prometheus' scrape config or the dashboards updates a
ConfigMap. The pods are not recreated, and the kubelet takes up to ~60–90 seconds
to refresh the mounted volume. Alloy and Prometheus both run a config-reloader
sidecar that then reloads in place.

So after `make upgrade`, wait for the change to actually land before concluding it
did not work:

```bash
kubectl exec -n monitoring <alloy-pod> -c alloy -- cat /etc/alloy/config.alloy
kubectl logs -n monitoring <alloy-pod> -c config-reloader --tail=5
```

---

## 10. The four traps (read before editing)

Each of these fails **silently** — the deployment looks healthy and the data is
wrong or absent. Three cost real debugging time during the build.

### Trap 1 — Alloy installs a CRD by default

`alloy/values.yaml` has `crds.create: true` and ships a `crds` subchart for the
`monitoring.grafana.com` `PodLogs` CRD. Helm **never** deletes CRDs on uninstall,
so this quietly defeats the clean-removal requirement. `make uninstall` only
removes `monitoring.coreos.com` CRDs, so Alloy's would be left behind.

```yaml
alloy:
  crds:
    create: false      # never turn this on
```

`make test` asserts that no `monitoring.grafana.com` CRD exists, so it cannot
regress. Note the reasoning shifted once the chart adopted the Prometheus
Operator: CRDs are no longer forbidden outright, but every CRD present must be
one `make uninstall` knows to delete. Alloy's is not, so it stays off.

### Trap 2 — Loki's defaults cannot fit this cluster

The chart defaults to a scalable cloud layout. Two problems:

- `chunksCache.allocatedMemory: 8192` — an **8 GiB memcached**, enabled by
  default, plus a 1 GiB `resultsCache`. On a 7.4 GiB node this alone never
  schedules; the install hangs on Pending pods.
- `deploymentMode: SimpleScalable` runs read/write/backend at 3 replicas each and
  expects S3-compatible object storage.

Required overrides are all in `values.yaml` under `loki:` — `SingleBinary`,
`singleBinary.replicas: 1`, read/write/backend at `0`, **both caches disabled**,
`storage.type: filesystem`, `commonConfig.replication_factor: 1`,
`auth_enabled: false`, and an **explicit `schemaConfig`** (tsdb / v13) because it
defaults to `{}` and the chart refuses to render without it.

### Trap 3 — Go regexp `$1_` is a group *named* `1_`

This is the one that produced a healthy-looking stack collecting zero pod logs.

Alloy's `__path__` is built by joining four labels and reformatting them. Two
things must be right, and both fail silently — every component still reports
`healthy`, the `kubernetes_events` stream keeps working, and only the pod-log
files are missing, so it looks like a partial success rather than a broken config:

```alloy
rule {
  source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_name",
                   "__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
  separator     = "/"
  regex         = "(.+)/(.+)/(.+)/(.+)"          # 1. REQUIRED
  action        = "replace"
  replacement   = "/var/log/pods/${1}_${2}_${3}/${4}/*.log"   # 2. BRACES REQUIRED
  target_label  = "__path__"
}
```

1. Without an explicit `regex`, a relabel rule defaults to `(.*)`, which captures
   the whole joined string as group 1 and leaves groups 2–4 empty.
2. Go's regexp expansion reads `$1_` as a group **named** `1_` — a name greedily
   consumes letters, digits and underscores. Written `$1_$2_$3` the path silently
   collapses to just the pod UID. `${1}_${2}_${3}` is the only correct form.

Symptom to look for: `loki_source_file_files_active_total` is `0`, and Loki has
only `instance`, `job`, `namespace`, `service_name` labels — no `pod`,
`container`, `node` or `level`.

Related: the Alloy chart injects `HOSTNAME` from `spec.nodeName`, so
`sys.env("HOSTNAME")` in the config is the **node** name, not the pod name. That
is what makes the per-node `keep` rule correct. (`env()` also works but is
deprecated in Alloy 1.18.)

### Trap 4 — hardcoded service names + the release-name guard

Helm cannot template a values file, so the cross-component URLs are written out
literally: Prometheus' `remote_write` target, the three Grafana datasource URLs,
and Alloy's `loki.write` endpoint.

The actual rendered names are **not** what you would guess:

| Guess | Actual |
|---|---|
| `monitoring-victoriametrics` | **`monitoring-victoriametrics-server`** |
| `monitoring-prometheus-alertmanager` | **`monitoring-alertmanager`** |
| `monitoring-loki` | `monitoring-loki` ✓ |
| `monitoring-prometheus-server` | `monitoring-prometheus-server` ✓ |

Get one wrong and every pod starts fine while the dashboards stay silently empty.
Always confirm with:

```bash
helm template monitoring ./monitoring-stack -n monitoring | grep -A3 "^kind: Service"
```

Because the same failure mode applies to the release name, `templates/_helpers.tpl`
makes the chart **refuse to render** under any name other than `monitoring`, and
prints which values to override if you want a different one.

`helm lint` hardcodes the release name to `test-release` and has no
`--name-template` flag, so linting waives the guard:

```bash
helm lint monitoring-stack --set skipReleaseNameCheck=true
```

That flag exists for linting only — never for a real install.

---

## 11. Critical configuration (do not break these)

### The `node` label on cAdvisor metrics

The `prometheus` chart keeps scrape jobs in a top-level `scrapeConfigs` **dict**
keyed by job name, each with its own `enabled` flag. `extraScrapeConfigs` is not
needed.

- `kubernetes-service-endpoints` **already** ends with
  `__meta_kubernetes_pod_node_name → node`, so node-exporter and
  kube-state-metrics get a `node` label for free — no change needed there.
- `kubernetes-nodes` and `kubernetes-nodes-cadvisor` only do
  `labelmap __meta_kubernetes_node_label_(.+)` and have **no `node` label**.
  These are the two jobs that need the addition:

```yaml
- source_labels: [__meta_kubernetes_node_name]
  target_label: node
```

Without it, no dashboard can group by node name.

> **Helm replaces lists, it does not merge them.** Overriding a job's
> `relabel_configs` means restating the chart's original entries *and* adding
> yours. Copy, do not append.

### remote_write

```yaml
prometheus:
  server:
    retention: 6h        # Prometheus is the scraper; VM is the store
    remoteWrite:
      - url: http://monitoring-victoriametrics-server:8428/api/v1/write
```

### Tolerations

```yaml
# DaemonSets (node-exporter, alloy) — must cover the tainted control-plane node
tolerations:
  - operator: Exists

# everything else — so the stack survives losing k8s-w-0
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

### Grafana dashboard sidecar

`sidecar.dashboards.searchNamespace` is deliberately **left unset**. The chart
only injects the `NAMESPACE` env var `{{- with .searchNamespace }}`, and
k8s-sidecar then defaults to its own namespace — which is where the dashboard
ConfigMaps live. Note the chart does `. | join ","`, so the key expects a **list**;
the commonly-copied `searchNamespace: ALL` string fails to render.

Dashboards are provisioned from ConfigMaps generated by
`templates/grafana-dashboards.yaml` via `.Files.Glob`, labelled
`grafana_dashboard: "1"`. They are embedded as JSON rather than fetched by
`gnetId`, so provisioning needs no internet at pod runtime and the panels cannot
drift from what was tested.

---

## 12. Troubleshooting

**Dashboards empty right after install.** Wait 2–3 minutes. `make test` names the
exact link in the chain that is not delivering.

**`PrometheusTargetDown` fires for something in another namespace.** This cluster
has a pre-existing service — `calico-kube-controllers` on port `9094` in
`calico-system` — that advertises `prometheus.io/scrape: true` but does not serve
metrics there. That is true information about the cluster, not a chart bug, which
is why the rule is not silenced. `make test` reports such targets separately and
does not count them as failures. To stop it: fix the annotation on that service,
or narrow the `PrometheusTargetDown` expression in `values.yaml`.

**PVCs stuck Pending.** Check `local-path-provisioner` in `local-path-storage` is
Running. It has no control-plane toleration, so it needs a schedulable worker.

**Stateful pod Pending after a node reboot.** `local-path` volumes are
**node-local** — a pod with a bound PVC can only reschedule onto the node holding
its data. If that node is `NotReady`, the pod waits. Nothing in the chart can work
around this; bring the node back.

**A DaemonSet shows 1/2.** A toleration is missing. Both need
`tolerations: [{operator: Exists}]`.

**Logs missing for one node.** Check that node's Alloy pod and its active file
count (see trap 3). `make test` retries this for 120s because DaemonSet members do
not start shipping simultaneously.

**Alertmanager datasource health check fails with `plugin.unavailable`.** Expected.
Grafana's built-in alertmanager datasource has no backend component, so POSTing to
its `/health` endpoint always returns that even when it works fine in the UI.
`verify.sh` asserts existence only for this one datasource.

**Verification returns empty responses / contradictory results.** Do not query
services with `kubectl run --rm` per call — pod startup races the output capture
and roughly half the calls return an empty string, producing false failures.
`scripts/verify.sh` starts one long-lived helper pod and `kubectl exec`s into it.

---

## 13. Known limitations

- **PVC sizes are permanent.** `local-path` has `allowVolumeExpansion: false`, so
  10/10/5/2 GiB cannot be grown in place. Resizing means delete + recreate, losing
  that volume's data.
- **Scheduler, controller-manager and etcd are not scraped.** They bind metrics to
  `127.0.0.1` here. To enable: set `--bind-address=0.0.0.0` in
  `/etc/kubernetes/manifests/kube-{scheduler,controller-manager}.yaml` on
  `k8s-cp-0` and add the jobs to `prometheus.scrapeConfigs`. etcd additionally
  needs client certificates.
- **`kubectl top` still will not work.** That needs metrics-server, a separate
  component. The dashboards do not depend on it — they use cAdvisor and
  node-exporter directly.
- **No notification receivers.** Alerts are visible in Grafana but reach nothing
  external until `prometheus.alertmanager.config` is set.
- **Single replica of everything.** Right for a 2-node lab; not HA.
- **Grafana password is `admin`** by default.

---

## 14. Full command reference

```bash
cd /root/prom-grafana-loki-vectoria

# setup (once)
make deps                # add repos + vendor subcharts

# pre-flight
make lint                # helm lint (guard waived)
make template            # render manifests
make dryrun              # validate against live API + count CRDs

# deploy
make install             # install + wait
make upgrade             # apply values.yaml changes
make reinstall           # uninstall then install fresh

# inspect
make test                # 36 end-to-end assertions
make status              # pods + PVCs + DaemonSets
make pods                # watch pods
make url                 # Grafana URL + password
make password            # password only

# remove
make uninstall           # helm uninstall + delete ns + verify clean
make clean               # drop vendored .tgz and Chart.lock
```

Raw equivalents, no Makefile:

```bash
# install
helm install monitoring ./monitoring-stack \
  -n monitoring --create-namespace --wait --timeout 15m

# upgrade
helm upgrade monitoring ./monitoring-stack -n monitoring --wait --timeout 15m

# uninstall (both lines)
helm uninstall monitoring -n monitoring
kubectl delete ns monitoring

# verify — wait 2-3 min after install first (see note below)
./scripts/verify.sh monitoring monitoring
```

> **Do not run the verify straight after install.** Several dashboard queries use
> `rate(...[5m])`, which needs at least **two** scrapes in the window before it can
> return anything. Run too early and the series exist while every rate() query is
> legitimately empty — verified: `count(node_cpu_seconds_total{mode="idle"})`
> returned 16 series while the per-node CPU query returned `result: []`, then
> passed once a second scrape landed. `verify.sh` now retries these checks for up
> to 100s, so an early run self-corrects rather than reporting a false failure.

---

## Appendix — build history

| Step | Result |
|---|---|
| Chart scaffold + `helm dependency build` | 5 CRD-free subcharts vendored |
| `helm lint` / `template` / server-side dry run | passed, 0 CRDs rendered |
| First install | 10 pods Running, 4 PVCs Bound, both DaemonSets 2/2 |
| First `make test` | 12/32 — but 20 were false failures from a flaky `kubectl run --rm` helper |
| Fixed verify helper (one persistent pod) | 29/34 |
| Found + fixed 2 wrong service names | `-victoriametrics-server`, `-alertmanager` |
| Found + fixed Alloy `__path__` (trap 3) | 34 files tailed on cp-0, 25 on w-0 |
| Alertmanager datasource → existence-only check | expected `plugin.unavailable` |
| Log-node check → bounded retry | removed a startup-race false failure |
| Full `make test` | **36 passed, 0 failed** |
| Uninstall test | 0 release-owned cluster objects, 0 orphaned PVs, 0 CRDs |
| Fresh reinstall | 58 seconds, then 36/36 |
| Final teardown | namespace deleted, cluster clean |
