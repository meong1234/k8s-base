.PHONY: env-help env-check smoke

CLUSTER_ENV  ?= local
FLEET_DIR    ?= repos/fleet/clusters/$(CLUSTER_ENV)
CLUSTER_VARS ?= $(FLEET_DIR)/cluster-vars.yaml
TEAMS_INPUTS ?= $(FLEET_DIR)/teams-inputs.yaml

ENV_CHECK_DIR := tmp/env-check
ENV_CHECK_N   := 16

# Every unit is a root of its own: <unit>/base builds on its own by contract,
# and <unit>/envs/<env> is what the cluster roster actually points at, so both
# are built even though the repo root reaches them transitively - a base that
# only builds once an env patch has papered over it is a base nobody can trust.
# Team units sit two levels deep (apps/<unit>, batch/<unit>, edges/<unit>);
# platform and infra units one level deep. repos/*/clusters/*/* catches the
# second-stage rosters (platform config, infra issuers).
# repos/infra/policies/base/prod is listed by hand, and is the reason the line
# exists: policies/prod/ is referenced by no kustomization on a dev-tier
# cluster (docs/11-environments.md), so no parent reaches it and nothing would
# notice the day it stopped building. A root nobody builds is a root nobody
# can trust.
ENV_ROOT_GLOBS := repos/* repos/*/clusters/* repos/*/clusters/*/* \
                  repos/*/*/base repos/*/*/envs/* \
                  repos/*/*/*/base repos/*/*/*/envs/* \
                  repos/fleet/clusters/* repos/fleet/clusters/*/bootstrap \
                  repos/fleet/base/flux-system \
                  repos/infra/policies/base/prod demos/*

ENV_ROOTS := $(sort $(patsubst %/kustomization.yaml,%,$(wildcard $(addsuffix /kustomization.yaml,$(ENV_ROOT_GLOBS)))))

# Recursive: TEAMS comes from scripts/k8s.mk, which make includes after this file.
ENV_TEAM_ROOTS = $(sort $(foreach t,$(TEAMS),$(filter repos/$(t) repos/$(t)/%,$(ENV_ROOTS))))

# The five keys repos/fleet/base/teams.yaml stamps into each team's own
# cluster-vars copy. A team manifest may reference these and nothing else: the
# other keys exist only in flux-system, so ${OCI_TAG} in a team repo passes
# check 3 and then fails on the cluster. That gap is check 5.
ENV_TEAM_VARS := CLUSTER_ENV CLUSTER_TIER CLUSTER_DOMAIN PUBLIC_PORT INTERNAL_PORT

ENV_BOUNDARY_RE := local-dev\.test|k3d-local-dev-registry|local-ca|:8443|:8444|platform: k3d|172\.28\.0\.250|partner-bank

# repos/team-b/batch/partner/base/ addresses the partner by api.partner-bank.test,
# which is the allow-listed contract hostname rather than a k3d address, so it
# stays in base/ even though the unit has an envs/local to move it into. Named
# here so the exception is reviewable instead of absent from the pattern.
ENV_BOUNDARY_SKIP_RE := /(envs|clusters)/local/|^repos/team-b/batch/partner/base/

# Check 14 compares three copies of one list, in two repos, because RBAC cannot
# read a ConfigMap: platform-policy-params' jitRoles (infra), the ClusterRoles
# labelled standing-binding: forbidden (infra), and the resourceNames the access
# warden holds `bind` on (platform). The literal in the warden's Role is load
# bearing and cannot be removed; it can only be asserted.
#
# Checks 13 and 14 read $(IDENTITY_USERS) and $(DEX_USERS_CM) from
# scripts/identity.mk, which make includes after this file; both are recursive
# variables and the recipes expand them at run time, when every include has been
# read. Check 14's one exception: a built-in ClusterRole is reconciled by the
# apiserver's RBAC bootstrapper, which owns its metadata, so this repo cannot
# label it and the check must not expect the label.
ENV_JIT_BUILTIN_ROLES := cluster-admin

# A credentialName on a DestinationRule is resolved by istiod in the namespace of
# the waypoint that originates the TLS, not in the DestinationRule's own, so
# check 15 looks in the one egress namespace the platform owns. During `make up`
# the check runs before platform-ks has created that namespace (the platform
# artifacts are pushed, and so checked, as part of flux-bootstrap), so a missing
# namespace is a skip, not a failure; a missing Secret in a namespace that
# exists is the real finding.
ENV_EGRESS_NS := platform-egress

# Check 16. Every directory under repos/ is the root of a git repo that does not
# exist yet: on a real platform `infra`, `platform` and each team are separate
# repos with separate reviewers, and this tree is the local stand-in for all of
# them. A relative path that climbs out of its own directory is therefore a
# reference no real checkout could resolve, and it reads as working code here
# because the sibling happens to be on the same disk. The check counts how deep
# a file sits inside its repo (apps/podinfo/envs/local/ is four) and refuses a
# path with more `../` than that; the deepest legitimate climb is the roster's
# ../../<group>/<unit>/envs/<env> from clusters/<env>/, two from depth two.
ENV_SPLIT_RE := (\.\./)+[A-Za-z0-9._/-]*

env-help:
	@echo "Environment Commands:"
	@echo "--------------------"
	@echo "  env-check        - The fifteen repo checks for CLUSTER_ENV=$(CLUSTER_ENV): every root builds,"
	@echo "                     every Secret is SOPS-encrypted, no \$${VAR} survives substitution,"
	@echo "                     no k3d literal outside envs/local and clusters/local, team roots use"
	@echo "                     only team-readable keys, every unit has an envs/<env> per env,"
	@echo "                     the partner roster matches its keys, every recipient is this"
	@echo "                     environment's, no stray secret, repo root and clusters/<env> agree,"
	@echo "                     no renaming under team-sec-ops, the tier component matches"
	@echo "                     CLUSTER_TIER, the Dex roster matches identity/users.yaml, the"
	@echo "                     just-in-time role list matches its labels, every egress"
	@echo "                     credential exists (cluster-side), and no repo under repos/"
	@echo "                     reaches into another"
	@echo "  smoke            - What a real environment runs instead of the demos: Flux is Ready, the"
	@echo "                     team boundary holds, and a secured public path answers 403 without a token"
	@echo ""

# Check 3 hands envsubst a shell-format argument built from the cluster-vars
# keys, so that only those names are substituted: a bcrypt hash or any other
# literal $ in a rendered manifest is left alone, and every ${VAR} a root
# references but cluster-vars does not define survives into the grep that
# follows - which is how the unset-variable half of the check is implemented.
# Objects annotated kustomize.toolkit.fluxcd.io/substitute: disabled are
# dropped before that pass, because Flux will not substitute them either.
# Check 5 is the same pass over the team roots only, with the format restricted
# to ENV_TEAM_VARS.
#
# A reference may also be written $${KEY:=default}, which Flux honours and GNU
# envsubst does not, so those survive the pass above untouched and the grep
# after it does not match them. They get their own assertion: the name must
# still be a declared key. The default is there so that the revision which
# introduces a key can apply at all - cluster-vars is artifact content, and a
# whole build is substituted before any of it is applied - and not so that an
# environment can omit the key.
#
# Checks 1-14 are offline and ride the env-check dependency in front of every
# push; check 15 needs an API server and prints "skip" without one. Each check
# that cannot assert appends a line to $(ENV_CHECK_DIR)/skipped, which the last
# line counts.
env-check:
	@echo "==> env-check (CLUSTER_ENV=$(CLUSTER_ENV), vars $(CLUSTER_VARS))"
	@command -v kustomize >/dev/null 2>&1 || { echo "Error: kustomize not found - run 'make brew-setup-all'"; exit 1; }
	@command -v envsubst >/dev/null 2>&1 || { echo "Error: envsubst not found - run 'make brew-setup-all'"; exit 1; }
	@command -v yq >/dev/null 2>&1 || { echo "Error: yq not found - run 'make brew-setup-all'"; exit 1; }
	@test -n "$(strip $(ENV_ROOTS))" || { echo "  !! 1/$(ENV_CHECK_N) no kustomize root discovered under $(ENV_ROOT_GLOBS)"; exit 1; }
	@rm -rf $(ENV_CHECK_DIR)
	@mkdir -p $(ENV_CHECK_DIR)
	@: >$(ENV_CHECK_DIR)/skipped
	@set -e; \
	N=0; \
	for root in $(ENV_ROOTS); do \
	  out=$(ENV_CHECK_DIR)/$$(echo $$root | tr '/' '_').yaml; \
	  kustomize build $$root >$$out 2>$$out.err || { \
	    echo "  !! 1/$(ENV_CHECK_N) kustomize build failed: $$root"; \
	    sed 's/^/       /' $$out.err; \
	    exit 1; }; \
	  N=$$((N+1)); \
	done; \
	echo "  ok 1/$(ENV_CHECK_N) every root builds ($$N roots)"
	@set -e; \
	SECRETS=$$(grep -rl '^kind: Secret' repos/ || true); \
	if [ -z "$$SECRETS" ]; then \
	  echo "  ok 2/$(ENV_CHECK_N) no Secret under repos/"; \
	else \
	  LEAK=$$(echo "$$SECRETS" | xargs grep -L 'ENC\[' || true); \
	  test -z "$$LEAK" || { \
	    echo "  !! 2/$(ENV_CHECK_N) Secret under repos/ is not SOPS-encrypted:"; \
	    echo "$$LEAK" | sed 's/^/       /'; \
	    exit 1; }; \
	  echo "  ok 2/$(ENV_CHECK_N) every Secret under repos/ is SOPS-encrypted ($$(echo "$$SECRETS" | wc -l | tr -d ' ') files)"; \
	fi
	@set -e; \
	test -f $(CLUSTER_VARS) || { echo "  !! 3/$(ENV_CHECK_N) $(CLUSTER_VARS) not found"; exit 1; }; \
	yq -r '.data | to_entries | .[] | .key + "=" + (.value | tostring)' $(CLUSTER_VARS) >$(ENV_CHECK_DIR)/vars.env; \
	while IFS= read -r kv; do export "$$kv"; done <$(ENV_CHECK_DIR)/vars.env; \
	cut -d= -f1 $(ENV_CHECK_DIR)/vars.env >$(ENV_CHECK_DIR)/vars.keys; \
	FMT=$$(cut -d= -f1 $(ENV_CHECK_DIR)/vars.env | awk '{printf "$${%s} ", $$0}'); \
	test -n "$$FMT" || { echo "  !! 3/$(ENV_CHECK_N) $(CLUSTER_VARS) has no data keys"; exit 1; }; \
	for root in $(ENV_ROOTS); do \
	  out=$(ENV_CHECK_DIR)/$$(echo $$root | tr '/' '_').yaml; \
	  src=$$out; \
	  if grep -q 'kustomize.toolkit.fluxcd.io/substitute: disabled' $$out; then \
	    yq ea 'select(.metadata.annotations."kustomize.toolkit.fluxcd.io/substitute" != "disabled")' $$out >$$out.sub; \
	    src=$$out.sub; \
	  fi; \
	  LEFT=$$(envsubst "$$FMT" <$$src | grep -o '\$${[A-Za-z_][A-Za-z0-9_]*}' | sort -u || true); \
	  test -z "$$LEFT" || { \
	    echo "  !! 3/$(ENV_CHECK_N) $$root references variables that are not keys in $(CLUSTER_VARS):"; \
	    echo "$$LEFT" | sed 's/^/       /'; \
	    exit 1; }; \
	  for v in $$(grep -oE '\$$\{[A-Za-z_][A-Za-z0-9_]*:=' $$src | sed 's/^\$$[{]//; s/:=$$//' | sort -u); do \
	    grep -qx "$$v" $(ENV_CHECK_DIR)/vars.keys || { \
	      echo "  !! 3/$(ENV_CHECK_N) $$root defaults \$${$$v:=...}, but $(CLUSTER_VARS) does not declare $$v:"; \
	      echo "       a default exists so that introducing a key cannot deadlock a running"; \
	      echo "       cluster, never so that an environment can leave the key out"; \
	      exit 1; }; \
	  done; \
	done; \
	echo "  ok 3/$(ENV_CHECK_N) no \$${VAR} survives substitution and every default is declared ($$(wc -l <$(ENV_CHECK_DIR)/vars.env | tr -d ' ') variables)"
	@set -e; \
	HITS=$$(grep -rnE '$(ENV_BOUNDARY_RE)' repos --exclude='*.md' | grep -vE '$(ENV_BOUNDARY_SKIP_RE)' || true); \
	test -z "$$HITS" || { \
	  echo "  !! 4/$(ENV_CHECK_N) runtime literal outside envs/local and clusters/local:"; \
	  echo "$$HITS" | sed 's/^/       /'; \
	  exit 1; }; \
	echo "  ok 4/$(ENV_CHECK_N) boundary holds: no k3d literal outside envs/local and clusters/local"
	@set -e; \
	test -n "$(strip $(ENV_TEAM_ROOTS))" || { echo "  !! 5/$(ENV_CHECK_N) no team root discovered for TEAMS=$(TEAMS)"; exit 1; }; \
	while IFS= read -r kv; do export "$$kv"; done <$(ENV_CHECK_DIR)/vars.env; \
	FMT=$$(for k in $(ENV_TEAM_VARS); do printf '$${%s} ' $$k; done); \
	for root in $(ENV_TEAM_ROOTS); do \
	  out=$(ENV_CHECK_DIR)/$$(echo $$root | tr '/' '_').yaml; \
	  LEFT=$$(envsubst "$$FMT" <$$out | grep -o '\$${[A-Za-z_][A-Za-z0-9_]*}' | sort -u || true); \
	  test -z "$$LEFT" || { \
	    echo "  !! 5/$(ENV_CHECK_N) $$root references keys that are not stamped into a team namespace:"; \
	    echo "$$LEFT" | sed 's/^/       /'; \
	    echo "       team-readable keys are: $(ENV_TEAM_VARS)"; \
	    exit 1; }; \
	done; \
	echo "  ok 5/$(ENV_CHECK_N) team roots use only the five stamped keys ($$(echo $(ENV_TEAM_ROOTS) | wc -w | tr -d ' ') roots)"
	@set -e; \
	ENVS=$$(for d in repos/fleet/clusters/*/; do basename $$d; done); \
	U=0; \
	for t in $(TEAMS); do \
	  test -d repos/$$t || { echo "  !! 6/$(ENV_CHECK_N) TEAMS names $$t but repos/$$t does not exist"; exit 1; }; \
	  UNITS=$$(find repos/$$t -type d -name base -not -path '*/base/*' -not -path '*/envs/*' | sed 's#/base$$##' | sort); \
	  test -n "$$UNITS" || { echo "  !! 6/$(ENV_CHECK_N) repos/$$t holds no unit: no <group>/<unit>/base/ directory"; exit 1; }; \
	  for u in $$UNITS; do \
	    for e in $$ENVS; do \
	      test -f $$u/envs/$$e/kustomization.yaml || { \
	        echo "  !! 6/$(ENV_CHECK_N) $$u/envs/$$e/kustomization.yaml is missing, but $$e is an environment and every unit carries every environment"; \
	        exit 1; }; \
	    done; \
	    BACK=$$(grep -rn 'envs/' $$u/base --exclude='*.md' | grep -vE ':[0-9]+:[[:space:]]*#' || true); \
	    test -z "$$BACK" || { \
	      echo "  !! 6/$(ENV_CHECK_N) $$u/base points back at an envs/ directory:"; \
	      echo "$$BACK" | sed 's/^/       /'; \
	      exit 1; }; \
	    U=$$((U+1)); \
	  done; \
	done; \
	echo "  ok 6/$(ENV_CHECK_N) every team unit has an envs/<env> per environment ($$U units, $$(echo $$ENVS | wc -w | tr -d ' ') declared)"
	@set -e; \
	N=0; \
	for k in repos/*/edges/partner-api/envs/*/kustomization.yaml; do \
	  test -f "$$k" || continue; \
	  d=$$(dirname $$k); \
	  ROSTER=$$(yq -r '.resources[]? | select(test("partners/"))' $$k | sed 's#.*/##' | sort); \
	  KEYS=$$(for f in $$d/*-keys.enc.yaml; do test -f "$$f" || continue; basename $$f -keys.enc.yaml; done | sort); \
	  test "$$ROSTER" = "$$KEYS" || { \
	    echo "  !! 7/$(ENV_CHECK_N) $$d: the roster and the key files disagree"; \
	    echo "       roster: $$(echo $$ROSTER | tr '\n' ' ')"; \
	    echo "       keys:   $$(echo $$KEYS | tr '\n' ' ')"; \
	    exit 1; }; \
	  N=$$((N+1)); \
	done; \
	echo "  ok 7/$(ENV_CHECK_N) the partner roster matches its key files ($$N checked)"
	@set -e; \
	N=0; S=0; \
	for d in repos/*; do \
	  test -d "$$d" || continue; \
	  t=$$(echo $$d | cut -d/ -f2); \
	  for f in $$(find $$d -path '*/envs/$(CLUSTER_ENV)/*' -name '*.enc.yaml' | sort); do \
	    PUB=$(KEYS_DIR)/$$t/age.pub; \
	    if [ ! -f "$$PUB" ]; then \
	      S=$$((S+1)); continue; \
	    fi; \
	    WANT=$$(tr -d '[:space:]' <$$PUB); \
	    GOT=$$(yq -r '.sops.age[].recipient' $$f | sort -u); \
	    test "$$GOT" = "$$WANT" || { \
	      echo "  !! 8/$(ENV_CHECK_N) $$f is not encrypted to $$PUB:"; \
	      echo "       wants $$WANT"; \
	      echo "       has   $$(echo $$GOT | tr '\n' ' ')"; \
	      exit 1; }; \
	    N=$$((N+1)); \
	  done; \
	done; \
	if [ $$S -gt 0 ] && [ $$N -eq 0 ]; then \
	  echo "  skip 8/$(ENV_CHECK_N) no public key under $(KEYS_DIR)/ - run 'make team-keys' (or 'make keys-migrate' on a pre-P0 tree)"; \
	  echo "8" >>$(ENV_CHECK_DIR)/skipped; \
	else \
	  echo "  ok 8/$(ENV_CHECK_N) every envs/$(CLUSTER_ENV) secret is encrypted to this environment's recipient ($$N files, $$S unverifiable)"; \
	fi
	@set -e; \
	N=0; \
	for r in repos/*; do \
	  test -d "$$r" || continue; \
	  STRAY=$$(find $$r -name '*.enc.yaml' -not -path '*/envs/*' | sort); \
	  test -z "$$STRAY" || { \
	    echo "  !! 9/$(ENV_CHECK_N) $$r: every *.enc.yaml must live under a unit's envs/<env>/:"; \
	    echo "$$STRAY" | sed 's/^/       /'; \
	    exit 1; }; \
	  N=$$((N+1)); \
	done; \
	echo "  ok 9/$(ENV_CHECK_N) no secret outside an envs/ directory ($$N repos)"
	@set -e; \
	N=0; \
	for t in $(TEAMS); do \
	  test -f repos/$$t/clusters/$(CLUSTER_ENV)/kustomization.yaml || { \
	    echo "  !! 10/$(ENV_CHECK_N) repos/$$t/clusters/$(CLUSTER_ENV)/kustomization.yaml is missing: the team Kustomization points at it"; \
	    exit 1; }; \
	  root=$(ENV_CHECK_DIR)/repos_$$t.yaml; \
	  env=$(ENV_CHECK_DIR)/repos_$${t}_clusters_$(CLUSTER_ENV).yaml; \
	  test -f "$$env" || { echo "  !! 10/$(ENV_CHECK_N) repos/$$t/clusters/$(CLUSTER_ENV) was not built"; exit 1; }; \
	  diff -u $$root $$env >$(ENV_CHECK_DIR)/$$t.roots.diff || { \
	    echo "  !! 10/$(ENV_CHECK_N) repos/$$t and repos/$$t/clusters/$(CLUSTER_ENV) render different output:"; \
	    sed 's/^/       /' $(ENV_CHECK_DIR)/$$t.roots.diff | head -20; \
	    exit 1; }; \
	  N=$$((N+1)); \
	done; \
	echo "  ok 10/$(ENV_CHECK_N) repo root and clusters/$(CLUSTER_ENV) render the same output ($$N teams)"
	@set -e; \
	HITS=$$(grep -rnE 'namePrefix|nameSuffix|secretGenerator|configMapGenerator' repos/team-sec-ops --exclude='*.md' || true); \
	test -z "$$HITS" || { \
	  echo "  !! 11/$(ENV_CHECK_N) a rewritten name breaks a targetRef, credentialRef or credentialName silently:"; \
	  echo "$$HITS" | sed 's/^/       /'; \
	  exit 1; }; \
	echo "  ok 11/$(ENV_CHECK_N) no renaming under repos/team-sec-ops"
	@set -e; \
	K=repos/infra/clusters/$(CLUSTER_ENV)/kustomization.yaml; \
	test -f $$K || { echo "  !! 12/$(ENV_CHECK_N) $$K not found"; exit 1; }; \
	COMPS=$$(yq -r '.components[]? | select(test("policies/tier-"))' $$K || true); \
	if [ -z "$$COMPS" ]; then \
	  echo "  ok 12/$(ENV_CHECK_N) $$K selects no tier component (none exists yet)"; \
	else \
	  test "$$(echo "$$COMPS" | wc -l | tr -d ' ')" = 1 || { \
	    echo "  !! 12/$(ENV_CHECK_N) $$K selects more than one tier component:"; \
	    echo "$$COMPS" | sed 's/^/       /'; \
	    exit 1; }; \
	  TIER=$$(yq -r '.data.CLUSTER_TIER' $(CLUSTER_VARS)); \
	  test "$${COMPS##*/policies/tier-}" = "$$TIER" || { \
	    echo "  !! 12/$(ENV_CHECK_N) $$K selects $$COMPS but $(CLUSTER_VARS) says CLUSTER_TIER=$$TIER"; \
	    exit 1; }; \
	  echo "  ok 12/$(ENV_CHECK_N) the tier component matches CLUSTER_TIER=$$TIER"; \
	fi
	@set -e; \
	test -f $(IDENTITY_USERS) || { echo "  !! 13/$(ENV_CHECK_N) $(IDENTITY_USERS) not found"; exit 1; }; \
	if [ ! -f $(DEX_USERS_CM) ]; then \
	  echo "  skip 13/$(ENV_CHECK_N) $(DEX_USERS_CM) absent: $(CLUSTER_ENV) declares no static-password connector"; \
	  echo "13" >>$(ENV_CHECK_DIR)/skipped; \
	else \
	  ROSTER=$$(yq -r '.users[].email' $(IDENTITY_USERS) | sort); \
	  STATIC=$$(yq -r '.data["values.yaml"]' $(DEX_USERS_CM) | yq -r '.config.staticPasswords[].email' | sort); \
	  test "$$ROSTER" = "$$STATIC" || { \
	    echo "  !! 13/$(ENV_CHECK_N) $(DEX_USERS_CM) is stale - run 'make dex-render'"; \
	    printf '%s\n' "$$ROSTER" >$(ENV_CHECK_DIR)/roster.txt; \
	    printf '%s\n' "$$STATIC" >$(ENV_CHECK_DIR)/static.txt; \
	    comm -23 $(ENV_CHECK_DIR)/roster.txt $(ENV_CHECK_DIR)/static.txt \
	      | sed 's/^/       in the roster, no static password: /'; \
	    comm -13 $(ENV_CHECK_DIR)/roster.txt $(ENV_CHECK_DIR)/static.txt \
	      | sed 's/^/       a static password, not in the roster: /'; \
	    exit 1; }; \
	  BLANK=$$(yq -r '.data["values.yaml"]' $(DEX_USERS_CM) \
	    | yq -r '.config.staticPasswords[] | select((.hash // "") == "") | .email'); \
	  test -z "$$BLANK" || { \
	    echo "  !! 13/$(ENV_CHECK_N) a static password in $(DEX_USERS_CM) has no hash:"; \
	    echo "$$BLANK" | sed 's/^/       /'; \
	    exit 1; }; \
	  echo "  ok 13/$(ENV_CHECK_N) the Dex roster matches $(IDENTITY_USERS) ($$(echo "$$ROSTER" | wc -w | tr -d ' ') users)"; \
	fi
	@set -e; \
	P=$(ENV_CHECK_DIR)/repos_infra.yaml; \
	test -f $$P || { echo "  !! 14/$(ENV_CHECK_N) repos/infra was not built"; exit 1; }; \
	DECLARED=$$(yq ea 'select(.kind == "ConfigMap" and .metadata.name == "platform-policy-params") | .data.jitRoles' $$P \
	  | tr ',' '\n' | sed 's/^ *//; s/ *$$//' | grep -vx -- '---' | grep . | sort -u); \
	test -n "$$DECLARED" || { \
	  echo "  !! 14/$(ENV_CHECK_N) platform-policy-params declares no jitRoles key, so jit-binding-lock locks nothing"; \
	  exit 1; }; \
	LABELLED=$$(yq ea 'select(.kind == "ClusterRole" and .metadata.labels."platform.k8s-base/standing-binding" == "forbidden") | .metadata.name' $$P \
	  | grep -vx -- '---' | grep . | sort -u); \
	BUILTIN=$$(printf '%s\n' $(ENV_JIT_BUILTIN_ROLES)); \
	WANT=$$(printf '%s\n' $$DECLARED | grep -vxF "$$BUILTIN" | sort -u || true); \
	test "$$WANT" = "$$LABELLED" || { \
	  echo "  !! 14/$(ENV_CHECK_N) jitRoles and the standing-binding: forbidden labels disagree:"; \
	  echo "       jitRoles, excluding the built-ins ($(ENV_JIT_BUILTIN_ROLES)): $$(echo $$WANT | tr '\n' ' ')"; \
	  echo "       ClusterRoles carrying the label:                             $$(echo $$LABELLED | tr '\n' ' ')"; \
	  echo "       a role in one list and not the other is a role the lock or the reader is wrong about"; \
	  exit 1; }; \
	Q=$(ENV_CHECK_DIR)/repos_platform.yaml; \
	test -f $$Q || { echo "  !! 14/$(ENV_CHECK_N) repos/platform was not built"; exit 1; }; \
	BIND=$$(yq ea 'select(.kind == "ClusterRole") | .rules[] | select(.verbs[] == "bind") | .resourceNames[]' $$Q \
	  | grep -vx -- '---' | grep . | sort -u); \
	test "$$BIND" = "$$DECLARED" || { \
	  echo "  !! 14/$(ENV_CHECK_N) jitRoles and the access warden's bind grant disagree:"; \
	  echo "       jitRoles:                       $$(echo $$DECLARED | tr '\n' ' ')"; \
	  echo "       ClusterRoles the warden may bind: $$(echo $$BIND | tr '\n' ' ')"; \
	  echo "       a role the lock covers but the warden cannot bind is a role no approval can ever grant;"; \
	  echo "       a role the warden can bind but the lock does not cover is a standing binding nobody stops"; \
	  exit 1; }; \
	echo "  ok 14/$(ENV_CHECK_N) the just-in-time role list matches its labels and the warden's bind grant ($$(echo $$DECLARED | wc -w | tr -d ' ') roles)"
	@set -e; \
	CREDS=$$(grep -h 'credentialName:' $(ENV_CHECK_DIR)/*.yaml 2>/dev/null | awk '{print $$2}' | tr -d '"' | sort -u || true); \
	if [ -z "$$CREDS" ]; then \
	  echo "  ok 15/$(ENV_CHECK_N) no DestinationRule names an egress credential"; \
	elif ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then \
	  echo "  skip 15/$(ENV_CHECK_N) no cluster reachable; $$(echo $$CREDS | wc -w | tr -d ' ') unverified"; \
	  echo "15" >>$(ENV_CHECK_DIR)/skipped; \
	elif ! kubectl get namespace $(ENV_EGRESS_NS) >/dev/null 2>&1; then \
	  echo "  skip 15/$(ENV_CHECK_N) namespace $(ENV_EGRESS_NS) does not exist yet (platform-ks has not reconciled); $$(echo $$CREDS | wc -w | tr -d ' ') unverified"; \
	  echo "15" >>$(ENV_CHECK_DIR)/skipped; \
	else \
	  for c in $$CREDS; do \
	    kubectl -n $(ENV_EGRESS_NS) get secret $$c >/dev/null 2>&1 || { \
	      echo "  !! 15/$(ENV_CHECK_N) Secret $(ENV_EGRESS_NS)/$$c is named by a DestinationRule credentialName but does not exist"; \
	      echo "       on $(CLUSTER_ENV) it is filled by 'make partner-sim-inject'; the credential stays WARMING with no error until it is"; \
	      exit 1; }; \
	  done; \
	  echo "  ok 15/$(ENV_CHECK_N) every egress credential exists in $(ENV_EGRESS_NS) ($$(echo $$CREDS | wc -w | tr -d ' ') checked)"; \
	fi
	@set -e; \
	N=0; R=0; \
	for r in repos/*/; do \
	  test -d "$$r" || continue; \
	  R=$$((R+1)); \
	  for f in $$(find $$r -name '*.yaml' | sort); do \
	    rel=$${f#$$r}; dir=$$(dirname "$$rel"); \
	    if [ "$$dir" = "." ]; then depth=0; else depth=$$(echo "$$dir" | awk -F/ '{print NF}'); fi; \
	    for p in $$(grep -oE '$(ENV_SPLIT_RE)' "$$f" 2>/dev/null | sort -u); do \
	      ups=$$(printf '%s' "$$p" | grep -o '\.\./' | wc -l | tr -d ' '); \
	      test "$$ups" -le "$$depth" || { \
	        echo "  !! 16/$(ENV_CHECK_N) $$f climbs out of $$r, which is a git repo of its own:"; \
	        echo "       $$p"; \
	        echo "       nothing under repos/<name>/ may reference a sibling repo; a shared"; \
	        echo "       manifest is either copied, or published by the platform and pulled"; \
	        exit 1; }; \
	      N=$$((N+1)); \
	    done; \
	  done; \
	done; \
	echo "  ok 16/$(ENV_CHECK_N) every repo under repos/ is self-contained ($$R repos, $$N relative paths resolved)"
	@S=$$(wc -l <$(ENV_CHECK_DIR)/skipped | tr -d ' '); \
	if [ "$$S" = 0 ]; then \
	  echo "env-check: $(ENV_CHECK_N)/$(ENV_CHECK_N) pass"; \
	else \
	  echo "env-check: $$(($(ENV_CHECK_N)-$$S))/$(ENV_CHECK_N) pass, $$S skipped"; \
	fi

# What a real environment runs instead of the demos (M6): three assertions, no
# literal, cheap enough after every promotion. A demo teaches and may break
# things on the way; a smoke test asserts and must not, which is why it is
# named `smoke` and not `demo-smoke`.
SMOKE_TEAM       ?=
SMOKE_SRC_NS     ?=
SMOKE_DST_NS     ?=
SMOKE_DST_SVC    ?=
SMOKE_FOREIGN_NS ?=
# Assertion 3's 200 half needs a token this environment's identity provider
# minted for the public API, and which path is worth asking for is the route
# review's answer, not make's.
#
# The path it asks for must be a `jwt` route: the public host serves two auth
# classes and an `auth: none` path correctly answers 200 without a token, so the
# first apiPaths entry is not a safe default. Discovered from the edge's own
# labels, with the apiPaths entry only as a last resort.
SMOKE_EDGE_NS    ?= public-api
SMOKE_PATH       ?=
SMOKE_TOKEN      ?=
# Assertion 3 reaches the public edge from the operator's laptop, so an
# environment whose edge is not publicly resolvable with a publicly trusted
# certificate has to say how to reach it. Empty is the real-environment case;
# `local` needs its own CA and a --resolve, which is why the demos have
# edge_curl and this does not hard-code one.
SMOKE_CURL_OPTS  ?=

smoke:
	@echo "==> smoke (CLUSTER_ENV=$(CLUSTER_ENV), vars $(CLUSTER_VARS))"
	@command -v flux >/dev/null 2>&1 || { echo "Error: flux CLI not found - run 'make brew-setup-all'"; exit 1; }
	@command -v yq >/dev/null 2>&1 || { echo "Error: yq not found - run 'make brew-setup-all'"; exit 1; }
	@kubectl cluster-info >/dev/null 2>&1 || { echo "Error: no reachable cluster for CLUSTER_ENV=$(CLUSTER_ENV)"; exit 1; }
	@test -f $(CLUSTER_VARS) || { echo "Error: $(CLUSTER_VARS) is missing"; exit 1; }
	@set -e; \
	NOT_READY=$$(flux get all -A 2>/dev/null | grep -v True | grep -vE '^(NAMESPACE|NAME)' | grep . || true); \
	test -z "$$NOT_READY" || { \
	  echo "  !! 1/3 a Flux object is not Ready:"; echo "$$NOT_READY" | sed 's/^/       /'; exit 1; }; \
	RS=$$(kubectl -n flux-system get resourceset teams \
	  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null); \
	test "$$RS" = True || { echo "  !! 1/3 ResourceSet/teams is Ready=$${RS:-<absent>}"; exit 1; }; \
	echo "  ok 1/3 every Flux object is Ready and ResourceSet/teams reconciled"
	@set -e; \
	first_name() { kubectl -n $$2 get $$1 \
	  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null | awk '{print $$1}'; }; \
	TEAM="$(SMOKE_TEAM)"; A="$(SMOKE_SRC_NS)"; B="$(SMOKE_DST_NS)"; \
	if [ -z "$$A" ] || [ -z "$$B" ]; then \
	  for t in $$(kubectl get ns -l platform.k8s-base/team \
	      -o jsonpath='{range .items[*]}{.metadata.labels.platform\.k8s-base/team}{"\n"}{end}' | sort -u); do \
	    set -- $$(kubectl get ns -l platform.k8s-base/team=$$t,platform.k8s-base/role=team-workload \
	      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); \
	    [ $$# -ge 2 ] || continue; \
	    for d in "$$@"; do \
	      [ -n "$$(first_name svc $$d)" ] || continue; \
	      for s in "$$@"; do \
	        [ "$$s" = "$$d" ] && continue; \
	        [ -n "$$(first_name deploy $$s)" ] || continue; \
	        TEAM=$$t; A=$$s; B=$$d; break; \
	      done; \
	      [ -n "$$B" ] && break; \
	    done; \
	    [ -n "$$B" ] && break; \
	  done; \
	fi; \
	test -n "$$A" && test -n "$$B" || { \
	  echo "  !! 2/3 no team has two workload namespaces with a Service in one and a Deployment"; \
	  echo "         in another; name the pair with SMOKE_SRC_NS= SMOKE_DST_NS="; exit 1; }; \
	SVC="$(SMOKE_DST_SVC)"; \
	test -n "$$SVC" || SVC=$$(first_name svc $$B); \
	test -n "$$SVC" || { echo "  !! 2/3 no Service in $$B to call; name one with SMOKE_DST_SVC="; exit 1; }; \
	PORT=$$(kubectl -n $$B get svc $$SVC -o jsonpath='{.spec.ports[0].port}'); \
	URL=http://$$SVC.$$B:$$PORT/; \
	FOREIGN="$(SMOKE_FOREIGN_NS)"; \
	test -n "$$FOREIGN" || FOREIGN=$$(kubectl get ns -l platform.k8s-base/role=team-workload \
	  -o jsonpath="{range .items[?(@.metadata.labels.platform\.k8s-base/team!=\"$$TEAM\")]}{.metadata.name}{\" \"}{end}" \
	  | awk '{print $$1}'); \
	test -n "$$FOREIGN" || { echo "  !! 2/3 no other team's workload namespace; name one with SMOKE_FOREIGN_NS="; exit 1; }; \
	probe() { D=$$(first_name deploy $$1); \
	  test -n "$$D" || { echo no-deployment; return 0; }; \
	  C=$$(kubectl -n $$1 exec deploy/$$D \
	  -- curl -m 10 -s -o /dev/null -w '%{http_code}' $$2 2>/dev/null) || true; \
	  echo "$${C:-000}"; }; \
	IN=$$(probe $$A $$URL); \
	case "$$IN" in 2*|3*) ;; *) \
	  echo "  !! 2/3 $$A -> $$B inside $$TEAM answered '$$IN', and same-team traffic must be allowed"; exit 1;; \
	esac; \
	OUT=$$(probe $$FOREIGN $$URL); \
	case "$$OUT" in \
	  no-deployment) \
	    echo "  !! 2/3 no Deployment in $$FOREIGN to probe the boundary from; name another with SMOKE_FOREIGN_NS="; exit 1;; \
	  2*|3*) \
	    echo "  !! 2/3 $$FOREIGN -> $$B crossed a team boundary (HTTP $$OUT)"; exit 1;; \
	esac; \
	echo "  ok 2/3 $$A -> $$B inside $$TEAM is allowed ($$IN) and $$FOREIGN -> $$B is dropped ($$OUT)"
	@set -e; \
	DOMAIN=$$(yq -r '.data.CLUSTER_DOMAIN' $(CLUSTER_VARS)); \
	PORT=$$(yq -r '.data.PUBLIC_PORT' $(CLUSTER_VARS)); \
	P="$(SMOKE_PATH)"; \
	test -n "$$P" || P=$$(kubectl -n $(SMOKE_EDGE_NS) get httproute \
	  -l platform.k8s-base/auth=jwt \
	  -o jsonpath='{range .items[*]}{.spec.rules[0].matches[0].path.value}{"\n"}{end}' 2>/dev/null \
	  | sed -n '1s|^/*||p'); \
	test -n "$$P" || P=$$(yq -r '[.spec.inputs[]? | .apiPaths // [] | .[]] | .[0] // ""' \
	  $(FLEET_DIR)/teams-inputs.yaml); \
	test -n "$$P" || { echo "  !! 3/3 no apiPaths entry in $(FLEET_DIR)/teams-inputs.yaml; name one with SMOKE_PATH="; exit 1; }; \
	URL=https://api.$$DOMAIN:$$PORT/$$P/; \
	CODE=$$(curl -sS -o /dev/null -m 15 -w '%{http_code}' $(SMOKE_CURL_OPTS) $$URL 2>/dev/null) || true; \
	CODE=$${CODE:-000}; \
	test "$$CODE" = 403 || { echo "  !! 3/3 $$URL answered $$CODE without a token, not 403"; \
	  echo "         (an environment whose edge needs a private CA or a host override wants SMOKE_CURL_OPTS=)"; exit 1; }; \
	if [ -n "$(SMOKE_TOKEN)" ]; then \
	  CODE=$$(curl -sS -o /dev/null -m 15 -w '%{http_code}' $(SMOKE_CURL_OPTS) -H "Authorization: Bearer $(SMOKE_TOKEN)" $$URL 2>/dev/null) || true; \
	  CODE=$${CODE:-000}; \
	  test "$$CODE" = 200 || { echo "  !! 3/3 $$URL answered $$CODE with a token, not 200"; exit 1; }; \
	  echo "  ok 3/3 $$URL is 403 without a token and 200 with one"; \
	else \
	  echo "  ok 3/3 $$URL is 403 without a token (pass SMOKE_TOKEN= to assert the 200 half)"; \
	fi
	@echo "smoke: 3/3 pass"
