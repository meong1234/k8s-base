
.PHONY: help up down status

include scripts/*.mk

help: setup-help k8s-help images-help fluxcd-help artifacts-help env-help teams-help mesh-help edge-help identity-help access-help partner-help demos-help
	@echo "k8s-base — multi-team GitOps platform on k3d"
	@echo "=============================================="
	@echo ""
	@echo "High-Level Commands:"
	@echo "-------------------"
	@echo "  up               - Create cluster + registry, preload images, bootstrap Flux, onboard teams"
	@echo "  down             - Delete the k3d cluster (keeps the registry image cache and .keys/)"
	@echo "  status           - Show cluster, Flux and artifact status"
	@echo "  login-help       - The demo OIDC identities, their groups and their passwords"
	@echo "  access-list      - Show every AccessRequest and every live just-in-time binding"
	@echo ""

up: platform-ca authn-render dex-render dex-client-secret \
    cluster-create partner-sim-up dex-hosts-fix images-manage-all team-keys team-render-pubkeys \
    flux-operator-install platform-ca-inject flux-bootstrap partner-sim-inject dex-secrets \
    team-inject-age push-all
	@echo "==> Environment is now ready!"
	@echo "==> Inspect it with: make status"
	@echo "==> Walk the guarantees with: make demo-all"

down: partner-sim-down cluster-delete
	@echo "==> Environment has been destroyed"

status: cluster-status flux-status artifacts-list
