
.PHONY: identity-help platform-ca platform-ca-inject authn-render dex-hashes dex-render dex-client-secret \
        dex-secrets api-token login whoami login-help hosts-print dex-hosts-fix dex-proxy dex-proxy-build dex-proxy-stop \
        audit-tail audit-exec

IDENTITY_USERS   = $(FLEET_DIR)/identity/users.yaml
PLATFORM_KEYS    = $(KEYS_DIR)/platform
USER_KEYS        = $(KEYS_DIR)/users
CA_CRT           = $(PLATFORM_KEYS)/ca.crt
CA_KEY           = $(PLATFORM_KEYS)/ca.key
CA_DAYS         := 3650
CA_NS_TIMEOUT   := 600
CA_SECRET_NS    := flux-system
CA_SUBJECT      := /CN=k8s-base local-dev CA/O=k8s-base
AUTHN_TMPL      := k3d/authn.yaml.tmpl
AUTHN_OUT        = $(PLATFORM_KEYS)/authn.yaml
AUDIT_POLICY    := k3d/audit-policy.yaml
DEX_HASHES       = $(PLATFORM_KEYS)/dex-hashes.yaml
DEX_USERS_CM     = repos/platform/identity/envs/$(CLUSTER_ENV)/dex-users-configmap.yaml
DEX_CLIENT_FILE  = $(PLATFORM_KEYS)/dex-client-secret
DEX_CLIENT_ID   := kubernetes
PUBLIC_API_CLIENT_FILE = $(PLATFORM_KEYS)/dex-public-api-secret
PUBLIC_API_CLIENT_ID  := public-api
DEX_NS          := platform-identity
DEX_HOST        := dex.local-dev.test
DEX_PORT        := 8443
DEX_ISSUER      := https://$(DEX_HOST):$(DEX_PORT)
HUBBLE_HOST     := hubble.internal.local-dev.test
# A hosts file cannot hold a wildcard, so every demo hostname is listed.
HOSTS_NAMES     := $(DEX_HOST) $(HUBBLE_HOST) api.local-dev.test

# Demo passwords are derived, not random: the bcrypt hashes are committed in
# $(DEX_USERS_CM), and a hash cannot be reversed to re-print the password.
DEMO_PW_SUFFIX  := -local-dev
DEMO_CLIENT_SECRET := dex-kubernetes-local-dev-secret
DEMO_PUBLIC_API_SECRET := dex-public-api-local-dev-secret

DEX_PROXY_PORT  := 18443
DEX_PROXY_PID    = $(PLATFORM_KEYS)/dex-proxy.pid
DEX_PROXY_BIN    = $(PLATFORM_KEYS)/dexproxy
DEX_PROXY_SRC   := warden/cmd/dexproxy
# kubelogin resolves $(DEX_HOST) itself and there is no --resolve for it, so a
# laptop without the /etc/hosts line (editing it needs root) has no path to Dex.
# warden/cmd/dexproxy supplies the name-to-address decision over HTTPS_PROXY.
OIDC_PROXY_ENV   = HTTPS_PROXY=http://127.0.0.1:$(DEX_PROXY_PORT) \
                   NO_PROXY=127.0.0.1,0.0.0.0,localhost,::1,.svc,.cluster.local
OIDC_ENV         = $(OIDC_PROXY_ENV)

K3D_SERVER       = k3d-$(CLUSTER_NAME)-server-0
AUDIT_LOG       := /var/log/kubernetes/audit.log
AUDIT_LINES     ?= 20
# k3s names its own control plane without a system: prefix, so the "humans only"
# filter has to exclude it by name.
AUDIT_NON_HUMANS := k3s-cloud-controller-manager,k3s,kube-apiserver,system

