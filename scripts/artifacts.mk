
.PHONY: artifacts-help push push-guard push-all artifacts-push-platform artifacts-verify artifacts-list promote artifacts-promotions

TAG ?= $(CLUSTER_ENV)

PROMOTE_TAGS := local dev uat prod

PUSH_NUDGE_TIMEOUT ?= 30s

SIGN_AS ?=

# M3: TAG follows CLUSTER_ENV, which otherwise puts an uncommitted working tree
# one keystroke from :prod. The parse-time half catches make -n as well.
PUSH_GUARD_MSG = CLUSTER_ENV=$(CLUSTER_ENV): push writes the working tree to :$(TAG); content reaches a non-local tag only through 'make promote REPO=<repo> FROM=local TO=$(CLUSTER_ENV)'

ifneq ($(filter push push-all artifacts-push-platform,$(MAKECMDGOALS)),)
ifneq ($(filter-out local,$(CLUSTER_ENV)),)
$(error $(PUSH_GUARD_MSG))
endif
endif

key_for = $(if $(SIGN_AS),$(SIGN_AS),$(if $(filter $(1),$(PLATFORM_REPOS)),platform,$(1)))

ns_for = $(if $(filter $(1),$(PLATFORM_REPOS)),flux-system,$(1))

source_for = $(if $(filter $(1),fleet),cluster-source,$(1)-source)

# cosign 3 defaults to the new sigstore bundle format, which Flux 2.10 verifies
# only against an OIDC identity and not a static `.pub` key, and it refuses
# --new-bundle-format=false unless --use-signing-config=false opts out of the
# TUF-resolved signing config. --tlog-upload=false keeps a laptop signing into a
# private HTTP registry away from the public Rekor.
COSIGN_EXTRA_FLAGS ?= --new-bundle-format=false --use-signing-config=false --tlog-upload=false

COSIGN_HTTP_FLAGS := --allow-http-registry --allow-insecure-registry

artifacts-help:
	@echo "OCI Artifact Commands:"
	@echo "---------------------"
	@echo "  push REPO=<name>        - Push + sign one repo as oci://$(OCI_LOCAL_URL)/<name>:$(TAG) (SIGN=0 to skip signing)"
	@echo "  push REPO=<n> SIGN_AS=<o> - Sign with another owner's key: the OCIRepository must refuse it"
	@echo "  push-all                - Push + sign every repo ($(REPOS))"
	@echo "  artifacts-push-platform - Push + sign the platform repos only ($(PLATFORM_REPOS))"
	@echo "  artifacts-verify        - cosign verify every pushed artifact"
	@echo "  artifacts-list          - List the tags present in the local registry"
	@echo "  promote REPO= FROM= TO= - Re-tag one artifact from FROM to TO, digest and signature unchanged"
	@echo "  artifacts-promotions    - Print, per repo, which digest and revision each environment tag resolves to"
	@echo ""

push-guard:
	@test "$(CLUSTER_ENV)" = local || { echo "Error: $(PUSH_GUARD_MSG)"; exit 1; }

push: push-guard $(if $(ENV_CHECK_SKIP),,env-check)
	@test -n "$(REPO)" || { echo "Error: REPO=<name> required (one of: $(REPOS))"; exit 1; }
	@test -d repos/$(REPO) || { echo "Error: repos/$(REPO) does not exist"; exit 1; }
	@command -v flux >/dev/null 2>&1 || { echo "Error: flux CLI not found - run 'make brew-setup-all'"; exit 1; }
	@docker ps --format '{{.Names}}' | grep -qx '$(REG_NAME)' || { \
		echo "Error: registry '$(REG_NAME)' is not running - run 'make cluster-create' first"; exit 1; }
	@if [ "$(SIGN)" != "0" ]; then \
		command -v cosign >/dev/null 2>&1 || { echo "Error: cosign not found - run 'make brew-setup-all'"; exit 1; }; \
		test -f $(COSIGN_KEYS_DIR)/$(call key_for,$(REPO))/cosign.key || { \
			echo "Error: signing key $(COSIGN_KEYS_DIR)/$(call key_for,$(REPO))/cosign.key is missing - run 'make team-keys'"; \
			exit 1; }; \
	fi
	@echo "==> Pushing repos/$(REPO) -> oci://$(OCI_LOCAL_URL)/$(REPO):$(TAG)"
	@set -e; \
	REV=$$(find repos/$(REPO) -type f -not -name '.DS_Store' -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-12); \
	echo "  - revision: $(TAG)@sha1:$$REV"; \
	OUT=$$(mktemp); \
	flux push artifact oci://$(OCI_LOCAL_URL)/$(REPO):$(TAG) \
		--path=repos/$(REPO) \
		--source="local://repos/$(REPO)" \
		--revision="$(TAG)@sha1:$$REV" \
		--output=json > $$OUT; \
	DIGEST=$$(jq -r .digest $$OUT); \
	rm -f $$OUT; \
	echo "  - digest: $$DIGEST"; \
	if [ "$(SIGN)" != "0" ]; then \
		echo "  - signing with $(COSIGN_KEYS_DIR)/$(call key_for,$(REPO))/cosign.key"; \
		COSIGN_PASSWORD= cosign sign --yes \
			--key=$(COSIGN_KEYS_DIR)/$(call key_for,$(REPO))/cosign.key \
			$(COSIGN_HTTP_FLAGS) $(COSIGN_EXTRA_FLAGS) \
			$(OCI_LOCAL_URL)/$(REPO)@$$DIGEST; \
	else \
		echo "  - SIGN=0: skipping signature (the OCIRepository will refuse this artifact)"; \
	fi
	@echo "  - nudging source oci/$(call source_for,$(REPO)) in $(call ns_for,$(REPO))"
	@flux reconcile source oci $(call source_for,$(REPO)) -n $(call ns_for,$(REPO)) \
		--timeout=$(PUSH_NUDGE_TIMEOUT) 2>/dev/null || \
		echo "    (not reconciled - the source object may not exist yet, or the artifact was refused)"
	@echo "==> repos/$(REPO) pushed"

