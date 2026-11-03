
.PHONY: fluxcd-help flux-preflight flux-operator-install flux-bootstrap flux-instance-render flux-sync-render flux-status flux-reconcile-all

FLUX_OPERATOR_VERSION := v0.62.1
FLUX_VERSION          := 2.10.x

FLUX_OPERATOR_INSTALL_URL := https://github.com/controlplaneio-fluxcd/flux-operator/releases/download/$(FLUX_OPERATOR_VERSION)/install.yaml

# The two objects make applies by hand, kept out of the fleet artifact so that
# cluster-sync never manages its own spec.path. The root is per-environment
# because cluster-source is: see clusters/<env>/sources.yaml.
FLEET_BOOTSTRAP_DIR ?= $(FLEET_DIR)/bootstrap

FLUX_READY_TIMEOUT  := 10m
FLUX_SYNC_TIMEOUT   := 15m

# kubectl does not substitute, so anything applied before cluster-sync exists is
# rendered through make first and applied from a file, never through a pipe that
# would hide a failing renderer.
define apply_rendered
  set -e; \
  OUT=$$(mktemp); \
  $(MAKE) --no-print-directory $(1) > $$OUT; \
  kubectl apply -f $$OUT; \
  rm -f $$OUT
endef

fluxcd-help:
	@echo "FluxCD Commands:"
	@echo "---------------"
	@echo "  flux-operator-install - Install flux-operator $(FLUX_OPERATOR_VERSION)"
	@echo "  flux-bootstrap        - Install the operator, push platform artifacts, apply FluxInstance + cluster-vars + cluster sync"
	@echo "  flux-instance-render  - Print the FluxInstance for CLUSTER_ENV=$(CLUSTER_ENV)"
	@echo "  flux-sync-render      - Print cluster-source + cluster-sync for CLUSTER_ENV=$(CLUSTER_ENV), resolved from $(CLUSTER_VARS)"
	@echo "  flux-status           - flux get all -A plus FluxInstance / ResourceSet state"
	@echo "  flux-reconcile-all    - Force a reconcile of every source and Kustomization"
	@echo ""

flux-preflight:
	@command -v flux >/dev/null 2>&1 || { echo "Error: flux CLI not found - run 'make brew-setup-all'"; exit 1; }
	@kubectl cluster-info >/dev/null 2>&1 || { echo "Error: no reachable cluster - run 'make cluster-create' first"; exit 1; }
	@docker ps --format '{{.Names}}' | grep -qx '$(REG_NAME)' || { \
		echo "Error: registry '$(REG_NAME)' is not running - run 'make cluster-create' first"; exit 1; }

flux-operator-install: flux-preflight
	@echo "==> Installing flux-operator $(FLUX_OPERATOR_VERSION)"
	@kubectl apply --server-side -f $(FLUX_OPERATOR_INSTALL_URL)
	@kubectl -n flux-system rollout status deploy/flux-operator --timeout=3m
	@echo "==> flux-operator ready"

flux-instance-render:
	@test -d $(FLEET_DIR) || { echo "Error: $(FLEET_DIR) does not exist - CLUSTER_ENV=$(CLUSTER_ENV) has no clusters/<env> directory under repos/fleet"; exit 1; }
	@kustomize build $(FLEET_DIR) | yq 'select(.kind == "FluxInstance")'

flux-sync-render:
	@test -f $(CLUSTER_VARS) || { echo "Error: $(CLUSTER_VARS) is missing"; exit 1; }
	@set -e; \
	SUBST=$$(mktemp); OUT=$$(mktemp); \
	yq -r '.data | to_entries[] | ("s|$${" + .key + "}|" + .value + "|g", "s|$${" + .key + ":=[^}]*}|" + .value + "|g")' $(CLUSTER_VARS) > $$SUBST; \
	kustomize build $(FLEET_BOOTSTRAP_DIR) | sed -f $$SUBST > $$OUT; \
	if grep -q '$${' $$OUT; then \
		echo "Error: $(FLEET_BOOTSTRAP_DIR) references a variable $(CLUSTER_VARS) does not define:" >&2; \
		grep -n '$${' $$OUT >&2; \
		rm -f $$SUBST $$OUT; exit 1; \
	fi; \
	cat $$OUT; \
	rm -f $$SUBST $$OUT

flux-bootstrap: flux-operator-install artifacts-push-platform
	@echo "==> Applying FluxInstance (Flux $(FLUX_VERSION))"
	@$(call apply_rendered,flux-instance-render)
	@kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=$(FLUX_READY_TIMEOUT)
	@echo "==> Applying $(CLUSTER_VARS), which every Kustomization below substitutes from"
	@kubectl apply -f $(CLUSTER_VARS)
	@echo "==> Publishing the platform cosign public key as secret/cosign-pub-platform"
	@test -f $(COSIGN_KEYS_DIR)/platform/cosign.pub || { \
		echo "Error: $(COSIGN_KEYS_DIR)/platform/cosign.pub missing - run 'make team-keys' first"; exit 1; }
	@kubectl -n flux-system create secret generic cosign-pub-platform \
		--from-file=cosign.pub=$(COSIGN_KEYS_DIR)/platform/cosign.pub \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "==> Applying the bootstrap sync objects"
	@$(call apply_rendered,flux-sync-render)
	@echo "==> Waiting for Kustomization/cluster-sync to become Ready (this fans out to infra, operators and the teams ResourceSet)"
	@kubectl -n flux-system wait kustomization/cluster-sync --for=condition=Ready --timeout=$(FLUX_SYNC_TIMEOUT)
	@echo "==> Flux bootstrap complete - inspect it with: make flux-status"

flux-status:
	@echo "==> FluxInstance / ResourceSet"
	@kubectl get fluxinstance,resourceset -A || true
	@echo ""
	@echo "==> Flux objects"
	@flux get all -A || true

flux-reconcile-all:
	@echo "==> Reconciling every OCIRepository"
	@kubectl get ocirepositories.source.toolkit.fluxcd.io -A \
		-o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
		| while read -r ns name; do \
			[ -n "$$name" ] || continue; \
			echo "  - oci/$$ns/$$name"; \
			flux reconcile source oci "$$name" -n "$$ns" || true; \
		done
	@echo "==> Reconciling every Kustomization"
	@kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
		-o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
		| while read -r ns name; do \
			[ -n "$$name" ] || continue; \
			echo "  - ks/$$ns/$$name"; \
			flux reconcile kustomization "$$name" -n "$$ns" --with-source=false || true; \
		done
	@echo "==> Reconcile pass complete"
