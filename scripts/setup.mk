
.PHONY: setup-help brew-common brew-update-tools brew-setup-all tools-check

BREW_TOOLS := k3d kubectl kustomize helm cosign sops age cilium-cli hubble jq yq kubeconform
BREW_TAPS := fluxcd/tap/flux int128/kubelogin/kubelogin

REQUIRED_CLIS := k3d kubectl kustomize flux helm cosign sops age-keygen cilium hubble jq yq kubeconform \
                 kubectl-oidc_login htpasswd openssl

setup-help:
	@echo "Setup Commands:"
	@echo "--------------"
	@echo "  brew-common         - Install required development tools"
	@echo "  brew-update-tools   - Update all installed tools"
	@echo "  brew-setup-all      - Install and update all tools"
	@echo "  tools-check         - Print each required CLI and its version (or MISSING)"
	@echo ""

brew-common:
	@echo "==> Installing required tools..."
	@brew update
	@for tool in $(BREW_TOOLS); do \
		echo "  - Checking $$tool"; \
		brew list $$tool &>/dev/null || brew install $$tool; \
	done
	@for tap in $(BREW_TAPS); do \
		echo "  - Checking $$tap"; \
		brew list $$tap &>/dev/null || brew install $$tap; \
	done
	@echo "==> Installation complete"

brew-update-tools:
	@echo "==> Updating installed tools..."
	@brew update
	@for tool in $(BREW_TOOLS); do \
		if brew list $$tool &>/dev/null; then \
			echo "  - Upgrading $$tool"; \
			brew upgrade $$tool; \
		else \
			echo "  - $$tool not installed, skipping"; \
		fi \
	done
	@for tap in $(BREW_TAPS); do \
		if brew list $$tap &>/dev/null; then \
			echo "  - Upgrading $$tap"; \
			brew upgrade $$tap; \
		else \
			echo "  - $$tap not installed, skipping"; \
		fi \
	done
	@echo "==> Update complete"

brew-setup-all: brew-common brew-update-tools
	@echo "==> Environment setup complete"

tools-check:
	@echo "==> Required CLIs:"
	@missing=0; \
	for c in $(REQUIRED_CLIS); do \
		if command -v $$c >/dev/null 2>&1; then \
			v=""; \
			for spelling in "version --client" "--version" "-v" "version"; do \
				out=$$($$c $$spelling 2>&1 </dev/null | head -12); \
				v=$$(printf '%s\n' "$$out" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+[^ ,")]*' | head -1); \
				[ -n "$$v" ] && break; \
			done; \
			[ -n "$$v" ] || v="(installed, version unknown)"; \
			printf '  %-12s %s\n' "$$c" "$$v"; \
		else \
			printf '  %-12s %s\n' "$$c" "MISSING"; \
			missing=1; \
		fi; \
	done; \
	if [ $$missing -eq 1 ]; then \
		echo "==> Some tools are missing. Run: make brew-setup-all"; \
	else \
		echo "==> Toolchain complete"; \
	fi
