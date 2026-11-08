.PHONY: edge-help edge-authz-build edge-authz-push edge-authz-image edge-authz-logs gateway-status

EDGE_AUTHZ_DIR         := tools/edge-authz
EDGE_AUTHZ_IMAGE       := docker.io/k8s-base/edge-authz:dev
EDGE_AUTHZ_LOCAL_IMAGE  = localhost:$(REG_HOST_PORT)/k8s-base/edge-authz:dev
EDGE_AUTHZ_NS          := platform-ingress

edge-help:
	@echo "Edge Commands:"
	@echo "--------------"
	@echo "  gateway-status   - The three ingress Gateways, their Services and addresses"
	@echo "  edge-authz-logs  - Tail the partner API-key authorizer log (one line per decision)"
	@echo "  edge-authz-build - Build $(EDGE_AUTHZ_IMAGE) from $(EDGE_AUTHZ_DIR)/"
	@echo "  edge-authz-push  - Push it to the local registry as $(EDGE_AUTHZ_LOCAL_IMAGE)"
	@echo "  edge-authz-image - edge-authz-build + edge-authz-push"
	@echo ""

gateway-status:
	@echo "==> Ingress Gateways (gatewayClassName istio, namespace $(EDGE_AUTHZ_NS))"
	@kubectl -n $(EDGE_AUTHZ_NS) get gateways.gateway.networking.k8s.io \
		-o custom-columns=NAME:.metadata.name,CLASS:.spec.gatewayClassName,ADDRESS:.status.addresses[0].value,PROGRAMMED:'.status.conditions[?(@.type=="Programmed")].status' 2>&1
	@echo
	@echo "==> Their Services (istiod names them <gateway>-istio; no 15021 by design)"
	@kubectl -n $(EDGE_AUTHZ_NS) get svc -l gateway.networking.k8s.io/gateway-name \
		-o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PORTS:.spec.ports[*].port 2>&1

edge-authz-logs:
	@kubectl -n $(EDGE_AUTHZ_NS) logs deploy/edge-authz --tail=100 -f

edge-authz-build:
	@echo "==> Building $(EDGE_AUTHZ_IMAGE) from $(EDGE_AUTHZ_DIR)/"
	@docker build -t $(EDGE_AUTHZ_IMAGE) $(EDGE_AUTHZ_DIR)

edge-authz-push:
	@if ! docker ps --format '{{.Names}}' | grep -qx "$(REG_NAME)"; then \
		echo "Error: registry '$(REG_NAME)' is not running"; \
		echo "Please run 'make registry-create' (or 'make cluster-create') first"; \
		exit 1; \
	fi
	@echo "==> $(EDGE_AUTHZ_IMAGE) -> $(EDGE_AUTHZ_LOCAL_IMAGE)"
	@docker tag $(EDGE_AUTHZ_IMAGE) $(EDGE_AUTHZ_LOCAL_IMAGE)
	@docker push $(EDGE_AUTHZ_LOCAL_IMAGE)
	@echo "==> Nodes resolve $(EDGE_AUTHZ_IMAGE) through the docker.io mirror (see k3d/cluster.yaml)"

edge-authz-image: edge-authz-build edge-authz-push
