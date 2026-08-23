# monitoring-stack

A single Helm chart that gives the `k8s-ha` cluster metrics, logs, dashboards and
alerting. Deploy with one command, remove with two, and every dashboard is
populated the moment it comes up — nothing to import by hand.

```
make deps      # once: add helm repos, vendor the subcharts
make install   # deploy everything
make test      # prove data is actually flowing
```

Then open **http://192.168.56.134:30300** (or `.135`) and log in with
`admin` / `admin`.

---

## What you get

| Dashboard | Shows |
|---|---|
| **Cluster Health** | nodes ready, pods by phase, CPU/memory utilisation, requests vs allocatable, container restarts, firing alerts, deployment readiness |
| **Nodes** | per-node CPU (by mode), memory, disk fill, disk I/O, network, load average vs core count, uptime, node inventory |
| **Pods & Workloads** | per-pod CPU/memory/network, restart counts, top consumers, and a "why isn't this running" table of waiting/terminated reasons |
| **Logs** | live container logs from every node, filterable by namespace, pod and free text, plus log volume by level and noisiest pods |
| **Keycloak** | login rate split success vs failed, events by type/realm/error, top source IPs and targeted usernames, request latency, JVM and DB pool — only populated once Keycloak is deployed |

Alerting is included: 9 rules (node not ready, high CPU/memory, disk filling,
crashlooping, OOMKilled, target down, remote_write failing) visible under
**Alerting** in Grafana. No notification receivers are configured — nothing will
page you until you add one.

---

## Architecture

```
node-exporter (DaemonSet) ─┐
kube-state-metrics ────────┤
kubelet + cAdvisor ────────┼──> Prometheus ──remote_write──> VictoriaMetrics
kube-apiserver ────────────┤     (6h local, 5Gi)             (15d, 10Gi)
annotated pods ────────────┘          │                            │
                                 Alertmanager                      │
                                                                   │
pod logs ──> Alloy (DaemonSet) ──push──> Loki ─────────────────┐    │
                              (single binary, filesystem, 10Gi)│    │
                                                               v    v
                                                    Grafana (NodePort 30300)
                                            4 datasources, 4 dashboards, provisioned
```

**Why both Prometheus and VictoriaMetrics?** Prometheus does what it is best at —
service discovery and scraping, using its mature `kubernetes_sd` config — but
keeps only 6 hours locally. Everything is streamed to VictoriaMetrics, which is
the long-term store (15 days) and Grafana's **default** datasource. You get VM's
storage efficiency without hand-writing scrape discovery.

**Why kube-prometheus-stack?** The scraper is the Prometheus Operator, so scrape
targets are declared as ServiceMonitor objects rather than hand-written YAML.
This chart originally avoided it precisely because it installs CRDs and
`helm uninstall` never removes them — "easy to remove" was a requirement. That
requirement has not been dropped, it is met differently: `make uninstall`
deletes the 10 `monitoring.coreos.com` CRDs by name, and `make test` asserts
that exactly those 10 are present and nothing else has leaked.

**Annotation-based discovery still works.** ServiceMonitors cover everything
this chart owns, but a `kubernetes-pods` scrape job is kept alongside them so
any workload carrying plain `prometheus.io/scrape` annotations is still picked
up without writing a ServiceMonitor for it.

---

## Commands

| Command | What it does |
|---|---|
| `make deps` | Adds the three helm repos and runs `helm dependency build` |
| `make lint` | `helm lint` |
| `make template` | Render all manifests to stdout |
| `make dryrun` | Render **and** validate against the live API server; also counts CRDs (expects 10) |
| `make install` | Install and wait for readiness |
| `make upgrade` | Apply `values.yaml` changes to a running release |
| `make test` | 36 end-to-end assertions (see below) |
| `make status` | Pods, PVCs and DaemonSet coverage |
| `make url` / `make password` | Grafana URL / admin password |
| `make uninstall` | Remove the release **and** the namespace |
| `make reinstall` | Uninstall then install from scratch |

### `make test` is not a smoke test

It asserts that data is really flowing, because a stack where every pod is
`Running` and every dashboard is empty looks perfectly healthy to `kubectl`. It
checks, among other things:

- all 4 PVCs Bound, all containers ready
- **both DaemonSets at 2/2** — the proof that the tainted control-plane node is
  actually being monitored
- Prometheus has no down targets *of its own*
- VictoriaMetrics is receiving `remote_write` (row count is non-zero and rising)
- cAdvisor series carry a `node` label
- Loki returns real log lines, from **every** node
- all 4 datasources and all 4 dashboards are provisioned
- **each dashboard's key query replayed through Grafana's datasource proxy
  returns non-empty data** — this is the check that catches a green-but-empty stack
- Grafana answers on the NodePort from both node IPs
- the operator's 10 CRDs are present and no unmanaged CRD has leaked

---

## Removing it

```bash
helm uninstall monitoring -n monitoring
kubectl delete ns monitoring
```

`make uninstall` runs both and then verifies nothing was left behind.

**Both commands are needed.** Helm does not own the PVC that VictoriaMetrics'
StatefulSet creates through its `volumeClaimTemplate`, so `helm uninstall` alone
leaves a 10Gi volume behind; deleting the namespace reclaims it. (Loki's
StatefulSet sets `enableStatefulSetAutoDeletePVC`, so that one does clean itself
up — the namespace delete is the simple way to cover both cases without you
having to remember which is which.)

Verified clean: after uninstall there are **0** cluster-scoped objects owned by
the release, **0** orphaned PVs from the namespace, and **0** CRDs — the
operator's CRDs are deleted by name, since Helm will not do it.

