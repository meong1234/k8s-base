.PHONY: access-help access-request access-approve access-deny access-list access-revoke \
        warden-logs warden-build warden-push warden-image

WARDEN_DIR := warden
WARDEN_IMAGE := docker.io/k8s-base/access-warden:dev
WARDEN_LOCAL_IMAGE = localhost:$(REG_HOST_PORT)/k8s-base/access-warden:dev
WARDEN_NS := platform-access
WARDEN_SWEEP := 30s

ROLE ?= debug
DURATION ?= 1h

define access_whoami
  kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null
endef

define access_home_ns
  kubectl get namespace "$(NS)" -o jsonpath='{.metadata.labels.platform\.k8s-base/team}' 2>/dev/null
endef

define access_find_ns
  kubectl get accessrequests -A \
    -o jsonpath='{range .items[?(@.metadata.name=="$(NAME)")]}{.metadata.namespace}{end}' 2>/dev/null
endef

access-help:
	@echo "Just-in-Time Privileged Access Commands:"
	@echo "---------------------------------------"
	@echo "  access-request   - File an AccessRequest as the current user"
	@echo "                     ROLE=debug|team-admin|cluster-admin NS=<target> DURATION=1h REASON='...'"
	@echo "  access-approve   - Approve a request as the current user (four eyes: never your own)"
	@echo "                     NAME=<request> [NS=<request namespace>]"
	@echo "  access-deny      - Deny a request                NAME=<request> [NS=...]"
	@echo "  access-revoke    - End an active grant early     NAME=<request> [NS=...]"
	@echo "  access-list      - Every AccessRequest plus the live jit-* bindings and their expiry"
	@echo "  warden-logs      - Tail the access-warden log"
	@echo "  warden-build     - Build $(WARDEN_IMAGE) from $(WARDEN_DIR)/"
	@echo "  warden-push      - Push it to the local registry as $(WARDEN_LOCAL_IMAGE)"
	@echo "  warden-image     - warden-build + warden-push"
	@echo ""
	@echo "  Roles: debug (exec/attach/port-forward/debug, cap 4h), team-admin (cap 8h),"
	@echo "         cluster-admin (cap 1h, platform-access only, platform:operator approval)"
	@echo "  Use KUBECONFIG=$(USER_KEYS)/<user>/kubeconfig to act as a specific identity."
	@echo ""

access-request:
	@if [ -z "$(NS)" ] && [ "$(ROLE)" != "cluster-admin" ]; then \
		echo "Error: NS=<target namespace> is required"; \
		echo "Usage: make access-request ROLE=debug NS=team-a-apps DURATION=1h REASON='podinfo 5xx after 14:00'"; \
		exit 1; \
	fi
	@if [ -z "$(REASON)" ]; then \
		echo "Error: REASON='...' is required and must be at least 10 characters"; \
		exit 1; \
	fi
	@USER_NAME=$$($(access_whoami)); \
	if [ -z "$$USER_NAME" ]; then echo "Error: cannot determine the current user, is KUBECONFIG set?"; exit 1; fi; \
	SHORT=$$(echo "$$USER_NAME" | sed -E 's/@.*//; s/[^a-z0-9]+/-/g'); \
	STAMP=$$(date -u +%Y%m%d-%H%M%S); \
	REQ_NAME="$$SHORT-$(ROLE)-$$STAMP"; \
	if [ "$(ROLE)" = "cluster-admin" ]; then \
		REQ_NS=$(WARDEN_NS); TARGET_NS=$(WARDEN_NS); \
	else \
		REQ_NS=$$($(access_home_ns)); TARGET_NS="$(NS)"; \
		if [ -z "$$REQ_NS" ]; then \
			echo "Error: namespace $(NS) carries no platform.k8s-base/team label, so it owns no team home namespace"; \
			exit 1; \
		fi; \
	fi; \
	echo "==> Filing AccessRequest $$REQ_NS/$$REQ_NAME as $$USER_NAME"; \
	jq -n --arg n "$$REQ_NAME" --arg ns "$$REQ_NS" --arg requester "$$USER_NAME" \
	      --arg role "$(ROLE)" --arg target "$$TARGET_NS" --arg duration "$(DURATION)" \
	      --arg reason "$(REASON)" \
	  '{apiVersion:"access.k8s-base.io/v1alpha1",kind:"AccessRequest",metadata:{name:$$n,namespace:$$ns},spec:{requester:$$requester,role:$$role,targetNamespace:$$target,duration:$$duration,reason:$$reason}}' \
	  | kubectl create -f - && \
	echo "==> Ask a different person to run: make access-approve NAME=$$REQ_NAME NS=$$REQ_NS"