identity-help:
	@echo "Identity Commands:"
	@echo "-----------------"
	@echo "  platform-ca       - Generate the shared local CA into $(PLATFORM_KEYS)/ca.{crt,key} (idempotent)"
	@echo "  platform-ca-inject - Apply Secret $(CA_SECRET_NS)/local-ca from that CA (ClusterIssuer local-ca reads it)"
	@echo "  authn-render      - Render $(AUTHN_TMPL) + $(IDENTITY_USERS) -> $(AUTHN_OUT)"
	@echo "  dex-hashes        - Add a bcrypt hash for every user missing from $(DEX_HASHES)"
	@echo "  dex-render        - Render $(DEX_USERS_CM) from $(IDENTITY_USERS) + $(DEX_HASHES)"
	@echo "  dex-client-secret - Write the demo OIDC client secrets to $(DEX_CLIENT_FILE) and $(PUBLIC_API_CLIENT_FILE)"
	@echo "  dex-secrets       - Create Secret dex-client in $(DEX_NS) out of band (both client secrets)"
	@echo "  api-token USER=<email> PASS=<password> - Print an id_token for the $(PUBLIC_API_CLIENT_ID) client (password grant)"
	@echo "  dex-hosts-fix     - Point $(DEX_HOST) at host.k3d.internal inside the server node"
	@echo "  hosts-print       - Print the /etc/hosts lines this laptop needs"
	@echo "  dex-proxy         - Build and start the loopback CONNECT proxy that stands in for those lines"
	@echo "  dex-proxy-stop    - Stop it"
	@echo "  login USER=<email>        - Write $(USER_KEYS)/<email>/kubeconfig (kubelogin exec plugin)"
	@echo "  whoami KUBECONFIG=<path>  - kubectl auth whoami through that kubeconfig"
	@echo "  login-help        - Print the demo users, their groups and their passwords"
	@echo "  audit-tail        - Tail the apiserver audit log (last $(AUDIT_LINES) entries)"
	@echo "  audit-exec        - Show only privileged-access audit events"
	@echo ""

platform-ca:
	@mkdir -p $(PLATFORM_KEYS)
	@if [ -f $(CA_CRT) ] && [ -f $(CA_KEY) ]; then \
	  echo "==> Platform CA already exists: $(CA_CRT)"; \
	else \
	  echo "==> Generating the platform CA into $(PLATFORM_KEYS)"; \
	  openssl req -x509 -newkey rsa:2048 -nodes \
	    -keyout $(CA_KEY) -out $(CA_CRT) -days $(CA_DAYS) \
	    -subj "$(CA_SUBJECT)" \
	    -addext "basicConstraints=critical,CA:TRUE" \
	    -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" 2>/dev/null; \
	fi
	@chmod go-rwx $(CA_KEY)
	@openssl x509 -in $(CA_CRT) -noout -subject -enddate | sed 's/^/    /'

platform-ca-inject: platform-ca
	@echo "==> Waiting for namespace $(CA_SECRET_NS)"
	@i=0; until kubectl get namespace $(CA_SECRET_NS) >/dev/null 2>&1; do \
	  i=$$((i+5)); [ $$i -ge $(CA_NS_TIMEOUT) ] && { echo "    never appeared"; exit 1; }; sleep 5; \
	done
	@kubectl -n $(CA_SECRET_NS) create secret tls local-ca \
	  --cert=$(CA_CRT) --key=$(CA_KEY) \
	  --dry-run=client -o yaml | kubectl apply -f - | sed 's/^/    /'

authn-render: platform-ca
	@scripts/render-authn.sh $(IDENTITY_USERS) $(CA_CRT) $(AUTHN_TMPL) $(AUTHN_OUT)

dex-hashes:
	@command -v htpasswd >/dev/null || { echo "htpasswd is required (Apache httpd; preinstalled on macOS)"; exit 1; }
	@mkdir -p $(PLATFORM_KEYS)
	@touch $(DEX_HASHES)
	@for u in $$(yq -r '.users[].email' $(IDENTITY_USERS)); do \
	  if yq -e 'has("'"$$u"'")' $(DEX_HASHES) >/dev/null 2>&1; then \
	    echo "    $$u: hash exists"; \
	  else \
	    pw="$${u%%@*}$(DEMO_PW_SUFFIX)"; \
	    hash=$$(htpasswd -nbBC 10 "" "$$pw" | cut -d: -f2); \
	    printf '%s: "%s"\n' "$$u" "$$hash" >> $(DEX_HASHES); \
	    echo "    $$u: hash generated"; \
	  fi; \
	done
	@chmod go-rwx $(DEX_HASHES)

