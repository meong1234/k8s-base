
.PHONY: images-help images-pull-all images-push-all images-manage-all images-build-local images-list

REG_NAME ?= k3d-local-dev-registry
REG_HOST_PORT ?= 5050

FLUX_SOURCE_IMAGE       := ghcr.io/fluxcd/source-controller:v1.10.1
FLUX_KUSTOMIZE_IMAGE    := ghcr.io/fluxcd/kustomize-controller:v1.10.1
FLUX_HELM_IMAGE         := ghcr.io/fluxcd/helm-controller:v1.7.1
FLUX_NOTIFICATION_IMAGE := ghcr.io/fluxcd/notification-controller:v1.10.0
FLUX_OPERATOR_IMAGE     := ghcr.io/controlplaneio-fluxcd/flux-operator:v0.62.1

CILIUM_VERSION          := v1.20.4
HUBBLE_UI_VERSION       := v0.13.6
CILIUM_AGENT_IMAGE      := quay.io/cilium/cilium:$(CILIUM_VERSION)
CILIUM_OPERATOR_IMAGE   := quay.io/cilium/operator-generic:$(CILIUM_VERSION)
HUBBLE_RELAY_IMAGE      := quay.io/cilium/hubble-relay:$(CILIUM_VERSION)
HUBBLE_UI_IMAGE         := quay.io/cilium/hubble-ui:$(HUBBLE_UI_VERSION)
HUBBLE_UI_BACKEND_IMAGE := quay.io/cilium/hubble-ui-backend:$(HUBBLE_UI_VERSION)

# Istio 1.31 publishes images to Docker Hub only (gcr.io/istio-release and
# registry.istio.io are retired); the ambient profile sets global.variant to
# distroless, so the rendered tags carry the suffix.
ISTIO_VERSION           := 1.31.4
ISTIO_PILOT_IMAGE       := docker.io/istio/pilot:$(ISTIO_VERSION)-distroless
ISTIO_CNI_IMAGE         := docker.io/istio/install-cni:$(ISTIO_VERSION)-distroless
ISTIO_ZTUNNEL_IMAGE     := docker.io/istio/ztunnel:$(ISTIO_VERSION)-distroless
ISTIO_PROXY_IMAGE       := docker.io/istio/proxyv2:$(ISTIO_VERSION)-distroless

PODINFO_IMAGE           := ghcr.io/stefanprodan/podinfo:6.17.0
BUSYBOX_IMAGE           := docker.io/library/busybox:1.37
# 8.11.1 runs as uid 100; repos/team-b/apps/orders/base/caller.yaml pins runAsUser to match.
CURL_IMAGE              := docker.io/curlimages/curl:8.11.1

DEX_VERSION             := v2.46.1
DEX_IMAGE               := ghcr.io/dexidp/dex:$(DEX_VERSION)

# Hubble UI login on the internal Gateway: an ext_authz provider for Istio.
OAUTH2_PROXY_IMAGE      := quay.io/oauth2-proxy/oauth2-proxy:v7.15.6

CERT_MANAGER_VERSION          := v1.21.3
CERT_MANAGER_IMAGE            := quay.io/jetstack/cert-manager-controller:$(CERT_MANAGER_VERSION)
CERT_MANAGER_WEBHOOK_IMAGE    := quay.io/jetstack/cert-manager-webhook:$(CERT_MANAGER_VERSION)
CERT_MANAGER_CAINJECTOR_IMAGE := quay.io/jetstack/cert-manager-cainjector:$(CERT_MANAGER_VERSION)

PROJECT_IMAGES := $(FLUX_SOURCE_IMAGE) \
                  $(FLUX_KUSTOMIZE_IMAGE) \
                  $(FLUX_HELM_IMAGE) \
                  $(FLUX_NOTIFICATION_IMAGE) \
                  $(FLUX_OPERATOR_IMAGE) \
                  $(CILIUM_AGENT_IMAGE) \
                  $(CILIUM_OPERATOR_IMAGE) \
                  $(HUBBLE_RELAY_IMAGE) \
                  $(HUBBLE_UI_IMAGE) \
                  $(HUBBLE_UI_BACKEND_IMAGE) \
                  $(ISTIO_PILOT_IMAGE) \
                  $(ISTIO_CNI_IMAGE) \
                  $(ISTIO_ZTUNNEL_IMAGE) \
                  $(ISTIO_PROXY_IMAGE) \
                  $(PODINFO_IMAGE) \
                  $(BUSYBOX_IMAGE) \
                  $(CURL_IMAGE) \
                  $(OAUTH2_PROXY_IMAGE) \
                  $(CERT_MANAGER_IMAGE) \
                  $(CERT_MANAGER_WEBHOOK_IMAGE) \
                  $(CERT_MANAGER_CAINJECTOR_IMAGE) \
                  $(DEX_IMAGE)

images-help:
	@echo "Docker Image Management Commands:"
	@echo "--------------------------------"
	@echo "  images-pull-all     - Pull all required Docker images"
	@echo "  images-push-all     - Push all required images to the local registry"
	@echo "  images-manage-all   - Pull, push and build all required Docker images"
	@echo "  images-build-local  - Build the images this repo owns (access-warden, edge-authz)"
	@echo "  images-list         - List the registry catalog and each repo's tags"
	@echo ""

images-pull-all:
	@echo "==> Pulling project Docker images..."
	@for img in $(PROJECT_IMAGES); do \
		echo "  - Pulling $$img"; \
		for attempt in 1 2 3; do \
			docker pull $$img && break; \
			[ $$attempt = 3 ] && { echo "Error pulling $$img"; exit 1; }; \
			echo "    retrying ($$attempt)"; \
		done; \
	done
	@echo "==> All project images pulled successfully"

images-push-all:
	@echo "==> Pushing project images to local registry '$(REG_NAME)' (localhost:$(REG_HOST_PORT))..."
	@if ! docker ps --format '{{.Names}}' | grep -qx "$(REG_NAME)"; then \
		echo "Error: registry '$(REG_NAME)' is not running"; \
		echo "Please run 'make registry-create' (or 'make cluster-create') first"; \
		exit 1; \
	fi
	@for img in $(PROJECT_IMAGES); do \
		PATH_ONLY=$$(echo $$img | sed -E 's#^[^/]+\.[^/]+(:[0-9]+)?/##'); \
		LOCAL_REF="localhost:$(REG_HOST_PORT)/$$PATH_ONLY"; \
		echo "  - $$img -> $$LOCAL_REF"; \
		docker tag $$img $$LOCAL_REF; \
		docker push $$LOCAL_REF >/dev/null 2>&1 && continue; \
		echo "    docker push refused it; copying the manifest registry-to-registry"; \
		docker buildx imagetools create --tag $$LOCAL_REF $$img >/dev/null 2>&1 \
			|| { echo "Error pushing $$img"; exit 1; }; \
	done
	@echo "==> All project images pushed to the local registry"
	@echo "==> Nodes will pull them via the containerd mirrors (see k3d/cluster.yaml)"

images-build-local: warden-image edge-authz-image
	@echo "==> Locally built images are in the registry"

images-manage-all: images-pull-all images-push-all images-build-local
	@echo "==> Image management complete"

images-list:
	@echo "==> Registry catalog (http://localhost:$(REG_HOST_PORT)):"
	@curl -s http://localhost:$(REG_HOST_PORT)/v2/_catalog | jq -r '.repositories[]' | while read -r r; do \
		tags=$$(curl -s http://localhost:$(REG_HOST_PORT)/v2/$$r/tags/list | jq -rc '.tags'); \
		printf '  %-50s %s\n' "$$r" "$$tags"; \
	done
