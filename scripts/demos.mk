.PHONY: demos-help demo-guard demo-all demo-shards demo-misconfig-namespace demo-netpol demo-mtls \
        demo-cross-team-access demo-egress demo-exposure demo-public-auth demo-partner-api \
        demo-no-prune demo-signature demo-sops demo-psa demo-vap \
        demo-access demo-audit demo-internal-oidc \
        demo-jit demo-breakglass demo-privileged-guard demo-gitops-only \
        demo-shards-cleanup demo-misconfig-namespace-cleanup demo-netpol-cleanup \
        demo-mtls-cleanup demo-cross-team-access-cleanup demo-egress-cleanup \
        demo-exposure-cleanup demo-no-prune-cleanup demo-signature-cleanup demo-psa-cleanup \
        demo-jit-cleanup demo-breakglass-cleanup demo-privileged-guard-cleanup \
        demo-gitops-only-cleanup \
        demo-partner-egress demo-partner-egress-cleanup

DEMOS := shards misconfig-namespace netpol mtls cross-team-access egress partner-egress \
         exposure public-auth partner-api \
         no-prune signature sops psa vap \
         access audit internal-oidc jit breakglass privileged-guard gitops-only

DEMOS_WITH_CLEANUP := shards misconfig-namespace netpol mtls cross-team-access egress partner-egress \
                      exposure no-prune signature psa \
                      jit breakglass privileged-guard gitops-only

DEMO_OUT_DIR := tmp/demos

# M6: the twenty-two demos are local demos, and the read-only-looking ones are
# not read-only - they edit the fleet input and push it, push scratch artifacts
# at :demo, apply deliberately broken objects, and reach the k3d loadbalancer,
# the Dex static users and the partner container by name. One guard rather than
# a per-demo flag, which would be a promise to keep them honest against
# clusters that do not exist. A real environment gets `make smoke` instead.
DEMO_GUARD_MSG = CLUSTER_ENV=$(CLUSTER_ENV): the demos only run on local; assert a real environment with 'make smoke CLUSTER_ENV=$(CLUSTER_ENV)'

demo-guard:
	@test "$(CLUSTER_ENV)" = local || { echo "Error: $(DEMO_GUARD_MSG)"; exit 1; }

DEMO_FLEET_FILE  = $(FLEET_DIR)/teams-inputs.yaml

demos-help:
	@echo "Demo Commands:"
	@echo "-------------"
	@echo "  demo-all                 - Run every demo in order, with cleanups, and print a PASS/FAIL table"
	@echo "  demo-shards              - Shards are decoupled from teams, and a team can be moved between them"
	@echo "  demo-misconfig-namespace - A team cannot accidentally write outside its namespaces"
	@echo "  demo-netpol              - Undeclared cross-team traffic is dropped (Hubble shows the verdict)"
	@echo "  demo-mtls                - Pod-to-pod traffic is HBONE/mTLS on 15008 and identity-bound (SPIFFE)"
	@echo "  demo-cross-team-access   - A cross-team call needs both halves in git, one named identity and one route"
	@echo "  demo-egress              - Outbound traffic leaves only through the allow-listed egress waypoint"
	@echo "  demo-partner-egress      - The egress waypoint, not the team pod, holds the certificate a partner demands"
	@echo "  demo-exposure            - Public exposure needs the platform, team-sec-ops and the owning team"
	@echo "  demo-public-auth         - A secured path needs a Dex token minted for the public API; an open path needs none"
	@echo "  demo-partner-api         - A partner has its own gateway port, certificate, key set and rate limit"
	@echo "  demo-no-prune            - Namespaces survive removal from the ResourceSet inputs"
	@echo "  demo-signature           - Unsigned or foreign-signed artifacts are rejected"
	@echo "  demo-sops                - Per-team SOPS/age secret decryption"
	@echo "  demo-psa                 - PodSecurity restricted by default"
	@echo "  demo-vap                 - Native ValidatingAdmissionPolicy guardrails"
	@echo "  demo-access              - Developer access tiers through real OIDC logins"
	@echo "  demo-audit               - The audit log records which human did what"
	@echo "  demo-internal-oidc       - Internal UIs are reached by login, not by port-forward"
	@echo "  demo-jit                 - exec is granted just-in-time, by someone else, for a bounded window"
	@echo "  demo-breakglass          - four-eyes on cluster-admin, revocable early"
	@echo "  demo-privileged-guard    - data and platform namespaces are exec-free for everyone"
	@echo "  demo-gitops-only         - hand-applied workload objects are caught (warn here, deny on prod)"
	@echo "  Cleanups: $(foreach d,$(DEMOS_WITH_CLEANUP),demo-$(d)-cleanup)"
	@echo "  Transcripts: $(DEMO_OUT_DIR)/<name>.log"
	@echo ""

define demo_begin
  DEMO_NAME=$(1); \
  DEMO_LOG=$(DEMO_OUT_DIR)/$(1).log; \
  DEMO_RAW=$(DEMO_OUT_DIR)/$(1).raw; \
  DEMO_CHECKS=$(DEMO_OUT_DIR)/$(1).checks; \
  DEMO_FAILED=0; \
  mkdir -p $(DEMO_OUT_DIR); : > $$DEMO_LOG; : > $$DEMO_CHECKS; \
  run() { \
    printf '\n$$ %s\n' "$$*"; \
    { eval "$$@"; printf 'exit=%s\n' "$$?"; } > $$DEMO_RAW 2>&1; \
    sed 's/^/    /' $$DEMO_RAW; \
    cat $$DEMO_RAW >> $$DEMO_LOG; \
  }; \
  cond() { \
    _j=""; \
    for _n in 1 2 3; do \
      _j=$$(kubectl -n "$$1" get $$2 $$3 -o json 2>/dev/null) && [ -n "$$_j" ] && break; \
      _j=""; sleep 2; \
    done; \
    [ -n "$$_j" ] || { printf 'read-failed %s/%s %s\n' "$$1" "$$2" "$$3"; return 0; }; \
    printf '%s' "$$_j" \
      | jq -r --arg t "$$4" '.status.conditions[]? | select(.type==$$t) | .status + " " + (.message // "")'; \
  }; \
  wait_for() { \
    _t=$$1; _what=$$2; shift 2; _i=0; \
    printf '    waiting up to %ss for %s\n' "$$_t" "$$_what"; \
    while ! eval "$$@" >/dev/null 2>&1; do \
      _i=$$(( _i + 5 )); \
      if [ $$_i -ge $$_t ]; then printf '    ... NOT observed within %ss\n' "$$_t"; return 1; fi; \
      sleep 5; \
    done; \
    printf '    ... observed after ~%ss\n' "$$_i"; \
  }; \
  section() { printf '\n-- %s\n' "$$*"; : > $$DEMO_LOG; }; \
  expect() { \
    if grep -qE "$$1" $$DEMO_LOG; then printf '    [ok]   %s\n' "$$2" >> $$DEMO_CHECKS; \
    else printf '    [FAIL] %s\n' "$$2" >> $$DEMO_CHECKS; DEMO_FAILED=1; fi; \
  }; \
  expect_not() { \
    if grep -qE "$$1" $$DEMO_LOG; then printf '    [FAIL] %s\n' "$$2" >> $$DEMO_CHECKS; DEMO_FAILED=1; \
    else printf '    [ok]   %s\n' "$$2" >> $$DEMO_CHECKS; fi; \
  }; \
  finish() { \
    printf '\n==> EXPECTED: %s\n' "$$*"; \
    cat $$DEMO_CHECKS; \
    if [ "$$DEMO_FAILED" = 1 ]; then \
      printf '==> DEMO %s: FAIL (full transcript: %s)\n' "$$DEMO_NAME" "$$DEMO_LOG"; exit 1; \
    fi; \
    printf '==> DEMO %s: PASS\n' "$$DEMO_NAME"; \
  }; \
  printf '\n==> DEMO %s: %s\n' "$(1)" "$(2)"
endef

define demo_push
  printf '\n$$ flux push artifact oci://$(OCI_LOCAL_URL)/$(1):demo --path=$(2)  +  cosign sign --key $(COSIGN_KEYS_DIR)/$(3)/cosign.key\n'; \
  _rev=$$(find $(2) -type f -not -name '.DS_Store' -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-12); \
  _digest=$$(flux push artifact oci://$(OCI_LOCAL_URL)/$(1):demo \
      --path=$(2) --source="local://$(2)" --revision="demo@sha1:$$_rev" --output=json \
    | jq -r .digest); \
  printf '    digest: %s\n' "$$_digest"; \
  COSIGN_PASSWORD= cosign sign --yes --key=$(COSIGN_KEYS_DIR)/$(3)/cosign.key \
    $(COSIGN_HTTP_FLAGS) $(COSIGN_EXTRA_FLAGS) $(OCI_LOCAL_URL)/$(1)@$$_digest 2>&1 \
    | sed 's/^/    /'
endef

define demo_attach
  _shard=$$(yq -r '.spec.inputs[] | select(.team == "$(2)") | .shard' $(DEMO_FLEET_FILE)); \
  printf '\n$$ kubectl apply -f demos/_attach.yaml  (__NAME__=$(1) __TEAM__=$(2) __SHARD__=%s)\n' "$$_shard"; \
  sed -e 's/__NAME__/$(1)/g' -e 's/__TEAM__/$(2)/g' -e "s/__SHARD__/$$_shard/g" -e 's/__REGISTRY__/$(OCI_CLUSTER_URL)/g' demos/_attach.yaml \
    | kubectl apply -f - 2>&1 | sed 's/^/    /'
endef

define demo_detach
  printf '==> cleanup: detaching $(1) from $(2)\n'; \
  kubectl -n $(2) delete kustomization $(1) --ignore-not-found --timeout=120s 2>&1 | sed 's/^/    /'; \
  kubectl -n $(2) delete ocirepository $(1) --ignore-not-found 2>&1 | sed 's/^/    /'
endef

demo-all: demo-guard
	@mkdir -p $(DEMO_OUT_DIR)
	@: > $(DEMO_OUT_DIR)/summary
	@for d in $(DEMOS); do \
	  if $(MAKE) --no-print-directory demo-$$d; then R=PASS; else R=FAIL; fi; \
	  if echo " $(DEMOS_WITH_CLEANUP) " | grep -q " $$d "; then \
	    $(MAKE) --no-print-directory demo-$$d-cleanup || echo "    (cleanup of $$d reported a problem)"; \
	  fi; \
	  printf '  %-22s %s\n' "$$d" "$$R" >> $(DEMO_OUT_DIR)/summary; \
	done; \
	echo ""; \
	echo "=============================================="; \
	echo "==> DEMO SUMMARY"; \
	echo "=============================================="; \
	cat $(DEMO_OUT_DIR)/summary; \
	echo "=============================================="; \
	if grep -q FAIL $(DEMO_OUT_DIR)/summary; then echo "==> demo-all: FAIL"; exit 1; fi; \
	echo "==> demo-all: all $(words $(DEMOS)) demos PASS"

define demo_shard_set
  printf "\n$$ yq -i '(.spec.inputs[] | select(.team == \"$(1)\") | .shard) = \"$(2)\"' %s\n" $(DEMO_FLEET_FILE); \
  yq -i '(.spec.inputs[] | select(.team == "$(1)") | .shard) = "$(2)"' $(DEMO_FLEET_FILE); \
  grep -n -A2 'team: $(1)$$' $(DEMO_FLEET_FILE) | sed 's/^/    /'
endef

define demo_shard_apply
  $(MAKE) --no-print-directory push REPO=fleet 2>&1 | sed 's/^/    /'; \
  flux reconcile kustomization cluster-sync -n flux-system 2>&1 | sed 's/^/    /'
endef

