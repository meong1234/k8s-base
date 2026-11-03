
.PHONY: teams-help team-keys keys-migrate team-render-pubkeys team-inject-age \
        team-sops-encrypt team-sops-decrypt team-status team-kubeconfig

KEYS_ROOT := .keys

# The environments a rendered .sops.yaml can know about are the ones the fleet
# declares; local and dev may share one recipient, so they share the catch-all
# rule and every other environment is named by a rule of its own.
SOPS_ENVS           = $(sort $(notdir $(patsubst %/.,%,$(wildcard repos/fleet/clusters/*/.))))
SOPS_SHARED_ENVS   := local dev
SOPS_OWN_RULE_ENVS  = $(filter-out $(SOPS_SHARED_ENVS),$(SOPS_ENVS))
SOPS_CATCHALL_ENVS  = $(filter $(SOPS_SHARED_ENVS),$(SOPS_ENVS))

KEYS_MIGRATE_ENV   ?= local
KEYS_MIGRATE_OWNERS = platform $(TEAMS) users partner-api partner-bank
KEYS_COSIGN_OWNERS  = platform $(TEAMS)
# The first team namespace now waits behind platform-config-ks, so the chain
# is infra-ks -> four Istio Helm releases -> PeerAuthentication -> ResourceSet.
TEAM_NS_TIMEOUT ?= 600

teams-help:
	@echo "Team Commands:"
	@echo "---------------"
	@echo "  team-keys               - Generate age pairs under $(KEYS_DIR)/ and cosign pairs under $(COSIGN_KEYS_DIR)/ (idempotent)"
	@echo "  keys-migrate            - One-shot: move a flat .keys/<owner> layout into .keys/$(KEYS_MIGRATE_ENV)/ and $(COSIGN_KEYS_DIR)/"
	@echo "  team-render-pubkeys     - Write repos/<team>/.sops.yaml: one creation rule per environment, catch-all last"
	@echo "  team-inject-age         - Create Secrets sops-age + cosign-pub in each team home namespace"
	@echo "  team-sops-encrypt TEAM= FILE=  - sops --encrypt --in-place with that team's age key"
	@echo "  team-sops-decrypt TEAM= FILE=  - Decrypt to stdout for inspection (never written back)"
	@echo "  team-status TEAM=<t>  - Show one team's Flux objects, workloads and effective RBAC"
	@echo "  team-kubeconfig TEAM= - Write $(KEYS_DIR)/<t>/kubeconfig using that team's flux SA token"
	@echo ""

team-keys:
	@echo "==> Generating age key pairs in $(KEYS_DIR)/ and cosign key pairs in $(COSIGN_KEYS_DIR)/"
	@for t in platform $(TEAMS); do \
	  mkdir -p $(KEYS_DIR)/$$t $(COSIGN_KEYS_DIR)/$$t; \
	  if [ -f $(COSIGN_KEYS_DIR)/$$t/cosign.key ]; then \
	    echo "    $$t cosign  : exists"; \
	  else \
	    echo "    $$t cosign  : generating"; \
	    ( cd $(COSIGN_KEYS_DIR)/$$t && COSIGN_PASSWORD= cosign generate-key-pair >/dev/null ); \
	  fi; \
	  if [ -f $(KEYS_DIR)/$$t/age.agekey ]; then \
	    echo "    $$t age     : exists"; \
	  else \
	    echo "    $$t age     : generating"; \
	    age-keygen -o $(KEYS_DIR)/$$t/age.agekey 2>/dev/null; \
	  fi; \
	  grep 'public key' $(KEYS_DIR)/$$t/age.agekey | cut -d: -f2 | tr -d ' ' > $(KEYS_DIR)/$$t/age.pub; \
	done
	@chmod -R go-rwx $(KEYS_DIR) $(COSIGN_KEYS_DIR)

# A regenerated key invalidates every signature already in the registry and
# every Secret already encrypted, so nothing here ever overwrites: a name that
# exists on both sides is reported and the run fails with both files intact.
keys-migrate:
	@test -d $(KEYS_ROOT) || { echo "==> $(KEYS_ROOT)/ does not exist - nothing to migrate"; exit 0; }
	@echo "==> Migrating $(KEYS_ROOT)/<owner> into $(KEYS_ROOT)/$(KEYS_MIGRATE_ENV)/<owner> and $(COSIGN_KEYS_DIR)/<owner>"
	@set -e; \
	MOVED=0; CONFLICT=""; \
	for o in $(KEYS_MIGRATE_OWNERS); do \
	  src=$(KEYS_ROOT)/$$o; \
	  [ -d $$src ] || continue; \
	  case " $(KEYS_COSIGN_OWNERS) " in *" $$o "*) \
	    for b in cosign.key cosign.pub; do \
	      [ -f $$src/$$b ] || continue; \
	      dst=$(COSIGN_KEYS_DIR)/$$o/$$b; \
	      if [ -e $$dst ]; then CONFLICT="$$CONFLICT $$dst"; continue; fi; \
	      mkdir -p $(COSIGN_KEYS_DIR)/$$o; mv $$src/$$b $$dst; \
	      MOVED=$$((MOVED+1)); echo "    $$src/$$b -> $$dst"; \
	    done;; \
	  esac; \
	  for rel in $$(cd $$src && find . -type f | sed 's|^\./||'); do \
	    case "$$rel" in cosign.key|cosign.pub) continue;; esac; \
	    dst=$(KEYS_ROOT)/$(KEYS_MIGRATE_ENV)/$$o/$$rel; \
	    if [ -e $$dst ]; then CONFLICT="$$CONFLICT $$dst"; continue; fi; \
	    mkdir -p $$(dirname $$dst); mv $$src/$$rel $$dst; \
	    MOVED=$$((MOVED+1)); echo "    $$src/$$rel -> $$dst"; \
	  done; \
	  find $$src -type d -empty -delete 2>/dev/null || true; \
	done; \
	if [ -n "$$CONFLICT" ]; then \
	  echo "  !! refusing to overwrite an existing key:"; \
	  for c in $$CONFLICT; do echo "       $$c"; done; \
	  echo "     nothing was overwritten - move or delete those, then re-run"; \
	  exit 1; \
	fi; \
	if [ $$MOVED -eq 0 ]; then \
	  echo "    nothing to move - the layout is already per environment"; \
	else \
	  echo "    $$MOVED file(s) moved"; \
	fi
	@chmod -R go-rwx $(KEYS_ROOT)

# sops honours the first matching rule, so the environments that keep a key of
# their own come first and the shared catch-all stays last. A root-level
# *.enc.yaml then encrypts to the shared recipients, which is the correct
# failure on an environment that does not share them.
team-render-pubkeys:
	@echo "==> Writing repos/<team>/.sops.yaml from $(KEYS_ROOT)/<env>/<team>/age.pub"
	@test -n "$(strip $(SOPS_ENVS))" || { \
	  echo "    no environment directory found under repos/fleet/clusters/"; exit 1; }
	@for t in $(TEAMS); do \
	  mkdir -p repos/$$t; \
	  out=repos/$$t/.sops.yaml; \
	  echo "creation_rules:" > $$out; \
	  for e in $(SOPS_OWN_RULE_ENVS); do \
	    pub=$(KEYS_ROOT)/$$e/$$t/age.pub; \
	    [ -f $$pub ] || continue; \
	    { \
	      echo "  - path_regex: envs/$$e/.*\\.enc\\.yaml\$$"; \
	      echo "    encrypted_regex: ^(data|stringData)\$$"; \
	      echo "    age: $$(cat $$pub)"; \
	    } >> $$out; \
	    echo "    $$t: envs/$$e/ -> $$(cat $$pub)"; \
	  done; \
	  shared=""; \
	  for e in $(SOPS_CATCHALL_ENVS); do \
	    pub=$(KEYS_ROOT)/$$e/$$t/age.pub; \
	    [ -f $$pub ] || continue; \
	    shared="$${shared:+$$shared,}$$(cat $$pub)"; \
	  done; \
	  test -n "$$shared" || { \
	    echo "    $$t: no age.pub under $(KEYS_ROOT)/{$(SOPS_CATCHALL_ENVS)}/$$t - run make team-keys"; \
	    exit 1; }; \
	  { \
	    echo "  - path_regex: .*\\.enc\\.yaml\$$"; \
	    echo "    encrypted_regex: ^(data|stringData)\$$"; \
	    echo "    age: $$shared"; \
	  } >> $$out; \
	  echo "    $$t: $$out -> $$shared"; \
	done


team-inject-age:
	@echo "==> Injecting sops-age + cosign-pub into team home namespaces"
	@for t in $(TEAMS); do \
	  echo "    $$t: waiting for namespace (timeout $(TEAM_NS_TIMEOUT)s)"; \
	  i=0; \
	  until kubectl get namespace $$t >/dev/null 2>&1; do \
	    i=$$((i+2)); \
	    if [ $$i -ge $(TEAM_NS_TIMEOUT) ]; then \
	      echo "    $$t: namespace never appeared — is the ResourceSet 'teams' reconciling?"; exit 1; \
	    fi; \
	    sleep 2; \
	  done; \
	  kubectl -n $$t create secret generic sops-age \
	    --from-file=age.agekey=$(KEYS_DIR)/$$t/age.agekey \
	    --dry-run=client -o yaml | kubectl apply -f - ; \
	  kubectl -n $$t create secret generic cosign-pub \
	    --from-file=cosign.pub=$(COSIGN_KEYS_DIR)/$$t/cosign.pub \
	    --dry-run=client -o yaml | kubectl apply -f - ; \
	done
	@kubectl -n flux-system create secret generic cosign-pub-platform \
	  --from-file=cosign.pub=$(COSIGN_KEYS_DIR)/platform/cosign.pub \
	  --dry-run=client -o yaml | kubectl apply -f -

team-sops-encrypt:
	@test -n "$(TEAM)" || { echo "TEAM=<name> required"; exit 1; }
	@test -n "$(FILE)" || { echo "FILE=<path relative to repos/$(TEAM)> required"; exit 1; }
	@echo "==> Encrypting repos/$(TEAM)/$(FILE) with the $(TEAM) age key"
	@cd repos/$(TEAM) && SOPS_AGE_KEY_FILE=$(CURDIR)/$(KEYS_DIR)/$(TEAM)/age.agekey \
	  sops --encrypt --in-place $(FILE)

team-sops-decrypt:
	@test -n "$(TEAM)" || { echo "TEAM=<name> required"; exit 1; }
	@test -n "$(FILE)" || { echo "FILE=<path relative to repos/$(TEAM)> required"; exit 1; }
	@cd repos/$(TEAM) && SOPS_AGE_KEY_FILE=$(CURDIR)/$(KEYS_DIR)/$(TEAM)/age.agekey \
	  sops --decrypt $(FILE)

team-status:
	@test -n "$(TEAM)" || { echo "TEAM=<name> required (one of: $(TEAMS))"; exit 1; }
	@echo "==> Namespaces owned by $(TEAM)"
	@kubectl get namespace -l platform.k8s-base/team=$(TEAM) \
	  -L platform.k8s-base/role,pod-security.kubernetes.io/enforce
	@echo ""
	@echo "==> Sources and Kustomizations in $(TEAM)"
	@flux get sources oci -n $(TEAM) || true
	@flux get kustomizations -n $(TEAM) || true
	@echo ""
	@echo "==> Secrets the platform injected out of band"
	@kubectl -n $(TEAM) get secret sops-age cosign-pub 2>&1 || true
	@echo ""
	@echo "==> Workloads"
	@for ns in $$(kubectl get namespace -l platform.k8s-base/team=$(TEAM),platform.k8s-base/role=team-workload -o name | cut -d/ -f2); do \
	  echo "--- $$ns"; \
	  kubectl -n $$ns get pods -o wide 2>&1 | sed 's/^/    /'; \
	done
	@echo ""
	@echo "==> Effective permissions of the $(TEAM) reconciler in its first workload namespace"
	@ns=$$(kubectl get namespace -l platform.k8s-base/team=$(TEAM),platform.k8s-base/role=team-workload \
	        -o jsonpath='{.items[0].metadata.name}'); \
	  echo "    namespace: $$ns"; \
	  kubectl auth can-i --list \
	    --as=system:serviceaccount:$(TEAM):flux -n $$ns 2>&1 | head -20 | sed 's/^/    /'

team-kubeconfig:
	@test -n "$(TEAM)" || { echo "TEAM=<name> required (one of: $(TEAMS))"; exit 1; }
	@mkdir -p $(KEYS_DIR)/$(TEAM)
	@token=$$(kubectl -n $(TEAM) create token flux --duration=24h); \
	 server=$$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'); \
	 ca=$$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'); \
	 { \
	   echo "apiVersion: v1"; \
	   echo "kind: Config"; \
	   echo "current-context: $(TEAM)"; \
	   echo "clusters:"; \
	   echo "  - name: $(CLUSTER_NAME)"; \
	   echo "    cluster:"; \
	   echo "      server: $$server"; \
	   echo "      certificate-authority-data: $$ca"; \
	   echo "contexts:"; \
	   echo "  - name: $(TEAM)"; \
	   echo "    context:"; \
	   echo "      cluster: $(CLUSTER_NAME)"; \
	   echo "      namespace: $(TEAM)"; \
	   echo "      user: $(TEAM)-flux"; \
	   echo "users:"; \
	   echo "  - name: $(TEAM)-flux"; \
	   echo "    user:"; \
	   echo "      token: $$token"; \
	 } > $(KEYS_DIR)/$(TEAM)/kubeconfig
	@chmod go-rwx $(KEYS_DIR)/$(TEAM)/kubeconfig
	@echo "==> Wrote $(KEYS_DIR)/$(TEAM)/kubeconfig (24h token for serviceaccount/$(TEAM):flux)"
	@echo "    Use it with: KUBECONFIG=$(KEYS_DIR)/$(TEAM)/kubeconfig kubectl get pods -n $(TEAM)-apps"