push-all: push-guard env-check
	@for r in $(REPOS); do $(MAKE) --no-print-directory push REPO=$$r ENV_CHECK_SKIP=1 || exit 1; done
	@echo "==> All repos pushed: $(REPOS)"

artifacts-push-platform: push-guard env-check
	@for r in $(PLATFORM_REPOS); do $(MAKE) --no-print-directory push REPO=$$r ENV_CHECK_SKIP=1 || exit 1; done
	@echo "==> Platform repos pushed: $(PLATFORM_REPOS)"

# Only :local is on every repo. Sweeping all eight at a promoted tag would read
# seven absent tags as seven bad signatures, so an absent tag is reported as
# absent and skipped - unless REPO= named it, where absence is the answer.
artifacts-verify:
	@command -v cosign >/dev/null 2>&1 || { echo "Error: cosign not found - run 'make brew-setup-all'"; exit 1; }
	@FAILED=""; ABSENT=""; \
	for r in $(if $(REPO),$(REPO),$(REPOS)); do \
		OWNER=$$r; \
		for p in $(PLATFORM_REPOS); do [ "$$p" = "$$r" ] && OWNER=platform; done; \
		KEY=$(COSIGN_KEYS_DIR)/$$OWNER/cosign.pub; \
		if [ ! -f $$KEY ]; then \
			echo "  ?? $$r: public key $$KEY missing - run 'make team-keys'"; FAILED="$$FAILED $$r"; continue; \
		fi; \
		if [ -z "$$($(call digest_of,$$r,$(TAG)))" ]; then \
			echo "  -- $$r:$(TAG) is not in the registry"; \
			if [ -n "$(REPO)" ]; then FAILED="$$FAILED $$r"; else ABSENT="$$ABSENT $$r"; fi; \
			continue; \
		fi; \
		if COSIGN_PASSWORD= cosign verify --key=$$KEY $(COSIGN_HTTP_FLAGS) \
			--insecure-ignore-tlog=true $(OCI_LOCAL_URL)/$$r:$(TAG) >/dev/null 2>&1; then \
			echo "  ok $$r:$(TAG) signed by $$KEY"; \
		else \
			echo "  !! $$r:$(TAG) signature verification FAILED against $$KEY"; FAILED="$$FAILED $$r"; \
		fi; \
	done; \
	test -z "$$FAILED" || { echo "==> Verification failed for:$$FAILED"; exit 1; }; \
	if [ -n "$$ABSENT" ]; then echo "==> Every :$(TAG) artifact present verified; not tagged:$$ABSENT"; \
	else echo "==> All artifacts verified"; fi