**On a shared cluster, read that step first.** Deleting a CRD deletes every
object of that kind cluster-wide, so any ServiceMonitor or PrometheusRule
created outside this chart goes with it. The `uninstall` target in the Makefile
carries the same warning.

---

## Configuration

Everything lives in `monitoring-stack/values.yaml`, grouped per component and
commented. The knobs you are most likely to touch:

| Value | Default | Notes |
|---|---|---|
| `grafana.adminPassword` | `admin` | **Change this.** Lab default only |
| `grafana.service.nodePort` | `30300` | Grafana's port on both nodes |
| `victoriametrics.server.retentionPeriod` | `15d` | A bare number means **months** to VictoriaMetrics — keep the `d` |
| `victoriametrics.server.persistentVolume.size` | `10Gi` | Cannot be grown later, see below |
| `loki.loki.limits_config.retention_period` | `168h` | 7 days of logs |
| `prometheus.server.retention` | `6h` | Local only; VM holds the long history |
| `<component>.enabled` | `true` | Each of the 5 components can be switched off |

### The release must be named `monitoring`

Helm cannot template a values file, so the cross-component URLs (Prometheus'
`remote_write` target, the Grafana datasource URLs, Alloy's `loki.write`
endpoint) are written out literally as `monitoring-*` service names.

Installing under a different name would rename the Services but not those URLs.
Nothing would error — every pod would start and every dashboard would be silently
empty. Rather than leave that trap, the chart **refuses to render** under any
other release name and tells you which values to override if you really want a
different one.

---

## Troubleshooting

**Dashboards are empty right after install.** Give it 2–3 minutes. Prometheus has
to scrape, then `remote_write` into VictoriaMetrics. `make test` will tell you
exactly which link in the chain is not delivering.

**An alert fires about a target being down in another namespace.** This cluster
has a pre-existing service (`calico-kube-controllers` on port 9094) that
advertises `prometheus.io/scrape: true` but does not serve metrics there, so
`PrometheusTargetDown` will fire for it. That is real information, not a bug in
this chart, which is why the rule is not silenced. `make test` reports such
targets separately and does not count them as failures. To make it stop, either
fix the annotation on that service or narrow the `PrometheusTargetDown`
expression in `values.yaml`.

**A stateful pod is stuck Pending after a node reboot.** `local-path` volumes are
**node-local**, so a pod with a bound PVC can only ever be scheduled back onto
the node holding its data. If that node is `NotReady`, the pod waits. Nothing in
the chart can work around this; bring the node back.

**PVCs stuck Pending.** Check the `local-path-provisioner` pod in
`local-path-storage` is Running. It has no control-plane toleration, so it needs
at least one schedulable worker.

**Logs missing for one node.** Check that node's Alloy pod:
`kubectl logs -n monitoring -l app.kubernetes.io/name=alloy -c alloy`. Its active
file count should be non-zero:
`curl <alloyPodIP>:12345/metrics | grep loki_source_file_files_active_total`.

---

## Known limitations

- **PVC sizes are permanent.** The `local-path` StorageClass has
  `allowVolumeExpansion: false`, so 10Gi/10Gi/5Gi/2Gi cannot be grown in place.
  Changing a size means deleting and recreating that volume, losing its data.
- **Scheduler, controller-manager and etcd are not scraped.** They bind their
  metrics to `127.0.0.1` on this cluster, so they are unreachable from a pod. No
  scrape jobs are defined for them, which keeps the target list clean rather than
  permanently red. To enable them, set `--bind-address=0.0.0.0` in
  `/etc/kubernetes/manifests/kube-{scheduler,controller-manager}.yaml` on
  `k8s-cp-0` and add the jobs to `prometheus.scrapeConfigs`.
- **`kubectl top` still will not work.** That needs metrics-server, which is a
  separate component. The dashboards do not depend on it — they use cAdvisor and
  node-exporter directly.
- **No notification receivers.** Alerts are visible in Grafana but will not reach
  email/Slack/PagerDuty until you configure `prometheus.alertmanager.config`.
- **Single replica of everything.** Appropriate for a 2-node lab; not an HA
  configuration.

---

## Layout

```
Makefile                        deploy / verify / remove
scripts/verify.sh               the 36 end-to-end assertions
ADDING-A-DASHBOARD.md           how to add a dashboard of your own
monitoring-stack/
├── Chart.yaml                  umbrella + 5 pinned dependencies
├── values.yaml                 all configuration, per component
├── templates/
│   ├── _helpers.tpl            labels + the release-name guard
│   ├── grafana-dashboards.yaml one ConfigMap per dashboards/*.json
│   └── NOTES.txt               post-install access instructions
└── dashboards/                 5 hand-written dashboards (84 panels)
```

Dashboards are embedded as JSON rather than fetched by `gnetId`, so provisioning
needs no internet access at pod runtime and the panels cannot drift from what was
tested. They bind to datasources by fixed UID (`victoriametrics`, `prometheus`,
`loki`, `alertmanager`) — renaming a UID in `values.yaml` breaks every panel
using it.

To add one of your own, see **[ADDING-A-DASHBOARD.md](ADDING-A-DASHBOARD.md)** —
drop a `.json` into `dashboards/` and run `make upgrade`. Note that nothing in
the Helm pipeline validates dashboard JSON, so check it yourself before deploying.

### Pinned versions

| Chart | Version | App |
|---|---|---|
| kube-prometheus-stack | 88.5.3 | operator v0.93.1 / prom v3.14.0 |
| victoria-metrics-single | 0.44.0 | v1.149.0 |
| loki | 7.3.0 | 3.6.12 |
| alloy | 1.11.1 | v1.18.1 |
| grafana | 10.5.15 | 12.3.1 |