dex-render: dex-hashes
	@echo "==> Rendering $(DEX_USERS_CM) from $(IDENTITY_USERS)"
	@{ \
	  echo "---"; \
	  echo "apiVersion: v1"; \
	  echo "kind: ConfigMap"; \
	  echo "metadata:"; \
	  echo "  name: dex-users"; \
	  echo "  namespace: flux-system"; \
	  echo "  labels:"; \
	  echo "    app.kubernetes.io/part-of: platform"; \
	  echo "  annotations:"; \
	  echo "    platform.k8s-base/generated-from: $(IDENTITY_USERS)"; \
	  echo '    # A bcrypt hash is `$$2y$$10$$<salt><digest>`, and Flux'\''s post-build'; \
	  echo '    # substitution would read every `$$<word>` in it as a variable and blank it.'; \
	  echo "    kustomize.toolkit.fluxcd.io/substitute: disabled"; \
	  echo "data:"; \
	  echo "  values.yaml: |"; \
	  echo "    config:"; \
	  echo "      staticPasswords:"; \
	  for u in $$(yq -r '.users[].email' $(IDENTITY_USERS)); do \
	    lp=$${u%%@*}; dom=$${u#*@}; \
	    hash=$$(yq -r '.["'"$$u"'"]' $(DEX_HASHES)); \
	    echo "        - email: $$u"; \
	    echo "          username: $$lp"; \
	    echo "          userID: $$lp-$${dom%%.*}"; \
	    echo "          hash: \"$$hash\""; \
	  done; \
	} > $(DEX_USERS_CM)
	@yq -r '.data["values.yaml"]' $(DEX_USERS_CM) | yq '.config.staticPasswords | length' | sed 's/^/    staticPasswords: /'

dex-client-secret:
	@mkdir -p $(PLATFORM_KEYS)
	@if [ -s $(DEX_CLIENT_FILE) ]; then \
	  echo "==> OIDC client secret already present: $(DEX_CLIENT_FILE)"; \
	else \
	  printf '%s' '$(DEMO_CLIENT_SECRET)' > $(DEX_CLIENT_FILE); \
	  echo "==> Wrote $(DEX_CLIENT_FILE)"; \
	fi
	@if [ -s $(PUBLIC_API_CLIENT_FILE) ]; then \
	  echo "==> Public API client secret already present: $(PUBLIC_API_CLIENT_FILE)"; \
	else \
	  printf '%s' '$(DEMO_PUBLIC_API_SECRET)' > $(PUBLIC_API_CLIENT_FILE); \
	  echo "==> Wrote $(PUBLIC_API_CLIENT_FILE)"; \
	fi
	@chmod go-rwx $(DEX_CLIENT_FILE) $(PUBLIC_API_CLIENT_FILE)

dex-secrets: dex-client-secret
	@echo "==> Waiting for namespace $(DEX_NS)"
	@i=0; until kubectl get namespace $(DEX_NS) >/dev/null 2>&1; do \
	  i=$$((i+2)); \
	  if [ $$i -ge 600 ]; then echo "    $(DEX_NS) never appeared — is infra-ks reconciling?"; exit 1; fi; \
	  sleep 2; \
	done
	@kubectl -n $(DEX_NS) create secret generic dex-client \
	  --from-file=client-secret=$(DEX_CLIENT_FILE) \
	  --from-file=public-api-client-secret=$(PUBLIC_API_CLIENT_FILE) \
	  --dry-run=client -o yaml | kubectl apply -f -

# Stdout is the token and nothing else, so $(shell) and $$(make -s api-token ...)
# both work; everything else goes to stderr.
api-token:
	@test -n "$(USER)" || { echo "USER=<email> required; see: make login-help" >&2; exit 1; }
	@test -n "$(PASS)" || { echo "PASS=<password> required; see: make login-help" >&2; exit 1; }
	@test -s $(PUBLIC_API_CLIENT_FILE) || $(MAKE) --no-print-directory dex-client-secret >&2
	@curl -sS --cacert $(CA_CRT) --resolve $(DEX_HOST):$(DEX_PORT):127.0.0.1 \
	  -u $(PUBLIC_API_CLIENT_ID):$$(cat $(PUBLIC_API_CLIENT_FILE)) \
	  -d grant_type=password -d username='$(USER)' -d password='$(PASS)' \
	  -d scope='openid email groups' \
	  $(DEX_ISSUER)/token \
	  | jq -r 'if .id_token then .id_token else ("dex: " + (.error_description // .error // "no id_token")) | halt_error(1) end'

dex-hosts-fix:
	@echo "==> Pointing $(DEX_HOST) at host.k3d.internal inside $(K3D_SERVER)"
	@ip=$$(docker exec $(K3D_SERVER) awk '$$2 == "host.k3d.internal" { print $$1; exit }' /etc/hosts); \
	 test -n "$$ip" || { echo "    host.k3d.internal does not resolve inside the node"; exit 1; }; \
	 docker exec $(K3D_SERVER) sh -c "grep -q ' $(DEX_HOST)$$' /etc/hosts || echo '$$ip $(DEX_HOST)' >> /etc/hosts"; \
	 echo "    $$ip $(DEX_HOST)"
	@docker exec $(K3D_SERVER) grep '$(DEX_HOST)' /etc/hosts | sed 's/^/    /'

dex-proxy-build:
	@mkdir -p $(PLATFORM_KEYS)
	@if [ ! -x $(DEX_PROXY_BIN) ] || [ -n "$$(find $(DEX_PROXY_SRC) -newer $(DEX_PROXY_BIN) -name '*.go' 2>/dev/null)" ]; then \
	  echo "==> Building $(DEX_PROXY_BIN) from $(DEX_PROXY_SRC)"; \
	  ( cd warden && go build -o $(CURDIR)/$(DEX_PROXY_BIN) ./cmd/dexproxy ); \
	fi

dex-proxy: dex-proxy-build
	@if [ -s $(DEX_PROXY_PID) ] && kill -0 $$(cat $(DEX_PROXY_PID)) 2>/dev/null; then \
	  echo "==> dex-proxy already running on 127.0.0.1:$(DEX_PROXY_PORT) (pid $$(cat $(DEX_PROXY_PID)))"; \
	else \
	  nohup $(DEX_PROXY_BIN) $(DEX_PROXY_PORT) >$(PLATFORM_KEYS)/dex-proxy.log 2>&1 & \
	  echo $$! > $(DEX_PROXY_PID); \
	  sleep 1; \
	  echo "==> dex-proxy listening on 127.0.0.1:$(DEX_PROXY_PORT) (pid $$(cat $(DEX_PROXY_PID)))"; \
	fi
	@echo "    use it with: $(OIDC_PROXY_ENV) kubectl ..."

dex-proxy-stop:
	@if [ -s $(DEX_PROXY_PID) ]; then kill $$(cat $(DEX_PROXY_PID)) 2>/dev/null || true; rm -f $(DEX_PROXY_PID); fi
	@echo "==> dex-proxy stopped"

hosts-print:
	@echo "==> Add this line to /etc/hosts on this laptop (sudo required):"
	@echo ""
	@echo "127.0.0.1 $(HOSTS_NAMES)"
	@echo ""
	@echo "    sudo sh -c 'echo \"127.0.0.1 $(HOSTS_NAMES)\" >> /etc/hosts'"
	@echo ""
	@for h in $(HOSTS_NAMES); do \
	  if grep -qs "[[:space:]]$$h\([[:space:]]\|$$\)" /etc/hosts; then \
	    printf '  ok      %s\n' "$$h"; \
	  else \
	    printf '  MISSING %s\n' "$$h"; \
	  fi; \
	done
	@echo ""
	@echo "The public Gateway answers on https://<name>:8443 (k3d maps 8443 -> 443@loadbalancer)."

login: dex-client-secret
	@test -n "$(USER)" || { echo "USER=<email> required; see: make login-help"; exit 1; }
	@yq -e '.users[] | select(.email == "$(USER)")' $(IDENTITY_USERS) >/dev/null 2>&1 \
	  || { echo "$(USER) is not listed in $(IDENTITY_USERS)"; exit 1; }
	@command -v kubectl-oidc_login >/dev/null \
	  || { echo "kubelogin is required: brew install int128/kubelogin/kubelogin"; exit 1; }
	@mkdir -p $(USER_KEYS)/$(USER)
	@server=$$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'); \
	 ca=$$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'); \
	 secret=$$(cat $(DEX_CLIENT_FILE)); \
	 { \
	   echo "apiVersion: v1"; \
	   echo "kind: Config"; \
	   echo "current-context: $(USER)"; \
	   echo "clusters:"; \
	   echo "  - name: $(CLUSTER_NAME)"; \
	   echo "    cluster:"; \
	   echo "      server: $$server"; \
	   echo "      certificate-authority-data: $$ca"; \
	   echo "contexts:"; \
	   echo "  - name: $(USER)"; \
	   echo "    context:"; \
	   echo "      cluster: $(CLUSTER_NAME)"; \
	   echo "      user: $(USER)"; \
	   echo "users:"; \
	   echo "  - name: $(USER)"; \
	   echo "    user:"; \
	   echo "      exec:"; \
	   echo "        apiVersion: client.authentication.k8s.io/v1"; \
	   echo "        command: kubectl"; \
	   echo "        interactiveMode: Never"; \
	   echo "        provideClusterInfo: false"; \
	   echo "        args:"; \
	   echo "          - oidc-login"; \
	   echo "          - get-token"; \
	   echo "          - --oidc-issuer-url=$(DEX_ISSUER)"; \
	   echo "          - --oidc-client-id=$(DEX_CLIENT_ID)"; \
	   echo "          - --oidc-client-secret=$$secret"; \
	   echo "          - --oidc-extra-scope=email"; \
	   echo "          - --oidc-extra-scope=groups"; \
	   echo "          - --certificate-authority=$(abspath $(CA_CRT))"; \
	 } > $(USER_KEYS)/$(USER)/kubeconfig
	@chmod go-rwx $(USER_KEYS)/$(USER)/kubeconfig
	@echo "==> Wrote $(USER_KEYS)/$(USER)/kubeconfig"
	@echo "    First use opens a browser at $(DEX_ISSUER); password: $$(echo '$(USER)' | cut -d@ -f1)$(DEMO_PW_SUFFIX)"
	@echo "    Try it: make whoami KUBECONFIG=$(USER_KEYS)/$(USER)/kubeconfig"