artifacts-list:
	@echo "==> Catalog of $(OCI_LOCAL_URL)"
	@curl -s http://$(OCI_LOCAL_URL)/v2/_catalog | jq -r '.repositories[]?' 2>/dev/null \
		|| echo "  (registry not reachable on $(OCI_LOCAL_URL))"
	@echo "==> Tags per repo (TAG=$(TAG))"
	@for r in $(REPOS); do \
		TAGS=$$(curl -s http://$(OCI_LOCAL_URL)/v2/$$r/tags/list | jq -rc '.tags // []' 2>/dev/null); \
		printf '  %-12s %s\n' "$$r" "$${TAGS:-[]}"; \
	done

# flux pull artifact has no JSON output in 2.10.0 (-o is the extraction path),
# so a tag resolves to a digest the way demo_sign_as already does it: through
# the registry's own Docker-Content-Digest header.
digest_of = curl -s -o /dev/null -D - -H 'Accept: application/vnd.oci.image.manifest.v1+json' http://$(OCI_LOCAL_URL)/v2/$(1)/manifests/$(2) | awk 'tolower($$1) == "docker-content-digest:" { print $$2 }' | tr -d '\r'

promote:
	@test -n "$(REPO)" || { echo "Error: REPO=<name> required (one of: $(REPOS))"; exit 1; }
	@test -n "$(FROM)" || { echo "Error: FROM=<tag> required (one of: $(PROMOTE_TAGS))"; exit 1; }
	@test -n "$(TO)"   || { echo "Error: TO=<tag> required (one of: $(PROMOTE_TAGS))"; exit 1; }
	@test "$(FROM)" != "$(TO)" || { \
		echo "Error: FROM and TO are both '$(TO)' - a promotion moves content between environments"; exit 1; }
	@command -v flux >/dev/null 2>&1 || { echo "Error: flux CLI not found - run 'make brew-setup-all'"; exit 1; }
	@command -v cosign >/dev/null 2>&1 || { echo "Error: cosign not found - run 'make brew-setup-all'"; exit 1; }
	@set -e; \
	SRC=$$($(call digest_of,$(REPO),$(FROM))); \
	test -n "$$SRC" || { \
		echo "Error: oci://$(OCI_LOCAL_URL)/$(REPO):$(FROM) does not exist in the registry"; exit 1; }; \
	echo "==> Promoting $(REPO) $(FROM) -> $(TO)"; \
	echo "  - source digest: $$SRC"; \
	KEY=$(COSIGN_KEYS_DIR)/$(call key_for,$(REPO))/cosign.pub; \
	test -f $$KEY || { echo "Error: public key $$KEY is missing - run 'make team-keys'"; exit 1; }; \
	echo "  - verifying the source against $$KEY"; \
	COSIGN_PASSWORD= cosign verify --key=$$KEY $(COSIGN_HTTP_FLAGS) \
		--insecure-ignore-tlog=true $(OCI_LOCAL_URL)/$(REPO)@$$SRC >/dev/null; \
	DST=$$($(call digest_of,$(REPO),$(TO))); \
	if [ -z "$$DST" ]; then \
		echo "  - :$(TO) does not exist yet, so there is nothing to park"; \
	elif [ "$$DST" = "$$SRC" ]; then \
		echo "  - :$(TO) already resolves to $$SRC, so there is nothing to park"; \
	elif [ "$(FROM)" = "$(TO)-prev" ]; then \
		echo "  - rolling back from :$(TO)-prev, which parking the current :$(TO) would overwrite"; \
	else \
		echo "  - parking the current :$(TO) ($$DST) as :$(TO)-prev"; \
		flux tag artifact oci://$(OCI_LOCAL_URL)/$(REPO)@$$DST --tag $(TO)-prev | sed 's/^/    /'; \
	fi; \
	flux tag artifact oci://$(OCI_LOCAL_URL)/$(REPO):$(FROM) --tag $(TO) | sed 's/^/    /'; \
	NEW=$$($(call digest_of,$(REPO),$(TO))); \
	test "$$NEW" = "$$SRC" || { \
		echo "Error: $(REPO):$(TO) resolves to $$NEW, not $$SRC"; exit 1; }; \
	echo "==> $(REPO):$(TO) resolves to $$SRC, the digest its signature is bound to"; \
	echo "    verify it with : make artifacts-verify TAG=$(TO)"; \
	echo "    roll it back with: make promote REPO=$(REPO) FROM=$(TO)-prev TO=$(TO)"

artifacts-promotions:
	@echo "==> Promotions in $(OCI_LOCAL_URL) ($(PROMOTE_TAGS), with any parked <tag>-prev)"
	@for r in $(REPOS); do \
		echo "  $$r"; \
		for t in $(foreach e,$(PROMOTE_TAGS),$(e) $(e)-prev); do \
			D=$$($(call digest_of,$$r,$$t)); \
			[ -n "$$D" ] || continue; \
			REV=$$(curl -s -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
				http://$(OCI_LOCAL_URL)/v2/$$r/manifests/$$t \
				| jq -r '.annotations["org.opencontainers.image.revision"] // "-"'); \
			printf '    %-10s -> %s -> %s\n' "$$t" "$$D" "$$REV"; \
		done; \
	done