demo-shards: demo-guard
	@$(call demo_begin,shards,a shard is an operational choice and not a team boundary: two controller sets serve four teams and a team can be moved between them); \
	run 'kubectl -n flux-system get deploy -o name | sed "s|deployment.apps/||" | sort'; \
	run 'printf "shard-deploys=%s main-deploys=%s team-named-deploys=%s\n" "$$(kubectl -n flux-system get deploy -o name | grep -c -- "-shard-")" "$$(kubectl -n flux-system get deploy -o name | grep -cE "/(source|kustomize|helm|notification)-controller$$")" "$$(kubectl -n flux-system get deploy -o name | grep -c -- "-team-")"'; \
	run 'kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A -L sharding.fluxcd.io/key'; \
	run 'kubectl get ns -l platform.k8s-base/team -L platform.k8s-base/team,platform.k8s-base/shard'; \
	expect 'shard-deploys=6 main-deploys=4 team-named-deploys=0' 'six sharded controllers, the four platform ones, and not one Deployment named after a team'; \
	expect '^team-a .*[[:space:]]shard-1$$' 'Kustomization team-a is on shard-1'; \
	expect '^team-b .*[[:space:]]shard-1$$' 'Kustomization team-b is on shard-1'; \
	expect '^team-c .*[[:space:]]shard-2$$' 'Kustomization team-c is on shard-2'; \
	expect '^team-d .*[[:space:]]shard-2$$' 'Kustomization team-d is on shard-2'; \
	expect 'team-c-apps +Active +[^ ]+ +team-c +shard-2' 'the namespace carries the shard the VAP reads its expectation from'; \
	section 'who reconciled what'; \
	run 'printf "shard-1-mentions-team-a=%s main-mentions-teams=%s\n" "$$(kubectl -n flux-system logs deploy/kustomize-controller-shard-1 --tail=-1 | grep -c team-a-apps)" "$$(kubectl -n flux-system logs deploy/kustomize-controller --tail=-1 | grep -cE "team-(a|b|c|d)-(apps|batch|analytics)")"'; \
	expect 'shard-1-mentions-team-a=[1-9]' 'kustomize-controller-shard-1 logged the team-a objects'; \
	expect 'main-mentions-teams=0' 'the platform kustomize-controller never mentions a team'; \
	section 'move team-c from shard-2 to shard-1 with one line of fleet input'; \
	$(call demo_shard_set,team-c,shard-1); \
	$(call demo_shard_apply); \
	wait_for 300 'Kustomization team-c to be relabelled sharding.fluxcd.io/key=shard-1' \
	  'kubectl -n team-c get kustomization team-c -L sharding.fluxcd.io/key --no-headers | grep -q shard-1'; \
	run 'kubectl get ns team-c team-c-apps -L platform.k8s-base/shard'; \
	run 'kubectl -n team-c get kustomization,ocirepository -L sharding.fluxcd.io/key'; \
	wait_for 300 'kustomize-controller-shard-1 to log a team-c reconcile' \
	  'kubectl -n flux-system logs deploy/kustomize-controller-shard-1 --tail=-1 | grep -q team-c'; \
	run 'printf "shard-1-mentions-team-c=%s\n" "$$(kubectl -n flux-system logs deploy/kustomize-controller-shard-1 --tail=-1 | grep -c team-c)"'; \
	wait_for 300 'Kustomization team-c to report Ready=True on its new shard' \
	  'cond team-c kustomization team-c Ready | grep -q "^True"'; \
	run 'cond team-c kustomization team-c Ready'; \
	expect 'team-c +Active +[^ ]+ +shard-1' 'the team-c home namespace is relabelled shard-1'; \
	expect 'kustomization.kustomize.toolkit.fluxcd.io/team-c .*shard-1' 'the team-c Kustomization now carries shard-1'; \
	expect 'shard-1-mentions-team-c=[1-9]' 'kustomize-controller-shard-1 picked team-c up after the move'; \
	expect '^True Applied revision' 'team-c is still Ready on its new shard'; \
	section 'and back to shard-2'; \
	$(call demo_shard_set,team-c,shard-2); \
	$(call demo_shard_apply); \
	wait_for 300 'Kustomization team-c to be relabelled sharding.fluxcd.io/key=shard-2' \
	  'kubectl -n team-c get kustomization team-c -L sharding.fluxcd.io/key --no-headers | grep -q shard-2'; \
	run 'kubectl -n team-c get kustomization,ocirepository -L sharding.fluxcd.io/key'; \
	wait_for 300 'Kustomization team-c to report Ready=True back on shard-2' \
	  'cond team-c kustomization team-c Ready | grep -q "^True"'; \
	run 'cond team-c kustomization team-c Ready'; \
	expect 'kustomization.kustomize.toolkit.fluxcd.io/team-c .*shard-2' 'team-c is back on shard-2'; \
	expect '^True Applied revision' 'and still Ready'; \
	finish '6 shard + 4 platform Deployments with no team in a Deployment name, team-a/b on shard-1 and team-c/d on shard-2, then team-c moved to shard-1 and picked up by kustomize-controller-shard-1, then moved back'

demo-shards-cleanup: demo-guard
	@echo "==> cleanup: making sure team-c is back on shard-2 in $(DEMO_FLEET_FILE)"
	@if [ "$$(yq -r '.spec.inputs[] | select(.team == "team-c") | .shard' $(DEMO_FLEET_FILE))" = "shard-2" ]; then \
	  echo "    already shard-2, nothing to do"; \
	else \
	  $(call demo_shard_set,team-c,shard-2); \
	  $(call demo_shard_apply); \
	  i=0; until kubectl -n team-c get kustomization team-c -L sharding.fluxcd.io/key --no-headers | grep -q shard-2; do \
	    i=$$((i+5)); \
	    if [ $$i -ge 300 ]; then echo "    team-c never went back to shard-2"; exit 1; fi; \
	    sleep 5; \
	  done; \
	  echo "    team-c is back on shard-2 after ~$$i s"; \
	fi
	@kubectl -n team-c wait kustomization team-c --for=condition=Ready=True --timeout=300s

demo-misconfig-namespace: demo-guard
	@$(call demo_begin,misconfig-namespace,a team cannot accidentally write outside its namespaces); \
	run 'cat demos/misconfig-namespace/stray-configmap.yaml'; \
	$(call demo_push,team-b-misconfig,demos/misconfig-namespace,team-b); \
	$(call demo_attach,team-b-misconfig,team-b); \
	section 'the team-b shard tries to apply it as system:serviceaccount:team-b:flux'; \
	wait_for 180 'Kustomization team-b/team-b-misconfig to report Ready=False' \
	  'cond team-b kustomization team-b-misconfig Ready | grep -q "^False"'; \
	run 'cond team-b kustomization team-b-misconfig Ready'; \
	run 'kubectl -n team-a-apps get configmap stray'; \
	expect 'Ready=False|^False' 'the Kustomization is not Ready'; \
	expect 'forbidden' 'the apply was rejected as forbidden'; \
	expect 'system:serviceaccount:team-b:flux' 'the rejected identity is team-b s flux ServiceAccount'; \
	expect 'configmaps "stray" not found' 'nothing landed in team-a-apps'; \
	finish 'Kustomization team-b-misconfig Ready=False with configmaps forbidden for system:serviceaccount:team-b:flux and no ConfigMap in team-a-apps, so the mistake stops at team-b s own reconcile'

demo-misconfig-namespace-cleanup: demo-guard
	@$(call demo_detach,team-b-misconfig,team-b)
	@echo "    (the team-b-misconfig:demo artifact is left in the registry; nothing reads it)"

demo-netpol: demo-guard
	@$(call demo_begin,netpol,undeclared cross-team traffic is dropped by Cilium while same-team traffic is not); \
	printf '\n(team-c is the destination: team-a and team-b have declared cross-team access,\n and demo-cross-team-access is the demo that takes it away and puts it back.)\n'; \
	demos/_cilium-settle.sh 60; \
	printf '\n$$ cilium hubble port-forward &\n'; \
	cilium hubble port-forward >$(DEMO_OUT_DIR)/hubble-pf.log 2>&1 & \
	_pf=$$!; sleep 6; \
	run 'kubectl -n team-b-apps exec deploy/podinfo -- curl -m5 -s -o /dev/null -w "same-team-http=%{http_code}\n" http://podinfo.team-b-apps:9898/'; \
	run 'kubectl -n team-b-apps exec deploy/podinfo -- curl -m12 -s -o /dev/null -w "cross-team-http=%{http_code}\n" http://podinfo.team-c-apps:9898/'; \
	sleep 3; \
	run 'hubble observe --verdict DROPPED --to-namespace team-c-apps --last 10'; \
	run 'kubectl -n istio-system logs -l app=ztunnel --tail=-1 --since=3m | grep -F team-c-apps | tail -2'; \
	{ kill $$_pf; wait $$_pf; } 2>/dev/null; \
	expect 'same-team-http=200' 'same-team curl got HTTP 200'; \
	expect 'cross-team-http=000' 'the undeclared cross-team curl got no response'; \
	expect 'exit=56' 'ztunnel gave up on the HBONE handshake after 10s and reset the call (curl exit 56)'; \
	expect 'team-b-apps/podinfo.*team-c-apps/podinfo' 'Hubble recorded the team-b to team-c flow'; \
	expect 'team-c-apps/podinfo[^ ]*:15008' 'the flow Cilium saw was already HBONE on 15008, not the app port 9898'; \
	expect_not 'team-b-apps/podinfo[^ ]*(->|<>) team-c-apps/podinfo[^ ]*:9898' 'no attempt ever reached the plaintext app port'; \
	expect 'EGRESS DENIED' 'the drop is the callers own baseline egress rule, before any HBONE handshake'; \
	expect 'DENIED|DROPPED' 'Hubble reports the policy verdict as denied'; \
	expect 'maybe a NetworkPolicy is blocking HBONE port 15008' 'ztunnel names the same cause from the mesh side'; \
	finish 'HTTP 200 inside team-b, curl exit 56 to the undeclared team-a-apps, a DROPPED EGRESS policy-verdict on port 15008 in hubble observe, and ztunnel reporting a NetworkPolicy blocking HBONE 15008'

demo-netpol-cleanup: demo-guard
	@echo "==> cleanup: stopping any stray hubble port-forward"
	@pkill -f 'cilium hubble port-forward' 2>/dev/null || true
	@pkill -f 'port-forward.*hubble-relay' 2>/dev/null || true
	@echo "    done (nothing in the cluster was changed by demo-netpol)"

# The two ends of a mesh flow have to be two different pods in two different
# namespaces, and team-b is the only team with two workload namespaces. The
# probe arrives as a signed artifact like any other workload; team-a's identity
# is asserted from the ztunnel certificate store instead.
MTLS_SRC_NS   := team-b-batch
MTLS_SRC_POD  := mtls-probe
MTLS_DST_NS   := team-b-apps
MTLS_DST_PORT := 9898

demo-mtls: demo-guard
	@$(call demo_begin,mtls,traffic between pods is HBONE on 15008 with a SPIFFE identity on both ends and never touches the plaintext app port); \
	run 'printf "mesh-mtls=%s\n" "$$(kubectl -n istio-system get peerauthentication default -o jsonpath={.spec.mtls.mode})"'; \
	run 'istioctl ztunnel-config workloads | grep -E "^team-"'; \
	run 'printf "team-pods=%s team-pods-not-hbone=%s team-waypoints=%s\n" "$$(istioctl ztunnel-config workloads | grep "^team-" | grep -cv " waypoint-")" "$$(istioctl ztunnel-config workloads | grep "^team-" | grep -v " waypoint-" | grep -vc HBONE)" "$$(istioctl ztunnel-config workloads | grep "^team-" | grep -c " waypoint-")"'; \
	expect 'mesh-mtls=STRICT' 'PeerAuthentication default in istio-system is STRICT mesh-wide'; \
	expect 'team-pods=[1-9]' 'ztunnel knows the team pods'; \
	expect 'team-pods-not-hbone=0' 'and not one workload pod in a team namespace is left outside the mesh'; \
	expect 'team-waypoints=[1-9]' 'the one pod listed as TCP rather than HBONE is team-a s waypoint, which terminates HBONE instead of speaking it'; \
	section 'a same-team call from team-b-batch into team-b-apps'; \
	demos/_cilium-settle.sh 60; \
	$(call demo_push,team-b-mtls-probe,demos/mtls-probe,team-b); \
	$(call demo_attach,team-b-mtls-probe,team-b); \
	printf '\n$$ cilium hubble port-forward &\n'; \
	cilium hubble port-forward >$(DEMO_OUT_DIR)/hubble-pf.log 2>&1 & \
	_pf=$$!; sleep 6; \
	run 'kubectl -n $(MTLS_SRC_NS) delete job $(MTLS_SRC_POD) --ignore-not-found'; \
	run 'flux -n team-b reconcile kustomization team-b-mtls-probe --with-source'; \
	wait_for 180 'the mtls-probe Job to finish' \
	  'kubectl -n $(MTLS_SRC_NS) get job $(MTLS_SRC_POD) -o jsonpath={.status.succeeded} | grep -q 1'; \
	run 'kubectl -n $(MTLS_SRC_NS) logs job/$(MTLS_SRC_POD)'; \
	run 'kubectl -n $(MTLS_SRC_NS) get pods -o wide -l job-name=$(MTLS_SRC_POD); kubectl -n $(MTLS_DST_NS) get pods -o wide'; \
	expect 'probe=200' 'the same-team call succeeds'; \
	expect_not 'probe=000' 'and not one of the six attempts was refused'; \
	section 'what Cilium saw on the wire'; \
	run 'hubble observe --namespace $(MTLS_SRC_NS) --last 40 | grep -F "/$(MTLS_SRC_POD)"'; \
	{ kill $$_pf; wait $$_pf; } 2>/dev/null; \
	expect '$(MTLS_SRC_NS)/$(MTLS_SRC_POD)[^ ]* .*-> $(MTLS_DST_NS)/podinfo[^ ]*:15008' 'every flow to the callee is addressed to the HBONE port'; \
	expect_not '$(MTLS_SRC_NS)/$(MTLS_SRC_POD)[^ ]* .*(->|<>) $(MTLS_DST_NS)/podinfo[^ ]*:$(MTLS_DST_PORT)' 'not one flow between the two pods on the plaintext app port $(MTLS_DST_PORT)'; \
	section 'who the two ends were, according to ztunnel'; \
	run 'kubectl -n istio-system logs -l app=ztunnel --tail=-1 --since=5m | grep -F "src.workload=\"$(MTLS_SRC_POD)" | tail -1'; \
	expect 'src.identity="spiffe://cluster.local/ns/$(MTLS_SRC_NS)/sa/[^"]+"' 'the caller is named by a SPIFFE identity, not an IP'; \
	expect 'dst.identity="spiffe://cluster.local/ns/$(MTLS_DST_NS)/sa/[^"]+"' 'so is the callee, and it is a different identity'; \
	expect 'dst.hbone_addr=[0-9.]+:$(MTLS_DST_PORT)' 'the app port only exists inside the HBONE tunnel'; \
	section 'the identities ztunnel holds a certificate for'; \
	run 'for n in $$(kubectl get nodes -o name | sed "s|node/||"); do istioctl ztunnel-config certificates --node $$n; done | grep -E "spiffe://cluster.local/ns/team-" | sort -u'; \
	expect 'spiffe://cluster.local/ns/team-a-apps/sa/[a-z-]+ +Leaf +Available +true' 'ztunnel holds a live leaf certificate for the team-a-apps identity'; \
	expect 'spiffe://cluster.local/ns/$(MTLS_DST_NS)/sa/[a-z-]+ +Leaf +Available +true' 'and for the callee identity'; \
	section 'and the probes that have to stay plaintext still arrive'; \
	run 'kubectl -n $(MTLS_DST_NS) get pods --no-headers; kubectl get ccnp allow-ambient-hostprobes -o jsonpath="probe-cidr={.spec.ingress[0].fromCIDR[0]}"; echo'; \
	expect 'podinfo[^ ]* +1/1 +Running' 'the pod whose readiness probe is SNATed to the link-local address is still Ready'; \
	expect 'probe-cidr=169.254.7.127/32' 'and the CCNP that admits that address is in place'; \
	finish 'PeerAuthentication STRICT, every team pod on HBONE, six same-team 200s whose only Cilium-visible port is 15008, two different SPIFFE identities in the ztunnel access log with the app port inside hbone_addr, live leaf certificates for the team identities, and readiness probes still arriving from 169.254.7.127'