whoami: dex-proxy
	@test -n "$(KUBECONFIG)" || { echo "KUBECONFIG=<path> required"; exit 1; }
	@KUBECONFIG=$(KUBECONFIG) $(OIDC_ENV) kubectl auth whoami -o yaml

login-help:
	@echo "Demo identities (Dex static passwords, $(DEX_ISSUER)):"
	@echo "------------------------------------------------------------------"
	@printf '  %-22s %-20s %s\n' EMAIL GROUPS PASSWORD
	@yq -r '.users[] | .email + " " + (.groups | join(",")) + " " + (.email | sub("@.*"; "")) + "$(DEMO_PW_SUFFIX)"' $(IDENTITY_USERS) \
	  | while read -r e g p; do printf '  %-22s %-20s %s\n' "$$e" "$$g" "$$p"; done
	@echo ""
	@echo "  client id: $(DEX_CLIENT_ID)   client secret: $(DEX_CLIENT_FILE)"
	@echo "  client id: $(PUBLIC_API_CLIENT_ID)   client secret: $(PUBLIC_API_CLIENT_FILE)"
	@echo "  make login USER=<email>  then  make whoami KUBECONFIG=$(USER_KEYS)/<email>/kubeconfig"
	@echo "  make api-token USER=<email> PASS=<password>  prints an id_token for the public API (aud: $(PUBLIC_API_CLIENT_ID), valid 10m)"

