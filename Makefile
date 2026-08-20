# monitoring-stack — deploy / verify / remove
#
# Everything here is a thin wrapper around helm and kubectl; nothing is hidden.
# Run `make` on its own to see what is available.

SHELL       := /bin/bash
CHART       := monitoring-stack
RELEASE     := monitoring
NAMESPACE   := monitoring
NODE_IP     := 192.168.56.134
GRAFANA_PORT := 30300

.DEFAULT_GOAL := help
.PHONY: help deps lint template dryrun install upgrade test status pods url password uninstall clean reinstall

help:
	@echo ""
	@echo "  monitoring-stack — Prometheus + VictoriaMetrics + Loki + Grafana"
	@echo ""
	@echo "  Setup"
	@echo "    make deps         add helm repos and vendor the subcharts"
	@echo ""
	@echo "  Check before deploying"
	@echo "    make lint         helm lint"
	@echo "    make template     render all manifests to stdout"
	@echo "    make dryrun       render AND validate against the live cluster API"
	@echo ""
	@echo "  Deploy"
	@echo "    make install      install the stack (waits for readiness)"
	@echo "    make upgrade      apply values.yaml changes to a running release"
	@echo "    make reinstall    uninstall, then install again from scratch"
	@echo ""
	@echo "  Inspect"
	@echo "    make test         end-to-end verification (metrics AND logs really flowing)"
	@echo "    make status       helm status + pods + pvcs + daemonsets"
	@echo "    make pods         watch pods come up"
	@echo "    make url          print the Grafana URL"
	@echo "    make password     print the Grafana admin password"
	@echo ""
	@echo "  Remove"
	@echo "    make uninstall    remove the release AND the namespace (reclaims PVCs)"
	@echo ""

deps:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add vm https://victoriametrics.github.io/helm-charts
	helm repo update prometheus-community grafana vm
	cd $(CHART) && helm dependency build

# helm lint hardcodes the release name to "test-release" and offers no way to
# change it, so the chart's release-name guard has to be waived here.
lint:
	helm lint $(CHART) --set skipReleaseNameCheck=true

template:
	helm template $(RELEASE) ./$(CHART) --namespace $(NAMESPACE)

# Validates against the real API server, so it catches schema problems that
# `helm template` alone cannot. The namespace has to exist for server-side
# validation to resolve namespaced objects, so we ensure it first.
dryrun:
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	helm template $(RELEASE) ./$(CHART) --namespace $(NAMESPACE) \
	  | kubectl apply --dry-run=server -n $(NAMESPACE) -f - >/dev/null && \
	  echo "server-side dry run OK"
	@echo -n "CRDs this chart would create (must be 0): "
	@helm template $(RELEASE) ./$(CHART) --namespace $(NAMESPACE) \
	  | grep -c "^kind: CustomResourceDefinition" || true

install:
	helm install $(RELEASE) ./$(CHART) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --wait --timeout 15m
	@$(MAKE) --no-print-directory url

upgrade:
	helm upgrade $(RELEASE) ./$(CHART) \
	  --namespace $(NAMESPACE) \
	  --wait --timeout 15m

test:
	@./scripts/verify.sh $(RELEASE) $(NAMESPACE)

status:
	@helm status $(RELEASE) -n $(NAMESPACE) 2>/dev/null | head -5 || echo "release not installed"
	@echo ""
	@kubectl get pods -n $(NAMESPACE) -o wide 2>/dev/null || true
	@echo ""
	@kubectl get pvc -n $(NAMESPACE) 2>/dev/null || true
	@echo ""
	@echo "DaemonSets should be 2/2 — that proves the tainted control-plane node is covered:"
	@kubectl get ds -n $(NAMESPACE) 2>/dev/null || true

pods:
	kubectl get pods -n $(NAMESPACE) -w

url:
	@echo ""
	@echo "  Grafana:  http://$(NODE_IP):$(GRAFANA_PORT)"
	@echo "  user:     admin"
	@echo -n "  password: "
	@kubectl get secret -n $(NAMESPACE) $(RELEASE)-grafana \
	  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "(release not installed)"
	@echo ""
	@echo ""

password:
	@kubectl get secret -n $(NAMESPACE) $(RELEASE)-grafana \
	  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Both steps are needed. `helm uninstall` leaves the PVC that VictoriaMetrics'
# StatefulSet created behind (Helm does not own volumeClaimTemplate PVCs), so
# deleting the namespace is what actually reclaims the disk.
uninstall:
	-helm uninstall $(RELEASE) -n $(NAMESPACE)
	-kubectl delete ns $(NAMESPACE) --wait=true
	@echo ""
	@echo "removed. verifying nothing was left behind:"
	@# Matched by ownership label, NOT by name. Kubernetes ships built-in
	@# "system:monitoring" RBAC defaults, so a name-substring check would always
	@# report false leftovers.
	@echo -n "  cluster-scoped objects owned by this release: "
	@kubectl get clusterrole,clusterrolebinding \
	  -l app.kubernetes.io/instance=$(RELEASE) -o name 2>/dev/null | wc -l
	@# Only PVs whose claim pointed at our namespace; other namespaces' PVs are
	@# none of our business.
	@echo -n "  orphaned PVs from our namespace:              "
	@kubectl get pv -o json 2>/dev/null | python3 -c "import json,sys; \
	  print(sum(1 for p in json.load(sys.stdin)['items'] \
	  if (p['spec'].get('claimRef') or {}).get('namespace')=='$(NAMESPACE)'))"
	@echo -n "  CRDs added by this chart:                     "
	@kubectl get crd -o name 2>/dev/null | grep -cE "monitoring\.grafana\.com|victoriametrics" || true
	@echo ""
	@echo "  all three should be 0."

reinstall: uninstall install

clean:
	rm -rf $(CHART)/charts/*.tgz $(CHART)/Chart.lock