demo-mtls-cleanup: demo-guard
	@echo "==> cleanup: stopping any stray hubble port-forward"
	@pkill -f 'cilium hubble port-forward' 2>/dev/null || true
	@pkill -f 'port-forward.*hubble-relay' 2>/dev/null || true
	@$(call demo_detach,team-b-mtls-probe,team-b)
	@kubectl -n $(MTLS_SRC_NS) delete job $(MTLS_SRC_POD) --ignore-not-found 2>&1 | sed 's/^/    /'

DEMO_NS_FULL    := ["apps", "batch"]
DEMO_NS_DROPPED := ["apps"]

define demo_noprune_set
  printf "\n$$ yq -i '(.spec.inputs[] | select(.team == \"team-b\") | .namespaces) = %s' %s\n" '$(1)' $(DEMO_FLEET_FILE); \
  yq -i '(.spec.inputs[] | select(.team == "team-b") | .namespaces) = $(1)' $(DEMO_FLEET_FILE); \
  grep -n -A3 'team: team-b$$' $(DEMO_FLEET_FILE) | sed 's/^/    /'
endef

demo-no-prune: demo-guard
	@$(call demo_begin,no-prune,a team namespace survives removal from the ResourceSet inputs while its platform-owned baseline objects are pruned); \
	run 'kubectl get namespace team-b-batch -L platform.k8s-base/team,platform.k8s-base/role'; \
	run 'kubectl -n team-b-batch get networkpolicy,rolebinding,ocirepository'; \
	section 'drop batch from team-b in the fleet repo, re-push the fleet artifact'; \
	$(call demo_noprune_set,$(DEMO_NS_DROPPED)); \
	run '$(MAKE) --no-print-directory push REPO=fleet'; \
	run 'flux reconcile kustomization cluster-sync -n flux-system'; \
	wait_for 240 'the team-baseline NetworkPolicy in team-b-batch to be pruned' \
	  '! kubectl -n team-b-batch get networkpolicy team-baseline-default-deny'; \
	run 'kubectl get namespace team-b-batch'; \
	run 'kubectl -n team-b-batch get networkpolicy,rolebinding,ocirepository'; \
	run 'kubectl get namespace team-b-batch -o jsonpath={.metadata.annotations}'; \
	expect 'team-b-batch +Active' 'the namespace is still Active'; \
	expect 'No resources found in team-b-batch namespace' 'every platform-owned object in it was pruned'; \
	expect 'fluxcd.controlplane.io/prune.*disabled' 'the namespace carries the annotation that exempts it from pruning'; \
	finish 'namespace team-b-batch still Active, its team-baseline NetworkPolicy, team-admin RoleBinding and catalog chart source gone'

demo-no-prune-cleanup: demo-guard
	@echo "==> cleanup: putting batch back into $(DEMO_FLEET_FILE)"
	@$(call demo_noprune_set,$(DEMO_NS_FULL))
	@$(MAKE) --no-print-directory push REPO=fleet
	@flux reconcile kustomization cluster-sync -n flux-system
	@i=0; until kubectl -n team-b-batch get networkpolicy team-baseline-default-deny >/dev/null 2>&1; do \
	  i=$$((i+5)); \
	  if [ $$i -ge 240 ]; then echo "    team-baseline never came back — ResourceSet 'teams' is not reconciling"; exit 1; fi; \
	  sleep 5; \
	done; \
	echo "    team-baseline is back after ~$$i s"
	@kubectl -n team-b-batch get networkpolicy,rolebinding,ocirepository
	@echo "==> cleanup: team-b lost admin in team-b-batch while the RoleBinding was gone, so re-reconcile it"
	@flux reconcile kustomization team-b -n team-b --with-source 2>&1 | tail -2 || true
	@kubectl -n team-b wait kustomization team-b --for=condition=Ready=True --timeout=180s

define demo_sign_as
  _d=$$(curl -s -o /dev/null -D - -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        http://$(OCI_LOCAL_URL)/v2/$(1)/manifests/$(TAG) \
        | awk 'tolower($$1) == "docker-content-digest:" { print $$2 }' | tr -d '\r'); \
  printf '\n$$ cosign sign --key $(COSIGN_KEYS_DIR)/$(2)/cosign.key $(OCI_LOCAL_URL)/$(1)@%s\n' "$$_d"; \
  COSIGN_PASSWORD= cosign sign --yes --key=$(COSIGN_KEYS_DIR)/$(2)/cosign.key \
    $(COSIGN_HTTP_FLAGS) $(COSIGN_EXTRA_FLAGS) $(OCI_LOCAL_URL)/$(1)@$$_d 2>&1 \
    | sed 's/^/    /'
endef

demo-signature: demo-guard
	@$(call demo_begin,signature,an unsigned or foreign-signed artifact never reaches the cluster); \
	run 'kubectl -n team-c get ocirepository team-c-source -o jsonpath={.spec.verify}'; \
	section 'push team-c with no signature at all'; \
	run '$(MAKE) --no-print-directory push REPO=team-c SIGN=0'; \
	wait_for 180 'OCIRepository team-c-source to report SourceVerified=False' \
	  'cond team-c ocirepository team-c-source SourceVerified | grep -q "^False"'; \
	run 'cond team-c ocirepository team-c-source SourceVerified'; \
	run 'cond team-c ocirepository team-c-source Ready'; \
	expect '^False' 'SourceVerified is False'; \
	expect 'no signatures found|failed to verify|no matching signatures' 'the reason names the missing signature'; \
	section 'sign that exact digest with team-a key instead of team-c key'; \
	$(call demo_sign_as,team-c,team-a); \
	run 'flux reconcile source oci team-c-source -n team-c --timeout=30s'; \
	run 'cond team-c ocirepository team-c-source SourceVerified'; \
	expect '^False' 'SourceVerified is still False with a valid but foreign signature'; \
	expect 'no matching signatures|failed to verify' 'the reason is that no signature matches team-c cosign-pub'; \
	finish 'OCIRepository team-c-source SourceVerified=False first for a missing signature and then for a signature made with team-a key'

demo-signature-cleanup: demo-guard
	@echo "==> cleanup: re-push team-c signed with its own key"
	@$(MAKE) --no-print-directory push REPO=team-c
	@kubectl -n team-c wait ocirepository team-c-source --for=condition=Ready=True --timeout=180s
	@flux reconcile kustomization team-c -n team-c 2>&1 | tail -2 || true
	@kubectl -n team-c wait kustomization team-c --for=condition=Ready=True --timeout=180s

demo-sops: demo-guard
	@$(call demo_begin,sops,a team secret is ciphertext in the repo and plaintext only inside the cluster); \
	run 'cat repos/team-c/.sops.yaml'; \
	run 'grep -n "ENC\[" repos/team-c/apps/podinfo/envs/local/podinfo-config.enc.yaml'; \
	expect 'ENC\[AES256_GCM' 'the value in the repo is ciphertext'; \
	expect 'age1' 'the repo records which age public key it was sealed to'; \
	section 'the same Secret, in the cluster'; \
	run 'kubectl -n team-c-apps get secret podinfo-config -o jsonpath={.data.ui-message} | base64 -d; echo'; \
	expect 'hello from team-c \(decrypted in-cluster\)' 'the in-cluster Secret holds the plaintext'; \
	expect_not 'ENC\[' 'no ciphertext survived into the cluster'; \
	section 'and as the running app sees it'; \
	run 'kubectl -n team-c-apps exec deploy/podinfo -- curl -s -m5 localhost:9898/ | head -c 400; echo'; \
	expect '"message": "hello from team-c \(decrypted in-cluster\)"' 'podinfo serves the decrypted value as its UI message'; \
	finish 'ENC[AES256_GCM...] in repos/team-c, the plaintext in Secret team-c-apps/podinfo-config, and the same string in podinfo s own /  response'