audit-tail:
	@docker exec $(K3D_SERVER) sh -c 'test -r $(AUDIT_LOG)' \
	  || { echo "$(AUDIT_LOG) is not readable in $(K3D_SERVER) - is the audit policy wired into k3s?"; exit 1; }
	@docker exec $(K3D_SERVER) tail -n 2000 $(AUDIT_LOG) \
	  | jq -c --arg skip '$(AUDIT_NON_HUMANS)' 'select(.user.username as $$u | ($$u | startswith("system:") | not) and (($$skip | split(",")) | index($$u) == null)) | {t: .requestReceivedTimestamp, user: .user.username, groups: .user.groups, verb: .verb, resource: (.objectRef.resource // .requestURI), name: .objectRef.name, ns: .objectRef.namespace, level: .level, code: .responseStatus.code}' \
	  | tail -n $(AUDIT_LINES)

audit-exec:
	@docker exec $(K3D_SERVER) sh -c 'test -r $(AUDIT_LOG)' \
	  || { echo "$(AUDIT_LOG) is not readable in $(K3D_SERVER) - is the audit policy wired into k3s?"; exit 1; }
	@docker exec $(K3D_SERVER) tail -n 4000 $(AUDIT_LOG) \
	  | jq -c 'select((.objectRef.subresource // "") | IN("exec","attach","portforward","ephemeralcontainers","proxy","token")) | {t: .requestReceivedTimestamp, user: .user.username, groups: .user.groups, sub: .objectRef.subresource, pod: .objectRef.name, ns: .objectRef.namespace, command: ((.requestURI | capture("command=(?<c>[^&]*)") | .c) // null), code: .responseStatus.code}'