access-approve:
	@if [ -z "$(NAME)" ]; then echo "Error: NAME=<request> is required"; exit 1; fi
	@REQ_NS="$(NS)"; \
	if [ -z "$$REQ_NS" ]; then REQ_NS=$$($(access_find_ns)); fi; \
	if [ -z "$$REQ_NS" ]; then echo "Error: AccessRequest $(NAME) not found in any namespace you can read"; exit 1; fi; \
	USER_NAME=$$($(access_whoami)); \
	echo "==> Approving $$REQ_NS/$(NAME) as $$USER_NAME"; \
	kubectl patch accessrequest $(NAME) -n $$REQ_NS --subresource=status --type=merge \
		-p "{\"status\":{\"phase\":\"Approved\",\"approvedBy\":\"$$USER_NAME\"}}"; \
	kubectl get accessrequest $(NAME) -n $$REQ_NS

access-deny:
	@if [ -z "$(NAME)" ]; then echo "Error: NAME=<request> is required"; exit 1; fi
	@REQ_NS="$(NS)"; \
	if [ -z "$$REQ_NS" ]; then REQ_NS=$$($(access_find_ns)); fi; \
	if [ -z "$$REQ_NS" ]; then echo "Error: AccessRequest $(NAME) not found in any namespace you can read"; exit 1; fi; \
	USER_NAME=$$($(access_whoami)); \
	echo "==> Denying $$REQ_NS/$(NAME) as $$USER_NAME"; \
	kubectl patch accessrequest $(NAME) -n $$REQ_NS --subresource=status --type=merge \
		-p "{\"status\":{\"phase\":\"Denied\",\"approvedBy\":\"$$USER_NAME\"}}"

access-revoke:
	@if [ -z "$(NAME)" ]; then echo "Error: NAME=<request> is required"; exit 1; fi
	@REQ_NS="$(NS)"; \
	if [ -z "$$REQ_NS" ]; then REQ_NS=$$($(access_find_ns)); fi; \
	if [ -z "$$REQ_NS" ]; then echo "Error: AccessRequest $(NAME) not found in any namespace you can read"; exit 1; fi; \
	echo "==> Revoking $$REQ_NS/$(NAME)"; \
	kubectl patch accessrequest $(NAME) -n $$REQ_NS --subresource=status --type=merge \
		-p '{"status":{"phase":"Revoked"}}'; \
	echo "==> The warden deletes the binding on its next reconcile (within $(WARDEN_SWEEP))"

access-list:
	@echo "==> AccessRequests"
	@kubectl get accessrequests -A 2>/dev/null || echo "  (the CRD is not installed)"
	@echo ""
	@echo "==> Live namespaced grants"
	@kubectl get rolebindings -A -l access.k8s-base/managed-by=access-warden \
		-o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,ROLE:.roleRef.name,USER:.subjects[0].name,EXPIRES:.metadata.annotations.access\.k8s-base/expires-at,APPROVER:.metadata.annotations.access\.k8s-base/approved-by' \
		2>/dev/null | grep -v '^No resources' || echo "  none"
	@echo ""
	@echo "==> Live cluster-wide grants"
	@kubectl get clusterrolebindings -l access.k8s-base/managed-by=access-warden \
		-o custom-columns='NAME:.metadata.name,ROLE:.roleRef.name,USER:.subjects[0].name,EXPIRES:.metadata.annotations.access\.k8s-base/expires-at,APPROVER:.metadata.annotations.access\.k8s-base/approved-by' \
		2>/dev/null | grep -v '^No resources' || echo "  none"
	@echo ""
	@echo "==> Any cluster-admin binding that is NOT warden-managed (must be bootstrap identities only)"
	@kubectl get clusterrolebindings -o json | jq -r \
		'.items[] | select(.roleRef.name=="cluster-admin") | select((.metadata.labels // {})["access.k8s-base/managed-by"] != "access-warden") | "  " + .metadata.name + " -> " + ([.subjects[]? | .kind + "/" + .name] | join(","))'

warden-logs:
	@kubectl -n $(WARDEN_NS) logs deploy/access-warden --tail=100 -f

warden-build:
	@echo "==> Building $(WARDEN_IMAGE) from $(WARDEN_DIR)/"
	@docker build -t $(WARDEN_IMAGE) $(WARDEN_DIR)

warden-push:
	@if ! docker ps --format '{{.Names}}' | grep -qx "$(REG_NAME)"; then \
		echo "Error: registry '$(REG_NAME)' is not running"; \
		echo "Please run 'make registry-create' (or 'make cluster-create') first"; \
		exit 1; \
	fi
	@echo "==> $(WARDEN_IMAGE) -> $(WARDEN_LOCAL_IMAGE)"
	@docker tag $(WARDEN_IMAGE) $(WARDEN_LOCAL_IMAGE)
	@docker push $(WARDEN_LOCAL_IMAGE)
	@echo "==> Nodes resolve $(WARDEN_IMAGE) through the docker.io mirror (see k3d/cluster.yaml)"

warden-image: warden-build warden-push