demo-psa: demo-guard
	@$(call demo_begin,psa,a privileged pod is refused by the namespace's restricted PodSecurity level); \
	run 'kubectl get namespace team-a-apps -L pod-security.kubernetes.io/enforce'; \
	run 'grep -E "hostPID|privileged" demos/psa-violation/privileged-deployment.yaml'; \
	$(call demo_push,team-a-psa,demos/psa-violation,team-a); \
	$(call demo_attach,team-a-psa,team-a); \
	section 'the Deployment is admitted; its pods are not'; \
	wait_for 180 'Deployment privileged-oops to report ReplicaFailure' \
	  'cond team-a-apps deployment privileged-oops ReplicaFailure | grep -q violates'; \
	run 'kubectl -n team-a-apps get deploy privileged-oops'; \
	run 'cond team-a-apps deployment privileged-oops ReplicaFailure'; \
	run 'kubectl -n team-a-apps get pods -l app=privileged-oops'; \
	expect 'violates PodSecurity "restricted:latest"' 'the pod was refused by restricted PodSecurity'; \
	expect 'hostPID=true' 'host namespaces were part of the refusal'; \
	expect 'must not set securityContext.privileged=true' 'privileged was part of the refusal'; \
	expect 'No resources found' 'not one pod was created'; \
	finish 'Deployment privileged-oops created but ReplicaFailure citing violates PodSecurity restricted:latest and zero pods'

demo-psa-cleanup: demo-guard
	@$(call demo_detach,team-a-psa,team-a)
	@kubectl -n team-a-apps get deploy privileged-oops 2>&1 | sed 's/^/    /'

demo-vap: demo-guard
	@$(call demo_begin,vap,the API server itself denies off-shard Flux objects, baseline tampering and unknown registries); \
	run 'kubectl get validatingadmissionpolicy -o custom-columns=NAME:.metadata.name,FAILUREPOLICY:.spec.failurePolicy'; \
	section 'team-shard-label: team-a parks a HelmRelease on the other shard'; \
	run 'kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps apply -f demos/vap/wrong-shard-helmrelease.yaml'; \
	expect 'team-shard-label' 'the denial names the policy'; \
	expect 'sharding.fluxcd.io/key=shard-1 but has "shard-2"' 'the message says which shard was expected'; \
	section 'team-baseline-lock: the team deletes its own baseline NetworkPolicy'; \
	run 'kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps delete networkpolicy team-baseline-default-deny'; \
	expect 'team-baseline-\* objects are platform-owned' 'the denial explains the ownership rule'; \
	expect 'system:serviceaccount:team-a:flux may not DELETE' 'the denial names the identity and the verb'; \
	run 'kubectl -n team-a-apps get networkpolicy team-baseline-default-deny'; \
	expect 'team-baseline-default-deny' 'the NetworkPolicy is still there'; \
	section 'allowed-registries: an image from a registry nobody allow-listed'; \
	run 'kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps create -f demos/vap/bad-registry-pod.yaml'; \
	expect 'image registry not in the platform allow-list' 'the denial explains the allow-list'; \
	section 'the regression guard: a correct team object must still be admitted'; \
	run 'kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps apply --dry-run=server -f demos/vap/ok-kustomization.yaml'; \
	expect 'server dry run' 'a correctly sharded, correctly impersonating Kustomization is accepted'; \
	expect_not 'denied' 'no policy fired on the legitimate object'; \
	finish 'three API-server denials naming team-shard-label, team-baseline-lock and allowed-registries, and one accepted dry-run'

# Every public hostname resolves to 127.0.0.1 through the k3d loadbalancer port
# mapping; --resolve keeps the demo working without an /etc/hosts entry.
PUBLIC_HOST  := api.local-dev.test
PUBLIC_PORT  := 8443
CA_BUNDLE     = $(KEYS_DIR)/platform/ca.crt
edge_curl     = curl -sS --cacert $(CA_BUNDLE) --resolve $(PUBLIC_HOST):$(PUBLIC_PORT):127.0.0.1 $(1) https://$(PUBLIC_HOST):$(PUBLIC_PORT)$(2)

PARTNER_ZONE  = partners.$(CLUSTER_DOMAIN)
PARTNER_PORT := 9443
PARTNER_KEY_DIR = $(KEYS_DIR)/partner-api
partner_curl  = curl -sS --cacert $(CA_BUNDLE) --resolve $(1).$(PARTNER_ZONE):$(PARTNER_PORT):127.0.0.1 $(2) https://$(1).$(PARTNER_ZONE):$(PARTNER_PORT)$(3)

demo-cross-team-access: demo-guard
	@$(call demo_begin,cross-team-access,a cross-team call needs both halves in git and is bound to one workload identity on one route); \
	run 'cat repos/team-a/apps/podinfo/base/allow/team-b-podinfo.yaml'; \
	run 'cat repos/team-b/apps/orders/base/depends-on/team-a-podinfo.yaml'; \
	run 'kubectl -n team-a-apps get networkpolicy,authorizationpolicy'; \
	run 'kubectl -n team-b-apps get networkpolicy'; \
	run 'kubectl -n team-b-apps get serviceaccount orders'; \
	run 'kubectl -n team-a-apps get service podinfo -o jsonpath={.metadata.labels}; echo'; \
	run 'kubectl -n team-a-apps get gateway waypoint'; \
	expect 'networkpolicy.networking.k8s.io/allow-team-b-podinfo' 'the owning team ships the NetworkPolicy half'; \
	expect 'authorizationpolicy.security.istio.io/allow-team-b-podinfo' 'and the AuthorizationPolicy half, in the same file'; \
	expect 'depends-on-team-a-podinfo' 'the calling team ships its own egress half'; \
	expect '^orders ' 'the named calling identity exists'; \
	expect 'port: 15008' 'both halves are written against the ambient mesh port, never the service port'; \
	expect 'istio.io/use-waypoint.*waypoint' 'Service podinfo is bound to team-a s waypoint, without which the rule is inert and every path returns 200'; \
	expect 'istio-waypoint .* True' 'the waypoint Gateway is Programmed, under PSA restricted'; \
	section 'take both halves away'; \
	run 'flux -n team-a suspend kustomization team-a'; \
	run 'flux -n team-b suspend kustomization team-b'; \
	run 'kubectl -n team-a-apps delete networkpolicy allow-team-b-podinfo'; \
	run 'kubectl -n team-a-apps delete authorizationpolicy allow-team-b-podinfo'; \
	run 'kubectl -n team-b-apps delete networkpolicy depends-on-team-a-podinfo'; \
	demos/_cilium-settle.sh 60; \
	printf '\n$$ cilium hubble port-forward &\n'; \
	cilium hubble port-forward >$(DEMO_OUT_DIR)/hubble-pf.log 2>&1 & \
	_pf=$$!; sleep 6; \
	run 'kubectl -n team-b-apps exec deploy/caller -- curl -m12 -sS -o /dev/null -w "no-allow=%{http_code}\n" http://podinfo.team-a-apps:9898/api/info'; \
	sleep 3; \
	run 'hubble observe --verdict DROPPED --from-namespace team-b-apps --to-namespace team-a-apps --last 5'; \
	expect 'no-allow=000' 'without the allow the call gets no response at all'; \
	expect 'exit=(28|56)' 'the call never completes: the caller times out or ztunnel resets it'; \
	expect 'team-b-apps/caller.*team-a-apps/[^ ]*:15008' 'Hubble recorded the flow, already HBONE on 15008'; \
	expect 'EGRESS DENIED' 'Cilium denied it before any identity was checked'; \
	section 'put both halves back'; \
	run 'flux -n team-a resume kustomization team-a'; \
	run 'flux -n team-b resume kustomization team-b'; \
	run 'flux -n team-a reconcile kustomization team-a --with-source'; \
	run 'flux -n team-b reconcile kustomization team-b --with-source'; \
	wait_for 180 'the owning AuthorizationPolicy to come back' \
	  'kubectl -n team-a-apps get authorizationpolicy allow-team-b-podinfo'; \
	wait_for 180 'the calling NetworkPolicy to come back' \
	  'kubectl -n team-b-apps get networkpolicy depends-on-team-a-podinfo'; \
	demos/_cilium-settle.sh 60; \
	run 'kubectl -n team-b-apps exec deploy/caller -- curl -m12 -s -o /dev/null -w "allowed=%{http_code}\n" http://podinfo.team-a-apps:9898/api/info'; \
	sleep 3; \
	run 'hubble observe --from-namespace team-b-apps --to-namespace team-a-apps --last 5'; \
	run 'printf "ztunnel-knows-the-rule=%s\n" "$$(istioctl ztunnel-config policies -o json | grep -c allow-team-b-podinfo)"'; \
	{ kill $$_pf; wait $$_pf; } 2>/dev/null; \
	expect 'allowed=200' 'with both halves in place the declared call returns 200'; \
	expect ':15008' 'Hubble only ever sees the HBONE tunnel, never port 9898'; \
	expect_not 'team-b-apps/caller[^ ]* (->|<>) team-a-apps/[^ ]*:9898' 'nothing ever reached the plaintext app port'; \
	section 'the same identity, a route the owning team did not allow'; \
	run 'kubectl -n team-b-apps exec deploy/caller -- curl -m12 -s -X POST -d hello -w " | POST-api-echo=%{http_code}\n" http://podinfo.team-a-apps:9898/api/echo'; \
	expect 'POST-api-echo=403' 'POST /api/echo is refused with 403 on a real podinfo endpoint, so it is the rule and not a 404'; \
	expect 'RBAC: access denied' 'the waypoint parsed the request and answered it itself'; \
	section 'the same namespace, the wrong identity'; \
	run 'kubectl -n team-b-apps exec deploy/caller-other -- curl -m12 -sS -w " | wrong-identity=%{http_code}\n" http://podinfo.team-a-apps:9898/api/info'; \
	expect_not 'wrong-identity=200' 'the default ServiceAccount is not let through'; \
	expect 'wrong-identity=403' 'it is refused with 403 on identity, on the route that is allowed for orders'; \
	section 'and the owning team is not narrowed by a rule it wrote for someone else'; \
	run 'kubectl -n team-a-apps exec deploy/podinfo -- curl -m12 -s -o /dev/null -w "same-team-POST=%{http_code}\n" -X POST -d hi http://podinfo.team-a-apps:9898/api/echo'; \
	run 'kubectl -n team-a-apps get authorizationpolicy team-baseline-waypoint-allow-same-team -o jsonpath={.spec.targetRefs}; echo'; \
	expect 'same-team-POST=2' 'team-a keeps full access to its own service (podinfo answers 202 to POST /api/echo)'; \
	expect '"kind":"Gateway"' 'because the platform stamps a second baseline scoped to the waypoint Gateway, not to one Service'; \
	finish 'no response and a Cilium EGRESS DENIED on 15008 without the allow, 200 on GET /api/info with it, 403 RBAC: access denied for POST /api/echo and for the wrong ServiceAccount, and team-a s own POST still 202'

demo-cross-team-access-cleanup: demo-guard
	@echo "==> cleanup: resuming both team Kustomizations and reconciling the allow back"
	@flux -n team-a resume kustomization team-a 2>&1 | sed 's/^/    /' || true
	@flux -n team-b resume kustomization team-b 2>&1 | sed 's/^/    /' || true
	@flux -n team-a reconcile kustomization team-a --with-source 2>&1 | tail -2 || true
	@flux -n team-b reconcile kustomization team-b --with-source 2>&1 | tail -2 || true
	@kubectl -n team-a wait kustomization team-a --for=condition=Ready=True --timeout=180s
	@kubectl -n team-b wait kustomization team-b --for=condition=Ready=True --timeout=180s
	@kubectl -n team-a-apps get networkpolicy,authorizationpolicy
	@kubectl -n team-b-apps get networkpolicy
	@pkill -f 'cilium hubble port-forward' 2>/dev/null || true

demo-egress: demo-guard
	@$(call demo_begin,egress,outbound traffic leaves only through the platform egress waypoint and only to hosts team-sec-ops allow-listed); \
	run 'cond platform-egress gateway.gateway.networking.k8s.io egress-waypoint Programmed'; \
	run 'kubectl -n egress-allowlist get serviceentry,authorizationpolicy'; \
	run 'kubectl -n egress-allowlist get serviceentry api-github-com -o jsonpath={.metadata.labels}; echo'; \
	run 'istioctl ztunnel-config services | grep -E "api.github.com|httpbin.org"'; \
	expect 'True Resource programmed' 'the egress waypoint is Programmed'; \
	expect 'use-waypoint-namespace.*platform-egress' 'the ServiceEntry carries the cross-namespace waypoint label'; \
	expect 'api.github.com +240\.240\.' 'ztunnel hands the pod an auto-allocated VIP for the allow-listed host'; \
	expect 'egress-waypoint' 'and names the platform waypoint as its destination'; \
	section 'the three verdicts, from a job in team-b-batch'; \
	demos/_cilium-settle.sh 60; \
	printf '\n$$ cilium hubble port-forward &\n'; \
	cilium hubble port-forward >$(DEMO_OUT_DIR)/hubble-pf.log 2>&1 & \
	_pf=$$!; sleep 6; \
	run 'kubectl -n team-b-batch delete job egress-probe --ignore-not-found'; \
	run 'flux -n team-b reconcile kustomization team-b --with-source'; \
	run 'kubectl -n team-b-batch wait --for=condition=Complete job/egress-probe --timeout=180s'; \
	run 'kubectl -n team-b-batch logs job/egress-probe'; \
	sleep 3; \
	run 'hubble observe --verdict DROPPED --from-namespace team-b-batch --last 20'; \
	run 'hubble observe --from-namespace team-b-batch --to-namespace platform-egress --last 5'; \
	{ kill $$_pf; wait $$_pf; } 2>/dev/null; \
	expect 'probe github=200' 'api.github.com returned 200 through the waypoint'; \
	expect '    body:' 'a real response body came back, so the TLS passthrough is a real round trip'; \
	expect 'probe example=000' 'example.com, which nobody allow-listed, got no response'; \
	expect 'probe directip=000' 'and neither did a hard-coded IP'; \
	expect '93.184.215.14.*(DENIED|DROPPED)' 'the direct-IP attempt is a Cilium policy drop'; \
	expect 'platform-egress/egress-waypoint[^ ]*:15008' 'the allowed call went to the waypoint over HBONE on 15008'; \
	section 'who may use which host is the allow-list owner s decision'; \
	run 'kubectl -n team-a-apps exec deploy/podinfo -- curl -m12 -sS -o /dev/null -w "team-a-github=%{http_code}\n" https://api.github.com/zen'; \
	run 'kubectl -n team-a-apps exec deploy/podinfo -- curl -m12 -s -o /dev/null -w "team-a-httpbin=%{http_code}\n" https://httpbin.org/get'; \
	run 'kubectl -n platform-egress logs -l gateway.networking.k8s.io/gateway-name=egress-waypoint --tail=200 | grep -F caller= | tail -4'; \
	run 'printf "waypoint-rbac-denied=%s\n" "$$(kubectl -n platform-egress exec deploy/egress-waypoint -c istio-proxy -- pilot-agent request GET stats 2>/dev/null | awk -F": " "/^tcp.rbac.denied/{print \$$2}")"'; \
	expect 'team-a-github=000' 'api.github.com is listed but not granted to team-a, so team-a is refused'; \
	expect 'team-a-httpbin=200' 'httpbin.org, which team-a is granted, works from the same pod'; \
	expect 'caller=spiffe://cluster.local/ns/team-b-batch/sa/default' 'the waypoint access log names the calling workload identity'; \
	expect 'sni=api.github.com' 'and the host it asked for, by SNI, without ever decrypting it'; \
	expect 'waypoint-rbac-denied=[1-9]' 'the refusal for team-a is an authorization denial counted by the waypoint'; \
	finish 'github=200 with a body through the waypoint, example.com and a raw IP dropped by Cilium, api.github.com refused for the team that is not granted it, and a waypoint access log naming ns/team-b-batch/sa/default and the SNI host'

demo-egress-cleanup: demo-guard
	@echo "==> cleanup: removing the egress probe job"
	@kubectl -n team-b-batch delete job egress-probe --ignore-not-found 2>&1 | sed 's/^/    /'
	@pkill -f 'cilium hubble port-forward' 2>/dev/null || true

demo-partner-egress: demo-guard
	@$(call demo_begin,partner-egress,a team workload calls a partner over plain HTTP and the egress waypoint holds the certificate the partner demands); \
	run 'docker ps --filter name=$(PARTNER_BANK_NAME) --format "{{.Names}} {{.Status}} {{.Networks}}"'; \
	run 'kubectl -n platform-egress get secret partner-bank-client'; \
	run 'kubectl -n platform-egress get secret partner-bank-client -o json | jq -r ".type, (.data | keys | join(\",\"))"'; \
	run 'kubectl -n egress-allowlist get serviceentry,destinationrule,authorizationpolicy api-partner-bank-test'; \
	run 'kubectl -n egress-allowlist get destinationrule api-partner-bank-test -o jsonpath={.spec.trafficPolicy.tls}; echo'; \
	run 'kubectl -n egress-allowlist get authorizationpolicy api-partner-bank-test -o jsonpath={.spec.rules}; echo'; \
	run 'istioctl proxy-config secret deploy/egress-waypoint -n platform-egress | grep -E "RESOURCE|partner-bank-client"'; \
	run 'istioctl ztunnel-config services | grep api.partner-bank.test'; \
	expect '$(PARTNER_BANK_NAME) +Up' 'the partner bank runs outside the cluster, on the k3d Docker network'; \
	expect 'kubernetes.io/tls' 'the client credential is a TLS Secret'; \
	expect 'ca.crt,tls.crt,tls.key' 'with the three keys Istio SDS reads for mode MUTUAL'; \
	expect 'serviceentry.networking.istio.io/api-partner-bank-test' 'sec-ops listed the host'; \
	expect 'destinationrule.networking.istio.io/api-partner-bank-test' 'and the rule that makes the waypoint originate the TLS'; \
	expect '"credentialName":"partner-bank-client"' 'naming a credential that exists only in platform-egress'; \
	expect '"mode":"MUTUAL"' 'as mutual TLS, not simple'; \
	expect '"paths":\["/transfers"\]' 'the grant is a path, which only a plaintext hop can enforce'; \
	expect 'sa/payments' 'for one ServiceAccount principal'; \
	expect 'kubernetes://partner-bank-client +Cert Chain +ACTIVE' 'the waypoint loaded the client certificate through SDS'; \
	expect 'api.partner-bank.test' 'ztunnel hands the pod a service for the host'; \
	expect 'egress-waypoint' 'and names the platform waypoint as its destination'; \
	section 'the three verdicts, from a job running as sa/payments in team-b-batch'; \
	demos/_cilium-settle.sh 60; \
	run 'kubectl -n team-b-batch delete job partner-probe --ignore-not-found'; \
	run 'flux -n team-b reconcile kustomization team-b --with-source'; \
	run 'kubectl -n team-b-batch wait --for=condition=Complete job/partner-probe --timeout=180s'; \
	run 'kubectl -n team-b-batch logs job/partner-probe'; \
	expect 'probe transfers=200' 'POST /transfers is accepted through the waypoint'; \
	expect 'body: .*"status":"accepted"' 'with the partner s real response body, so the mTLS handshake happened'; \
	expect '"client":"CN=k8s-base-egress"' 'and the partner saw the platform s client certificate, which the team never held'; \
	expect 'probe get=403' 'GET on the same path is refused by the waypoint, on method'; \
	expect 'probe direct443=000' 'and port 443 is not on the ServiceEntry, so it has no waypoint and dies on the team baseline'; \
	section 'the grant is one principal, not one namespace'; \
	run 'kubectl -n team-a-apps exec deploy/podinfo -- curl -m12 -sS -o /dev/null -w "team-a-transfers=%{http_code}\n" -X POST -d "{}" http://api.partner-bank.test/transfers'; \
	expect 'team-a-transfers=403' 'team-a is refused on identity although the host is on the list'; \
	section 'what the audit trail says'; \
	run 'kubectl -n platform-egress logs -l gateway.networking.k8s.io/gateway-name=egress-waypoint --tail=200 | grep -F partner-bank | tail -5'; \
	expect 'caller=spiffe://cluster\.local/ns/team-b-batch/sa/payments' 'the waypoint access log names the calling identity'; \
	expect 'method=POST path=/transfers' 'and, because this entry is HTTP at the waypoint, the method and the path a TLS passthrough entry can never show'; \
	run 'docker logs --tail=20 $(PARTNER_BANK_NAME)'; \
	expect 'client="CN=k8s-base-egress" verify=SUCCESS' 'the partner s own log agrees on who called'; \
	expect_not '"GET /transfers' 'the refused GET never reached the partner at all'; \
	section 'and the credential is nowhere a team can reach it'; \
	run 'docker run --rm --network $(PARTNER_NETWORK) $(PARTNER_CURL_IMAGE) -sk -o /dev/null -w "no-client-cert=%{http_code}\n" -X POST https://$(PARTNER_BANK_IP)/transfers'; \
	run 'kubectl -n team-b-batch get secret'; \
	run 'kubectl -n team-b-batch get serviceaccount payments'; \
	expect 'no-client-cert=400' 'the partner refuses a caller with no certificate during the handshake, before any path is read'; \
	expect_not 'kubernetes.io/tls' 'and there is no TLS Secret anywhere in the team namespace to present'; \
	expect '^payments ' 'the team owns only the identity the grant is written against'; \
	finish 'transfers=200 with the partner s body naming CN=k8s-base-egress, get=403 and direct443=000, 403 for team-a, a waypoint log line with sa/payments POST /transfers, 400 for a caller with no certificate, and no TLS Secret in team-b-batch'

demo-partner-egress-cleanup: demo-guard
	@echo "==> cleanup: removing the partner probe job"
	@kubectl -n team-b-batch delete job partner-probe --ignore-not-found 2>&1 | sed 's/^/    /'

demo-exposure: demo-guard
	@$(call demo_begin,exposure,one public host with one path prefix per team: exposure takes the platform the sec-ops team and the owning team and no one can shortcut it); \
	run 'kubectl get gatewayclass istio -o jsonpath={.status.conditions[0].type}={.status.conditions[0].status}; echo'; \
	run 'cond "" clusterissuer local-ca Ready'; \
	run 'cond platform-ingress gateway.gateway.networking.k8s.io public Programmed'; \
	run 'kubectl get ns -L platform.k8s-base/role | grep -E "NAME|public-api|egress-allowlist"'; \
	run 'kubectl -n platform-ingress get svc -l gateway.networking.k8s.io/gateway-name=public'; \
	run 'kubectl -n flux-system get cm -l platform.k8s-base/registry=api-paths -o jsonpath="{range .items[*]}{.data.team}={.data.paths}{\"\n\"}{end}"'; \
	run 'kubectl -n public-api get httproute -L platform.k8s-base/owner-team,platform.k8s-base/auth'; \
	expect 'Accepted=True' 'the istio GatewayClass is Accepted: the control plane that runs the waypoints renders the doors too'; \
	expect 'True ' 'the local CA ClusterIssuer is Ready'; \
	expect 'public-api .* public-edge' 'public-edge is stamped on public-api'; \
	expect_not 'egress-allowlist .* public-edge' 'and on nothing else'; \
	expect 'LoadBalancer' 'the public Gateway Service is a LoadBalancer with an address from servicelb'; \
	expect 'team-a=podinfo,catalog' 'the fleet repo allocated the prefixes /podinfo and /catalog to team-a'; \
	expect 'team-b=orders' 'and /orders to team-b'; \
	expect 'team-a-podinfo .* team-a +none' 'the open route declares auth=none'; \
	expect 'team-b-orders .* team-b +jwt' 'and team-b s orders route declares auth=jwt'; \
	section 'one host, one prefix per team, over TLS the laptop CA trusts'; \
	run '$(call edge_curl,-o $(DEMO_OUT_DIR)/edge-body -w "podinfo=%{http_code}\n",/podinfo/api/info)'; \
	run 'head -c 160 $(DEMO_OUT_DIR)/edge-body; echo'; \
	run '$(call edge_curl,-o /dev/null -w "orders=%{http_code}\n",/orders/api/info)'; \
	run '$(call edge_curl,-o /dev/null -w "catalog=%{http_code}\n",/catalog/api/info)'; \
	run '$(call edge_curl,-o /dev/null -w "unallocated=%{http_code}\n",/nothing/)'; \
	run '$(call edge_curl,-D - -o /dev/null,/podinfo/api/info) | grep -iE "^HTTP|strict-transport|x-content-type|x-frame|referrer-policy|x-ratelimit"'; \
	expect 'podinfo=200' '200 on api.local-dev.test/podinfo, with the local CA verified by curl'; \
	expect '"hostname": "podinfo' 'and the real podinfo payload, so the URLRewrite handed /api/info to the backend'; \
	expect 'orders=403' 'team-b s /orders prefix is routed from the same host by its own route -- a 403 from the sec-ops require-jwt policy and not a 404 is the proof that longest-prefix selection works across separate HTTPRoutes'; \
	expect 'catalog=403' 'and so is team-a s second prefix /catalog; both are secured, so demo-public-auth is where they return 200'; \
	expect 'unallocated=403' 'a prefix nobody was allocated is a 403, not a 404: the door is closed by default, and the gateway does not even say whether a route exists there'; \
	expect 'strict-transport-security' 'the sec-ops security headers survive next to the URLRewrite filter'; \
	expect 'x-ratelimit-limit' 'and so do the sec-ops rate-limit headers'; \
	section 'the rate limit is the sec-ops floor and no team can raise it'; \
	run 'codes=$$(for i in $$(seq 1 70); do $(call edge_curl,-o /dev/null -w "%{http_code} ",/podinfo/); done); echo "$$codes"; printf "ok=%s limited=%s\n" "$$(echo $$codes | tr " " "\n" | grep -c 200)" "$$(echo $$codes | tr " " "\n" | grep -c 429)"'; \
	expect '429' 'the budget runs out and the edge starts answering 429'; \
	expect 'limited=[1-9]' 'and keeps answering 429 for the rest of the minute'; \
	expect 'ok=[2-9][0-9] ' 'more than the nominal 20 got through, and that is the design: sourceCIDR Distinct buckets per client IP, and servicelb presents one source per node, so the floor is 20 per node rather than 20 per edge'; \
	section 'a team cannot ship its own public route'; \
	run '$(MAKE) --no-print-directory push REPO=team-sec-ops SIGN_AS=team-a'; \
	wait_for 120 'the sec-ops source to reject the foreign signature' \
	  'kubectl -n team-sec-ops get ocirepository team-sec-ops-source -o jsonpath={.status.conditions} | grep -q "no matching signatures"'; \
	run 'cond team-sec-ops ocirepository team-sec-ops-source SourceVerified'; \
	expect 'False .*no matching signatures' 'the sec-ops artifact signed with team-a s key fails verification: the signature is the approval'; \
	run '$(MAKE) --no-print-directory push REPO=team-sec-ops'; \
	wait_for 120 'the sec-ops source to verify again' \
	  'kubectl -n team-sec-ops get ocirepository team-sec-ops-source -o jsonpath={.status.conditions} | grep -q "SourceVerified.*True\|verified signature"'; \
	section 'and the owning team holds a veto'; \
	run 'kubectl -n team-a-apps delete referencegrant allow-public-api'; \
	wait_for 90 'the route to stop resolving' \
	  'kubectl -n public-api get httproute team-a-podinfo -o jsonpath="{.status.parents[0].conditions[?(@.type==\"ResolvedRefs\")].status}" | grep -qx False'; \
	wait_for 60 'the proxy to drop the backend (istiod writes the status a few seconds before it pushes the route)' \
	  '$(call edge_curl,-o /dev/null -w "%{http_code}",/podinfo/api/info) | grep -qx 500'; \
	run '$(call edge_curl,-o /dev/null -w "no-consent=%{http_code}\n",/podinfo/api/info)'; \
	expect 'no-consent=500' 'pulling the ReferenceGrant takes the prefix offline with a 500, not a network drop'; \
	run 'flux -n team-a reconcile kustomization team-a --with-source'; \
	wait_for 90 'the route to resolve again' \
	  'kubectl -n public-api get httproute team-a-podinfo -o jsonpath="{.status.parents[0].conditions[?(@.type==\"ResolvedRefs\")].status}" | grep -qx True'; \
	section 'no shortcuts, at admission'; \
	run 'kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps apply -f demos/exposure/lb-service.yaml'; \
	run 'sed s/__DOMAIN__/$(CLUSTER_DOMAIN)/g demos/exposure/public-parentref-route.yaml | kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps apply -f -'; \
	run 'sed s/__DOMAIN__/$(CLUSTER_DOMAIN)/g demos/exposure/foreign-backend-route.yaml | kubectl --as=system:serviceaccount:team-sec-ops:flux -n public-api apply -f -'; \
	run 'sed s/__DOMAIN__/$(CLUSTER_DOMAIN)/g demos/exposure/platform-backend-route.yaml | kubectl --as=system:serviceaccount:team-sec-ops:flux -n public-api apply -f -'; \
	run 'sed s/__DOMAIN__/$(CLUSTER_DOMAIN)/g demos/exposure/no-auth-label-route.yaml | kubectl --as=system:serviceaccount:team-sec-ops:flux -n public-api apply -f -'; \
	run 'sed s/__DOMAIN__/$(CLUSTER_DOMAIN)/g demos/exposure/wrong-prefix-route.yaml | kubectl --as=system:serviceaccount:team-sec-ops:flux -n public-api apply -f -'; \
	run 'sed s/__DOMAIN__/$(CLUSTER_DOMAIN)/g demos/exposure/api-key-on-public.yaml | kubectl --as=system:serviceaccount:team-sec-ops:flux -n public-api apply -f -'; \
	expect 'may not have type LoadBalancer' 'team-no-direct-exposure refuses a team LoadBalancer'; \
	expect 'attaches to a Gateway this namespace does not own' 'team-no-direct-exposure refuses a team route aimed at the public Gateway'; \
	expect 'owner-team=team-a but a backendRef points elsewhere' 'public-route-owner refuses a public route into another team s Service'; \
	expect 'owner-team=platform but a backendRef points elsewhere' 'public-route-owner refuses a public route into a platform namespace'; \
	expect 'must carry the label platform.k8s-base/auth' 'public-route-owner refuses a public route that does not say whether it is open or secured'; \
	expect 'team-a-claims-orders is labelled .*teams.yaml apiPaths' 'api-path-owner refuses a team-a route claiming team-b s /orders prefix'; \
	expect 'The public edge serves none and jwt' 'public-route-owner refuses an api-key route on the public edge: that class belongs to the partner edge'; \
	finish '200 with the real payload and the sec-ops headers on api.local-dev.test/podinfo, every team prefix routed from the one host with the two secured ones answering 403 without a token and an unallocated prefix a 403 too, 429 after the budget, SourceVerified=False for a sec-ops artifact signed by a team, 500 once the ReferenceGrant is pulled, and seven admission denials'

demo-exposure-cleanup: demo-guard
	@echo "==> cleanup: restoring team-a's ReferenceGrant and the sec-ops artifact"
	@$(MAKE) --no-print-directory push REPO=team-sec-ops 2>&1 | tail -1
	@flux -n team-a reconcile kustomization team-a --with-source 2>&1 | tail -1 || true
	@kubectl -n team-a wait kustomization team-a --for=condition=Ready=True --timeout=180s 2>&1 | sed 's/^/    /'
	@kubectl -n team-a-apps get referencegrant allow-public-api 2>&1 | sed 's/^/    /'

demo-public-auth: demo-guard
	@$(call demo_begin,public-auth,a secured prefix takes a Dex token minted for the public API and an open prefix takes none); \
	section 'the edge policies attach to the public Gateway, in its namespace, applied by the sec-ops identity'; \
	run 'kubectl -n platform-ingress get requestauthentication,authorizationpolicy,envoyfilter -l platform.k8s-base/team=team-sec-ops'; \
	run 'kubectl -n platform-ingress get authorizationpolicy public-edge-require-jwt -o jsonpath="{.spec.action} {.spec.rules[0].to[0].operation.notPaths}"; echo'; \
	run 'kubectl -n public-api get httproute -L platform.k8s-base/auth'; \
	expect 'public-edge-jwt' 'the RequestAuthentication that validates Dex tokens is on the Gateway'; \
	expect 'public-edge-require-jwt' 'and so is the DENY policy that demands one'; \
	expect 'public-edge-ratelimit' 'and the rate limit, all three carrying the sec-ops team label Flux stamps on what that identity applies'; \
	expect 'DENY \["/podinfo","/podinfo/\*"\]' 'the open prefix is the one listed in notPaths; every other prefix on the host is closed the moment it is merged'; \
	section 'the secured prefix is closed to anyone without a token'; \
	run '$(call edge_curl,-o /dev/null -w "no-token=%{http_code}\n",/orders/api/info)'; \
	run '$(call edge_curl,-o /dev/null -w "garbage-token=%{http_code}\n" -H "Authorization: Bearer not-a-jwt",/orders/api/info)'; \
	expect 'no-token=403' 'no Authorization header is a 403 from the require-jwt policy at the edge, and the backend never sees the request'; \
	expect 'garbage-token=401' 'and an unverifiable token is a 401 from the JWT filter itself: no credential is refused by authorization, a bad one by authentication'; \
	section 'a cluster-login token is not an API credential: the audience is the fence'; \
	KUBE_TOKEN=$$(curl -sS --cacert $(CA_BUNDLE) --resolve $(DEX_HOST):$(DEX_PORT):127.0.0.1 \
	  -u $(DEX_CLIENT_ID):$$(cat $(DEX_CLIENT_FILE)) \
	  -d grant_type=password -d username=carol@team-b.local -d password=carol$(DEMO_PW_SUFFIX) \
	  -d scope='openid email groups' $(DEX_ISSUER)/token | jq -r .id_token); \
	run 'printf "%s" "$$KUBE_TOKEN" | cut -d. -f2 | tr "_-" "/+" | jq -Rr "@base64d" | jq -c "{aud, email}"'; \
	run '$(call edge_curl,-o /dev/null -w "kube-token=%{http_code}\n" -H "Authorization: Bearer $$KUBE_TOKEN",/orders/api/info)'; \
	run '$(call edge_curl,-D - -o /dev/null -H "Authorization: Bearer $$KUBE_TOKEN",/orders/api/info) | grep -iE "^HTTP|www-authenticate"'; \
	expect '"aud":"kubernetes"' 'the same password grant against the kubernetes client mints a token for the cluster, not for the API'; \
	expect 'kube-token=403' 'carol s own kubelogin token is refused: Dex signed it and the edge verified the signature, but for aud kubernetes; a verified credential at the wrong door is a 403 from the JWT filter, told apart from the no-token 403 by its www-authenticate header'; \
	expect 'error="invalid_token"' 'and the edge says so in www-authenticate, so the audience is demonstrably the fence'; \
	section 'a token minted for the public API opens it, and the backend learns who called'; \
	TOKEN=$$($(MAKE) -s --no-print-directory api-token USER=carol@team-b.local PASS=carol$(DEMO_PW_SUFFIX)); \
	run 'printf "%s" "$$TOKEN" | cut -d. -f2 | tr "_-" "/+" | jq -Rr "@base64d" | jq -c "{aud, email, groups}"'; \
	run '$(call edge_curl,-o /dev/null -w "api-token=%{http_code}\n" -H "Authorization: Bearer $$TOKEN",/orders/api/info)'; \
	run '$(call edge_curl,-H "Authorization: Bearer $$TOKEN",/orders/headers) | tr -d " \n" | tr "A-Z" "a-z"; echo'; \
	expect '"aud":"public-api"' 'the password grant against the public-api client mints a token for that audience'; \
	expect 'api-token=200' 'and the same request that was a 403 is now a 200'; \
	expect 'x-user-email.{0,8}carol@team-b.local' 'the email claim reached the backend as x-user-email, so the API knows its caller without parsing a token'; \
	expect '"groups":null' 'and no x-user-groups, because Dex s local connector emits no groups claim for a static password: the outputClaimToHeaders entry is correct the day a real connector does, and a missing claim is an omitted header rather than a 401'; \
	section 'the open prefix is still open, CORS and all'; \
	run '$(call edge_curl,-o /dev/null -w "podinfo-no-token=%{http_code}\n",/podinfo/api/info)'; \
	run '$(call edge_curl,-D - -o /dev/null -X OPTIONS -H "Origin: https://app.local-dev.test" -H "Access-Control-Request-Method: GET",/podinfo/) | grep -iE "^HTTP|access-control"'; \
	expect 'podinfo-no-token=200' 'auth none means no token: the prefix is in the DENY policy s notPaths'; \
	expect 'access-control-allow-origin' 'CORS is a filter on the route itself, and admission refuses a public route that reaches a backend without one'; \
	finish '403 on /orders with no token, 401 with an unverifiable one, 403 again with a kubernetes-audience token, 200 with a public-api token for carol and x-user-email at the backend, and /podinfo still 200 with CORS and no token at all'

demo-partner-api: demo-guard
	@$(call demo_begin,partner-api,a partner enters through its own gateway port and certificate with its own key set and its own rate limit); \
	run 'cond platform-ingress gateway.gateway.networking.k8s.io partner Programmed'; \
	run 'kubectl -n platform-ingress get svc -l gateway.networking.k8s.io/gateway-name=partner'; \
	run 'kubectl -n platform-ingress get svc -l gateway.networking.k8s.io/gateway-name=public'; \
	run 'kubectl get ns partner-api -L platform.k8s-base/role'; \
	run 'kubectl -n platform-ingress get certificate partners-wildcard -o jsonpath="{.spec.dnsNames} {.status.conditions[?(@.type==\"Ready\")].status}"; echo'; \
	run 'kubectl -n partner-api get httproute -L platform.k8s-base/owner-team,platform.k8s-base/auth'; \
	run 'kubectl -n partner-api get secret -o name'; \
	run 'kubectl -n platform-ingress get authorizationpolicy partner-edge-api-key -o jsonpath="{.spec.action} {.spec.provider.name}"; echo'; \
	run 'kubectl -n platform-ingress get envoyfilter -l platform.k8s-base/team=team-sec-ops'; \
	run 'kubectl -n team-b-apps get referencegrant allow-public-api -o jsonpath="{range .spec.from[*]}{.namespace}{\" \"}{end}"; echo'; \
	expect 'True (Address assigned|Resource programmed)' 'the partner Gateway is Programmed'; \
	expect 'partner.*LoadBalancer.*9443:[0-9]+/TCP' 'on its own LoadBalancer Service listening on 9443, because servicelb binds one host port per Service'; \
	expect 'public.*LoadBalancer.*80:[0-9]+/TCP,443:[0-9]+/TCP' 'and the public edge keeps its own Service and ports: two proxies, two blast radii'; \
	expect 'partner-api +Active.*partner-edge' 'the ResourceSet stamped role partner-edge on partner-api'; \
	expect 'partners.local-dev.test.* True' 'the partner subzone has its own wildcard certificate from the same local CA'; \
	expect 'partner-a .* team-b +api-key' 'the partner route names the backend s team as owner, not sec-ops, and declares auth=api-key'; \
	expect 'partner-b .* team-b +api-key' 'and so does the second partner'; \
	expect 'secret/partner-a-keys' 'the key Secret reached the cluster only through SOPS decryption by the sec-ops Flux identity'; \
	expect 'CUSTOM edge-authz' 'every request on the partner Gateway is checked by edge-authz, which reads that Secret, before anything is routed'; \
	expect 'partner-a-ratelimit' 'and each partner s rate limit is its own EnvoyFilter on the Gateway, applied by sec-ops'; \
	expect 'public-api partner-api' 'the owning team consented to each edge namespace separately'; \
	section 'no key, the wrong key, and the partner s own key'; \
	run '$(call partner_curl,partner-a,-o /dev/null -w "no-key=%{http_code}\n",/v1/orders/api/info)'; \
	run '$(call partner_curl,partner-a,-H "x-api-key: 0000000000000000" -o /dev/null -w "wrong-key=%{http_code}\n",/v1/orders/api/info)'; \
	run '$(call partner_curl,partner-a,-H "x-api-key: $$(cat $(PARTNER_KEY_DIR)/partner-a-prod.key)" -o $(DEMO_OUT_DIR)/partner-headers -w "partner-a=%{http_code}\n",/v1/orders/headers)'; \
	run 'jq -r "to_entries[] | .key + \": \" + (.value | join(\",\"))" $(DEMO_OUT_DIR)/partner-headers | tr "A-Z" "a-z"'; \
	expect 'no-key=401' 'without a key the edge answers 401 and the backend is never reached'; \
	expect 'wrong-key=401' 'and a key nobody issued is the same 401'; \
	expect 'partner-a=200' 'partner-a s own key returns 200 from podinfo in team-b-apps'; \
	expect 'x-partner-id: partner-a-prod' 'and the backend learns which client id called, not just which partner'; \
	expect_not 'x-api-key' 'the credential itself is stripped at the edge: sanitize works next to forwardClientIDHeader'; \
	section 'a key is good on one host only'; \
	run '$(call partner_curl,partner-b,-H "x-api-key: $$(cat $(PARTNER_KEY_DIR)/partner-a-prod.key)" -o /dev/null -w "a-key-on-b=%{http_code}\n",/v1/orders/api/info)'; \
	run '$(call partner_curl,partner-b,-H "x-api-key: $$(cat $(PARTNER_KEY_DIR)/partner-b-prod.key)" -o /dev/null -w "b-key-on-b=%{http_code}\n",/v1/orders/api/info)'; \
	run 'curl -sS --cacert $(CA_BUNDLE) --resolve partner-a.$(PARTNER_ZONE):$(PUBLIC_PORT):127.0.0.1 -o /dev/null -w "partner-host-on-public-edge=%{http_code}\n" https://partner-a.$(PARTNER_ZONE):$(PUBLIC_PORT)/v1/orders/api/info'; \
	expect 'a-key-on-b=401' 'partner-a s key on partner-b s host is a 401 by construction: each partner has its own key Secret'; \
	expect 'b-key-on-b=200' 'and partner-b s own key works on it'; \
	expect 'partner-host-on-public-edge=000' 'the partner subzone cannot be reached on the public edge at all'; \
	expect 'certificate subject name' 'and it fails before HTTP: the public wildcard certificate covers one label of the zone, so it does not even name a partner host'; \
	section 'each partner s rate limit is its own number'; \
	run '$(call partner_curl,partner-a,-D - -o /dev/null -H "x-api-key: $$(cat $(PARTNER_KEY_DIR)/partner-a-prod.key)",/v1/orders/api/info) | grep -iE "^HTTP|x-ratelimit-limit"'; \
	run '$(call partner_curl,partner-b,-D - -o /dev/null -H "x-api-key: $$(cat $(PARTNER_KEY_DIR)/partner-b-prod.key)",/v1/orders/api/info) | grep -iE "^HTTP|x-ratelimit-limit"'; \
	expect 'x-ratelimit-limit: 100' 'partner-a is served its contractual 100 per minute'; \
	expect 'x-ratelimit-limit: 50' 'and partner-b its own 50, from an EnvoyFilter scoped to that one partner s virtual host'; \
	section 'no shortcuts, at admission'; \
	run 'sed s/__DOMAIN__/$(CLUSTER_DOMAIN)/g demos/partner/partner-route-on-public.yaml | kubectl --as=system:serviceaccount:team-sec-ops:flux -n public-api apply -f -'; \
	run 'sed s/__DOMAIN__/$(CLUSTER_DOMAIN)/g demos/partner/jwt-route-on-partner.yaml | kubectl --as=system:serviceaccount:team-sec-ops:flux -n partner-api apply -f -'; \
	expect 'claims a hostname its edge does not serve' 'public-route-owner refuses a partner hostname on the public edge'; \
	expect 'the partner edge serves api-key only' 'and refuses a jwt route in partner-api: the class and the edge are checked against each other'; \
	finish '401 without a key and with the wrong key, 200 with the partner s own key and x-partner-id but no x-api-key at the backend, 401 for that key on the other partner s host, a TLS failure for the partner host on the public edge, rate limits of 100 and 50, and two admission denials'

# A browser login cannot be automated, so the access demos use Dex's resource
# owner password credentials grant; it is the one setting in this epic that must
# not survive into a real cluster. $(OIDC_PROXY_ENV) is what lets kubelogin
# resolve the issuer on a laptop with no /etc/hosts entry for it.
define demo_logins
  $(MAKE) --no-print-directory dex-proxy >/dev/null; \
  export $(OIDC_PROXY_ENV); \
  login() { \
    $(MAKE) --no-print-directory login USER=$$1 >/dev/null; \
    kc=$(KEYS_DIR)/users/$$1/kubeconfig; pw="$${1%%@*}$(DEMO_PW_SUFFIX)"; \
    yq -i ".users[0].user.exec.args += [\"--grant-type=password\", \"--username=$$1\", \"--password=$$pw\"]" $$kc; \
    echo $$kc; \
  }
endef

define demo_canI
  KUBECONFIG=$(1) kubectl auth can-i $(3) 2>/dev/null | sed "s/^/$(2)=/"
endef

demo-access: demo-guard
	@$(call demo_begin,access,developer access tiers through real OIDC logins); \
	$(demo_logins); \
	ALICE=$$(login alice@team-a.local); BOB=$$(login bob@team-a.local); \
	CAROL=$$(login carol@team-b.local); VIEWER=$$(login viewer@company.local); \
	OPS=$$(login ops@platform.local); \
	section 'who the API server thinks they are'; \
	run "KUBECONFIG=$$ALICE kubectl auth whoami -o json | jq -c .status.userInfo"; \
	expect '"username":"alice@team-a.local"' 'alice authenticates as her email through Dex'; \
	expect 'team-a:dev' 'the CEL group map in the apiserver derived her group'; \
	expect_not 'system:masters' 'no system: group leaks into an OIDC identity'; \
	run "KUBECONFIG=$$OPS kubectl auth whoami -o json | jq -c .status.userInfo"; \
	expect 'platform:operator' 'ops carries platform:operator'; \
	section 'alice: developer tier, her own namespaces only'; \
	run '$(call demo_canI,$$ALICE,alice-own-pods,get pods -n team-a-apps)'; \
	run '$(call demo_canI,$$ALICE,alice-other-team-pods,get pods -n team-b-apps)'; \
	run '$(call demo_canI,$$ALICE,alice-exec,create pods/exec -n team-a-apps)'; \
	run '$(call demo_canI,$$ALICE,alice-secrets,get secrets -n team-a-apps)'; \
	run '$(call demo_canI,$$ALICE,alice-flux-patch,patch kustomizations.kustomize.toolkit.fluxcd.io -n team-a)'; \
	run '$(call demo_canI,$$ALICE,alice-flux-delete,delete ocirepositories.source.toolkit.fluxcd.io -n team-a)'; \
	run '$(call demo_canI,$$ALICE,alice-request,create accessrequests.access.k8s-base.io -n team-a)'; \
	run '$(call demo_canI,$$ALICE,alice-approve,update accessrequests.access.k8s-base.io -n team-a --subresource=status)'; \
	expect 'alice-own-pods=yes' 'alice reads pods in team-a-apps'; \
	expect 'alice-other-team-pods=no' 'alice cannot read pods in team-b-apps'; \
	expect 'alice-exec=no' 'exec is never standing, not even in her own namespace'; \
	expect 'alice-secrets=no' 'the view tier excludes secrets'; \
	expect 'alice-flux-patch=yes' 'flux reconcile / suspend works for a developer'; \
	expect 'alice-flux-delete=no' 'but she cannot delete her own Flux source'; \
	expect 'alice-request=yes' 'a developer may file an AccessRequest'; \
	expect 'alice-approve=no' 'and may not approve one'; \
	section 'bob: team admin, with escalation prevention'; \
	run '$(call demo_canI,$$BOB,bob-rolebindings,create rolebindings -n team-a-apps)'; \
	run '$(call demo_canI,$$BOB,bob-approve,update accessrequests.access.k8s-base.io -n team-a --subresource=status)'; \
	run "KUBECONFIG=$$BOB kubectl -n team-a-apps create rolebinding escalate --clusterrole=cluster-admin --user=bob@team-a.local"; \
	run "KUBECONFIG=$$BOB kubectl -n team-a-apps create rolebinding escalate-debug --clusterrole=platform-debug --user=bob@team-a.local"; \
	run "KUBECONFIG=$$BOB kubectl -n team-a-apps create rolebinding delegate --clusterrole=view --user=carol@team-b.local --dry-run=server"; \
	expect 'bob-rolebindings=yes' 'bob may create RoleBindings in his workload namespace'; \
	expect 'bob-approve=yes' 'and may approve an AccessRequest in his team home namespace'; \
	expect 'forbidden|not allowed to escalate|may not CREATE' 'bob cannot bind cluster-admin or platform-debug'; \
	expect 'created \(server dry run\)' 'but he can delegate a role he already holds'; \
	section 'carol: the wrong team'; \
	run '$(call demo_canI,$$CAROL,carol-team-a,get pods -n team-a-apps)'; \
	run '$(call demo_canI,$$CAROL,carol-team-b,get pods -n team-b-apps)'; \
	expect 'carol-team-a=no' 'carol sees nothing in team-a'; \
	expect 'carol-team-b=yes' 'carol does see her own team'; \
	section 'viewer: read everywhere, write nowhere'; \
	run '$(call demo_canI,$$VIEWER,viewer-read,get pods -n team-d-analytics)'; \
	run '$(call demo_canI,$$VIEWER,viewer-write,create configmaps -n team-d-analytics)'; \
	run '$(call demo_canI,$$VIEWER,viewer-flux-system,get pods -n flux-system)'; \
	expect 'viewer-read=yes' 'company:viewer reads every team namespace'; \
	expect 'viewer-write=no' 'company:viewer writes nowhere'; \
	expect 'viewer-flux-system=no' 'and a per-namespace binding keeps it out of the platform namespaces'; \
	section 'ops: platform operator, not cluster-admin'; \
	run '$(call demo_canI,$$OPS,ops-secrets,get secrets -A)'; \
	run '$(call demo_canI,$$OPS,ops-nodes,get nodes)'; \
	run '$(call demo_canI,$$OPS,ops-exec,create pods/exec -n team-a-apps)'; \
	run '$(call demo_canI,$$OPS,ops-flux,patch kustomizations.kustomize.toolkit.fluxcd.io -n flux-system)'; \
	expect 'ops-secrets=no' 'platform:operator cannot read secrets'; \
	expect 'ops-nodes=yes' 'platform:operator reads cluster-scoped state'; \
	expect 'ops-exec=no' 'no standing exec for the platform team either'; \
	expect 'ops-flux=yes' 'platform:operator drives Flux'; \
	finish 'five identities, five different answers, and nobody holds standing exec or secrets'

demo-audit: demo-guard
	@$(call demo_begin,audit,the audit log records which human did what); \
	$(demo_logins); \
	BOB=$$(login bob@team-a.local); \
	section 'bob creates and removes a RoleBinding in his own namespace'; \
	run "KUBECONFIG=$$BOB kubectl -n team-a-apps create rolebinding audit-probe --clusterrole=view --user=carol@team-b.local"; \
	expect 'created' 'the write succeeded'; \
	run "KUBECONFIG=$$BOB kubectl -n team-a-apps delete rolebinding audit-probe"; \
	section 'what the apiserver wrote to $(AUDIT_LOG)'; \
	sleep 5; \
	run "docker exec $(K3D_SERVER) tail -n 4000 $(AUDIT_LOG) | jq -c 'select(.objectRef.name == \"audit-probe\") | {level, verb, user: .user.username, groups: .user.groups, ns: .objectRef.namespace, hasBody: (.requestObject != null)}'"; \
	expect 'bob@team-a.local' 'the entry names the human, not a service account'; \
	expect 'team-a:admin' 'and the group the CEL map derived'; \
	expect '"verb":"create"' 'the create is recorded'; \
	expect '"verb":"delete"' 'and so is the delete'; \
	expect '"level":"RequestResponse"' 'RBAC writes are logged at RequestResponse'; \
	expect '"hasBody":true' 'with the request body included'; \
	section 'make audit-tail shows humans only'; \
	run "$(MAKE) --no-print-directory audit-tail AUDIT_LINES=400 | grep audit-probe"; \
	expect 'bob@team-a.local' 'audit-tail surfaces the same entry'; \
	expect_not '"user":"system:' 'and filters the control plane out'; \
	finish 'a named human, a named group and a full request body in the audit log'

demo-internal-oidc: demo-guard
	@$(call demo_begin,internal-oidc,internal UIs are reached by login rather than by port-forward); \
	section 'the route and the policy are accepted'; \
	run "kubectl -n platform-identity get httproute hubble-ui -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}'; echo"; \
	expect 'Accepted=True' 'the internal Gateway accepted the route'; \
	expect 'ResolvedRefs=True' 'and the ReferenceGrant in kube-system resolved the backend'; \
	run "kubectl -n platform-ingress get authorizationpolicy internal-edge-hubble-oidc -o jsonpath='{.spec.action} {.spec.provider.name} {.spec.rules[0].to[0].operation.hosts[0]}'; echo"; \
	expect 'CUSTOM oauth2-proxy hubble.internal' 'the internal Gateway hands the hubble host to oauth2-proxy before routing anything'; \
	section 'an unauthenticated request is redirected to Dex'; \
	SVC=$$(kubectl -n platform-ingress get svc -l gateway.networking.k8s.io/gateway-name=internal -o jsonpath='{.items[0].metadata.name}'); \
	printf '\n$$ kubectl -n platform-ingress port-forward svc/%s 8444:443 &\n' "$$SVC"; \
	kubectl -n platform-ingress port-forward svc/$$SVC 8444:443 >$(DEMO_OUT_DIR)/internal-pf.log 2>&1 & \
	_pf=$$!; sleep 8; \
	run "curl -s -o /dev/null -D - --cacert $(CA_BUNDLE) --resolve $(HUBBLE_HOST):8444:127.0.0.1 https://$(HUBBLE_HOST):8444/"; \
	expect 'HTTP/[0-9.]+ 302' '302, not 200: the UI sits behind a login'; \
	expect 'dex.local-dev.test:8443/auth' 'redirected to Dex, the browser-facing issuer'; \
	expect '_hubble_oauth2_csrf' 'and the CSRF cookie the callback leg will check travels with the redirect'; \
	kill $$_pf 2>/dev/null || true; \
	section 'and no human held a port-forward right to get there'; \
	$(demo_logins); \
	ALICE=$$(login alice@team-a.local); \
	run '$(call demo_canI,$$ALICE,alice-portforward,create pods/portforward -n kube-system)'; \
	run '$(call demo_canI,$$ALICE,alice-hubble-pods,get pods -n kube-system)'; \
	expect 'alice-portforward=no' 'alice cannot port-forward the Hubble UI herself'; \
	expect 'alice-hubble-pods=no' 'she cannot even list the pods behind it'; \
	finish 'the Hubble UI answers 302 to Dex on the internal Gateway, and no developer holds port-forward'

demo-jit: demo-guard
	@$(call demo_begin,jit,exec is granted just-in-time by someone else for a bounded window); \
	$(demo_logins); \
	ALICE=$$(login alice@team-a.local); BOB=$$(login bob@team-a.local); \
	CAROL=$$(login carol@team-b.local); \
	section 'no standing exec, and no hand-made shortcut either'; \
	run "KUBECONFIG=$$ALICE kubectl -n team-a-apps exec deploy/podinfo -- true"; \
	expect 'cannot create resource "pods/exec"|forbidden' 'alice holds no standing exec'; \
	run "KUBECONFIG=$$BOB kubectl apply -f demos/access/handmade-debug-binding.yaml"; \
	expect 'attempting to grant RBAC permissions not currently held' 'RBAC escalation prevention refuses bob a platform-debug binding before admission is even consulted'; \
	run "kubectl --as=tester --as-group=system:masters apply -f demos/access/handmade-debug-binding.yaml"; \
	expect "ValidatingAdmissionPolicy 'jit-binding-lock'" 'and for an identity RBAC does let through, jit-binding-lock is the second fence'; \
	expect 'granted only through an approved AccessRequest' 'the denial says where platform-debug comes from'; \
	section 'alice files a request for herself, two minutes'; \
	run "KUBECONFIG=$$ALICE $(MAKE) --no-print-directory access-request ROLE=debug NS=team-a-apps DURATION=2m REASON='podinfo 5xx after 14:00, need to inspect /tmp'"; \
	expect 'accessrequest.access.k8s-base.io/alice-debug-.*created' 'the request lands in team-a, her team home namespace'; \
	NAME=$$(kubectl -n team-a get accessrequests -o jsonpath='{.items[-1:].metadata.name}'); \
	printf '    request: %s\n' "$$NAME"; \
	section 'the wrong team cannot approve it, and neither can the requester'; \
	run "KUBECONFIG=$$CAROL $(MAKE) --no-print-directory access-approve NAME=$$NAME NS=team-a"; \
	expect 'forbidden|denied|may not approve' 'carol, in another team, is refused'; \
	run "KUBECONFIG=$$ALICE $(MAKE) --no-print-directory access-approve NAME=$$NAME NS=team-a"; \
	expect 'may not approve their own request|four eyes|forbidden|denied' 'alice cannot approve her own request'; \
	run "kubectl -n team-a get accessrequest $$NAME -o jsonpath='{.status.phase}'; echo"; \
	expect 'Pending' 'the request is still Pending'; \
	section 'the team lead can, and the warden grants it'; \
	run "KUBECONFIG=$$BOB $(MAKE) --no-print-directory access-approve NAME=$$NAME NS=team-a"; \
	wait_for 60 'the warden to mint the binding' "kubectl -n team-a-apps get rolebinding jit-$$NAME"; \
	run "kubectl -n team-a-apps get rolebinding jit-$$NAME -o jsonpath='{.roleRef.name}{\" \"}{.subjects[0].name}{\" \"}{.metadata.annotations.access\\.k8s-base/approved-by}{\" \"}{.metadata.annotations.access\\.k8s-base/expires-at}'; echo"; \
	expect 'platform-debug alice@team-a.local bob@team-a.local' 'the binding names the role, the grantee and the approver'; \
	run "kubectl -n team-a get accessrequest $$NAME -o jsonpath='{.status.phase}'; echo"; \
	expect 'Active' 'the request is Active'; \
	section 'the window works'; \
	run "KUBECONFIG=$$ALICE kubectl -n team-a-apps exec deploy/podinfo -- sh -c 'echo exec-ok'"; \
	expect 'exec-ok' 'alice can exec while the grant is live'; \
	sleep 5; \
	run "$(MAKE) --no-print-directory audit-exec | grep alice@team-a.local | tail -3"; \
	expect '"sub":"exec"' 'the audit log recorded the CONNECT on pods/exec'; \
	expect 'alice@team-a.local' 'with her email'; \
	section 'and closes itself'; \
	wait_for 240 'the sweep to expire the grant' \
	  'test "$$(kubectl -n team-a get accessrequest '"$$NAME"' -o jsonpath={.status.phase})" = Expired'; \
	run "kubectl -n team-a-apps get rolebinding jit-$$NAME"; \
	expect 'NotFound|not found' 'the binding is gone'; \
	run "KUBECONFIG=$$ALICE kubectl -n team-a-apps exec deploy/podinfo -- true"; \
	expect 'cannot create resource "pods/exec"|forbidden' 'exec is forbidden again'; \
	finish 'exec forbidden, requested, refused twice, approved once, used, audited and swept'

demo-jit-cleanup: demo-guard
	@echo "==> cleanup: removing the jit demo AccessRequests"
	@kubectl -n team-a delete accessrequests --all --ignore-not-found --timeout=90s 2>&1 | sed 's/^/    /'
	@kubectl -n team-a-apps delete rolebinding i-grant-myself-debug --ignore-not-found 2>&1 | sed 's/^/    /'

demo-breakglass: demo-guard
	@$(call demo_begin,breakglass,four eyes on cluster-admin and revocable early); \
	$(demo_logins); \
	BOB=$$(login bob@team-a.local); OPS=$$(login ops@platform.local); \
	OPS2=$$(login ops2@platform.local); \
	section 'nobody holds cluster-admin standing'; \
	run "kubectl get clusterrolebinding -o json | jq -r '.items[] | select(.roleRef.name==\"cluster-admin\") | .metadata.name + \" -> \" + ([.subjects[]?|.kind+\"/\"+.name]|join(\",\"))'"; \
	expect_not 'User/.*@' 'no OIDC identity appears in a cluster-admin binding'; \
	run '$(call demo_canI,$$OPS,ops-secrets-before,get secrets -A)'; \
	expect 'ops-secrets-before=no' 'ops cannot read secrets before the request'; \
	section 'the cap is enforced at creation, not only by the warden'; \
	run "KUBECONFIG=$$OPS $(MAKE) --no-print-directory access-request ROLE=cluster-admin DURATION=8h REASON='restore the flux-system HelmRelease history'"; \
	expect 'role cluster-admin is capped at 3600s' 'cluster-admin over an hour is refused at admission'; \
	section 'ops requests an hour of cluster-admin'; \
	run "KUBECONFIG=$$OPS $(MAKE) --no-print-directory access-request ROLE=cluster-admin DURATION=1h REASON='restore the flux-system HelmRelease history after the failed upgrade'"; \
	expect 'created' 'the request lands in platform-access'; \
	NAME=$$(kubectl -n platform-access get accessrequests -o jsonpath='{.items[-1:].metadata.name}'); \
	printf '    request: %s\n' "$$NAME"; \
	section 'a team admin cannot approve it, and neither can the requester'; \
	run "KUBECONFIG=$$BOB $(MAKE) --no-print-directory access-approve NAME=$$NAME NS=platform-access"; \
	expect 'forbidden|denied|may not approve' 'bob is not a platform:operator'; \
	run "KUBECONFIG=$$OPS $(MAKE) --no-print-directory access-approve NAME=$$NAME NS=platform-access"; \
	expect 'may not approve their own request|four eyes|forbidden|denied' 'ops cannot approve their own request'; \
	section 'the second platform engineer can'; \
	run "KUBECONFIG=$$OPS2 $(MAKE) --no-print-directory access-approve NAME=$$NAME NS=platform-access"; \
	wait_for 60 'the warden to mint the ClusterRoleBinding' "kubectl get clusterrolebinding jit-$$NAME"; \
	run "kubectl get clusterrolebinding jit-$$NAME -o jsonpath='{.roleRef.name}{\" \"}{.subjects[0].name}{\" \"}{.metadata.annotations.access\\.k8s-base/approved-by}'; echo"; \
	expect 'cluster-admin ops@platform.local ops2@platform.local' 'four eyes are recorded on the binding'; \
	run "kubectl get clusterrolebinding jit-$$NAME -o json | jq -r '.metadata.annotations | keys[]'"; \
	expect 'access.k8s-base/request-uid' 'the request-uid jit-binding-lock demands is there'; \
	run '$(call demo_canI,$$OPS,ops-secrets-during,get secrets -A)'; \
	expect 'ops-secrets-during=yes' 'ops now reads secrets cluster-wide'; \
	section 'and it can be ended early'; \
	run "KUBECONFIG=$$OPS $(MAKE) --no-print-directory access-revoke NAME=$$NAME NS=platform-access"; \
	wait_for 120 'the warden to drop the ClusterRoleBinding' \
	  "! kubectl get clusterrolebinding jit-$$NAME >/dev/null 2>&1"; \
	run "kubectl -n platform-access get accessrequest $$NAME -o jsonpath='{.status.phase}'; echo"; \
	expect 'Revoked' 'the request is Revoked'; \
	run '$(call demo_canI,$$OPS,ops-secrets-after,get secrets -A)'; \
	expect 'ops-secrets-after=no' 'and the right is gone again'; \
	finish 'cluster-admin needs two platform engineers, lasts an hour at most, and ends on demand'

demo-breakglass-cleanup: demo-guard
	@echo "==> cleanup: removing the breakglass AccessRequests"
	@kubectl -n platform-access delete accessrequests --all --ignore-not-found --timeout=90s 2>&1 | sed 's/^/    /'

demo-privileged-guard: demo-guard
	@$(call demo_begin,privileged-guard,data and platform namespaces are exec-free for everyone); \
	$(demo_logins); \
	ALICE=$$(login alice@team-a.local); BOB=$$(login bob@team-a.local); \
	OPS=$$(login ops@platform.local); OPS2=$$(login ops2@platform.local); \
	section 'the label is on the data namespace and on every platform namespace'; \
	run "kubectl get ns -l platform.k8s-base/privileged-access=forbidden -o name | sort"; \
	expect 'namespace/team-d-analytics' 'the data-plane namespace carries it'; \
	expect 'namespace/platform-access' 'and the namespace the warden runs in'; \
	expect 'namespace/istio-system' 'and the mesh control plane'; \
	section 'RBAC refuses a debug request for a namespace bob team does not own'; \
	run "KUBECONFIG=$$BOB $(MAKE) --no-print-directory access-request ROLE=debug NS=team-d-analytics DURATION=10m REASON='analytics pod wedged, inspect the data directory'"; \
	expect 'carries no platform.k8s-base/team label|forbidden|home namespace of a team' 'bob cannot even resolve team-d-analytics, let alone request debug in it'; \
	section 'so take the widest grant the platform can issue: cluster-admin, four-eyed'; \
	run "KUBECONFIG=$$OPS $(MAKE) --no-print-directory access-request ROLE=cluster-admin DURATION=10m REASON='analytics pod wedged, inspect the data directory'"; \
	NAME=$$(kubectl -n platform-access get accessrequests -o jsonpath='{.items[-1:].metadata.name}'); \
	run "KUBECONFIG=$$OPS2 $(MAKE) --no-print-directory access-approve NAME=$$NAME NS=platform-access"; \
	wait_for 60 'the cluster-admin grant' "kubectl get clusterrolebinding jit-$$NAME"; \
	run '$(call demo_canI,$$OPS,ops-exec-rbac,create pods/exec -n team-d-analytics)'; \
	expect 'ops-exec-rbac=yes' 'RBAC now allows the exec'; \
	run "KUBECONFIG=$$OPS kubectl -n team-d-analytics exec deploy/podinfo -- true"; \
	expect 'privileged-access-guard|exec-free|privileged-access=forbidden' 'admission refuses it anyway: the policy is the ceiling, RBAC is the floor'; \
	section 'the same guard caps kubectl debug to a curated image'; \
	POD=$$(kubectl -n team-a-apps get pod -l app.kubernetes.io/name=podinfo -o jsonpath='{.items[0].metadata.name}'); \
	printf '    target pod: %s\n' "$$POD"; \
	run "KUBECONFIG=$$OPS kubectl -n team-a-apps debug pod/$$POD --image=docker.io/library/alpine:3 --profile=restricted -c dbg-bad --attach=false"; \
	expect 'curated debug image|privileged-access-guard' 'a non-allow-listed image is refused'; \
	section 'and admits the curated one'; \
	run "KUBECONFIG=$$OPS kubectl -n team-a-apps debug pod/$$POD --image=$(BUSYBOX_IMAGE) --profile=restricted -c dbg-ok --attach=false -- sleep 30"; \
	expect_not 'curated debug image' 'the allow-listed image is admitted'; \
	expect_not 'forbidden' 'with no denial at all'; \
	run "kubectl -n team-a-apps get pod $$POD -o jsonpath='{.spec.ephemeralContainers[*].image}'; echo"; \
	expect '$(BUSYBOX_IMAGE)' 'and only the curated image reached the pod'; \
	section 'and token minting is not a back door'; \
	run "KUBECONFIG=$$ALICE kubectl -n team-a-apps create token flux"; \
	expect 'standing credential|privileged-access-guard|forbidden' 'a human may not mint a workload token in a team namespace'; \
	run "kubectl -n team-a-apps create token flux >/dev/null && echo bootstrap-token-ok"; \
	expect 'bootstrap-token-ok' 'the break-glass identity still can, so make up is unaffected'; \
	finish 'exec into a forbidden namespace is refused even with cluster-admin, debug images are allow-listed, and humans mint no tokens'

demo-privileged-guard-cleanup: demo-guard
	@echo "==> cleanup: revoking the grant and dropping the pod that carries the debug container"
	@kubectl -n platform-access delete accessrequests --all --ignore-not-found --timeout=90s 2>&1 | sed 's/^/    /'
	@kubectl -n team-a-apps delete pod -l app.kubernetes.io/name=podinfo --ignore-not-found --timeout=180s 2>&1 | sed 's/^/    /'
	@kubectl -n team-a-apps rollout status deploy/podinfo --timeout=180s 2>&1 | sed 's/^/    /'

demo-gitops-only: demo-guard
	@$(call demo_begin,gitops-only,hand-applied workload objects are caught -- warn here and deny on prod); \
	$(demo_logins); \
	BOB=$$(login bob@team-a.local); \
	section 'this cluster carries the warn binding only'; \
	run "kubectl get validatingadmissionpolicybinding -o custom-columns=NAME:.metadata.name,POLICY:.spec.policyName,ACTIONS:.spec.validationActions | grep gitops-only"; \
	expect 'gitops-only-warn.*Warn' 'gitops-only-warn is bound'; \
	expect_not 'gitops-only-deny' 'the deny binding is not on this cluster'; \
	section 'bob applies a Deployment by hand'; \
	run "KUBECONFIG=$$BOB kubectl apply -f demos/access/handmade-deployment.yaml 2>&1"; \
	expect 'Warning.*gitops-only' 'the warning names the policy'; \
	expect 'bob@team-a.local may not CREATE' 'and the human who did it'; \
	expect 'deployment.apps/drift created' 'but the object is admitted on this dev-tier cluster'; \
	run "KUBECONFIG=$$BOB kubectl -n team-a-apps delete deployment drift"; \
	section 'switch to the prod binding and retry'; \
	run "kubectl apply -f repos/infra/policies/base/prod/gitops-only-deny.yaml"; \
	sleep 10; \
	run "KUBECONFIG=$$BOB kubectl apply -f demos/access/handmade-deployment.yaml 2>&1"; \
	expect 'denied|forbidden' 'on a prod-tier cluster the same apply is denied'; \
	expect_not 'drift created' 'nothing was admitted'; \
	section 'the same object through git still applies'; \
	run "cp demos/access/handmade-deployment.yaml repos/team-a/apps/podinfo/base/drift.yaml"; \
	run "yq -i '.resources += [\"drift.yaml\"]' repos/team-a/apps/podinfo/base/kustomization.yaml"; \
	run "$(MAKE) --no-print-directory push REPO=team-a"; \
	run "flux -n team-a reconcile kustomization team-a --with-source"; \
	wait_for 180 'the Deployment to arrive through Flux' 'kubectl -n team-a-apps get deployment drift'; \
	run "kubectl -n team-a-apps get deployment drift -o jsonpath='{.metadata.labels}'; echo"; \
	expect 'platform.k8s-base/team.*team-a' 'applied by the team Flux ServiceAccount, not by a human'; \
	finish 'a hand-applied Deployment warns here and is denied on prod, while the same object through git is applied'

demo-gitops-only-cleanup: demo-guard
	@echo "==> cleanup: restoring the dev-tier binding and removing the drift Deployment"
	@kubectl delete validatingadmissionpolicybinding gitops-only-deny --ignore-not-found 2>&1 | sed 's/^/    /'
	@rm -f repos/team-a/apps/podinfo/base/drift.yaml
	@yq -i '.resources -= ["drift.yaml"]' repos/team-a/apps/podinfo/base/kustomization.yaml
	@$(MAKE) --no-print-directory push REPO=team-a 2>&1 | sed 's/^/    /'
	@flux -n team-a reconcile kustomization team-a --with-source 2>&1 | sed 's/^/    /'
	@kubectl -n team-a-apps delete deployment drift --ignore-not-found --timeout=90s 2>&1 | sed 's/^/    /'
