
.PHONY: mesh-help istio-status ztunnel-logs ztunnel-workloads waypoint-status

ISTIO_NAMESPACE := istio-system
ZTUNNEL_LOG_LINES ?= 50

mesh-help:
	@echo "Service Mesh (Istio ambient) Commands:"
	@echo "-------------------------------------"
	@echo "  istio-status       - istiod, istio-cni and ztunnel rollout state plus istioctl version"
	@echo "  ztunnel-workloads  - istioctl ztunnel-config workloads (protocol HBONE means enrolled)"
	@echo "  ztunnel-logs       - Last $(ZTUNNEL_LOG_LINES) lines from every ztunnel pod"
	@echo "  waypoint-status    - Waypoint Gateways and their programmed state"
	@echo ""

istio-status:
	@echo "==> istioctl"
	@istioctl version --remote=true 2>&1 || true
	@echo "==> Workloads in $(ISTIO_NAMESPACE)"
	@kubectl -n $(ISTIO_NAMESPACE) get deploy,ds,pods -o wide 2>&1 || true
	@echo "==> Ambient enrollment"
	@kubectl get ns -L istio.io/dataplane-mode 2>&1 || true
	@echo "==> Mesh-wide mTLS"
	@kubectl -n $(ISTIO_NAMESPACE) get peerauthentication 2>&1 || true
	@echo "==> Mesh authorization"
	@kubectl get authorizationpolicy -A 2>&1 || true

ztunnel-workloads:
	@istioctl ztunnel-config workloads

ztunnel-logs:
	@for p in $$(kubectl -n $(ISTIO_NAMESPACE) get pods -l app=ztunnel -o name); do \
		echo "==> $$p"; \
		kubectl -n $(ISTIO_NAMESPACE) logs $$p --tail=$(ZTUNNEL_LOG_LINES) 2>&1 | sed 's/^/    /'; \
	done

waypoint-status:
	@echo "==> Waypoint Gateways (gatewayClassName istio-waypoint)"
	@kubectl get gateways.gateway.networking.k8s.io -A \
		-o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.gatewayClassName,PROGRAMMED:'.status.conditions[?(@.type=="Programmed")].status' \
		2>&1 | grep -E 'NAMESPACE|istio-waypoint' || echo "  (no waypoints — H2 deploys the first one)"
	@echo "==> Namespaces pointing at a waypoint"
	@kubectl get ns -L istio.io/use-waypoint 2>&1 || true
