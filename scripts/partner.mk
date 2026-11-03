
.PHONY: partner-help partner-sim-keys partner-sim-up partner-sim-inject partner-sim-down partner-sim-status

PARTNER_BANK_NAME  ?= k3d-local-dev-partner-bank
PARTNER_BANK_IP    ?= 172.28.0.250
PARTNER_BANK_IMAGE := docker.io/library/nginx:1.29-alpine
PARTNER_NETWORK     = k3d-$(CLUSTER_NAME)
PARTNER_KEYS        = $(KEYS_DIR)/partner-bank
PARTNER_CONF       := sim/partner-bank/nginx.conf
PARTNER_HOST       := api.partner-bank.test
PARTNER_CLIENT_CN  := k8s-base-egress
PARTNER_CA_SUBJECT := /CN=partner-bank-ca/O=k8s-base
PARTNER_CA_DAYS    := 3650
PARTNER_EGRESS_NS  := platform-egress
PARTNER_SECRET     := partner-bank-client
PARTNER_NS_TIMEOUT := 600
PARTNER_CURL_IMAGE := docker.io/curlimages/curl:8.11.1

partner-help:
	@echo "Partner Simulation Commands:"
	@echo "---------------------------"
	@echo "  partner-sim-keys   - Generate the partner CA, server and client certificates into $(PARTNER_KEYS) (idempotent)"
	@echo "  partner-sim-up     - Run the $(PARTNER_BANK_NAME) container on $(PARTNER_NETWORK) at $(PARTNER_BANK_IP)"
	@echo "  partner-sim-inject - Create Secret $(PARTNER_SECRET) in $(PARTNER_EGRESS_NS) from $(PARTNER_KEYS)"
	@echo "  partner-sim-down   - Remove the container (the keys stay)"
	@echo "  partner-sim-status - Container, Secret and the egress-allowlist objects for $(PARTNER_HOST)"
	@echo ""

partner-sim-keys:
	@mkdir -p $(PARTNER_KEYS)
	@if [ -f $(PARTNER_KEYS)/ca.crt ] && [ -f $(PARTNER_KEYS)/server.crt ] && [ -f $(PARTNER_KEYS)/client.crt ]; then \
	  echo "==> Partner bank keys already exist: $(PARTNER_KEYS)"; \
	else \
	  echo "==> Generating the partner bank CA, server and client certificates into $(PARTNER_KEYS)"; \
	  openssl req -x509 -newkey rsa:2048 -nodes \
	    -keyout $(PARTNER_KEYS)/ca.key -out $(PARTNER_KEYS)/ca.crt -days $(PARTNER_CA_DAYS) \
	    -subj "$(PARTNER_CA_SUBJECT)" \
	    -addext "basicConstraints=critical,CA:TRUE" \
	    -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" 2>/dev/null; \
	  printf 'subjectAltName=DNS:$(PARTNER_HOST),IP:$(PARTNER_BANK_IP)\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\n' \
	    > $(PARTNER_KEYS)/server.ext; \
	  openssl req -newkey rsa:2048 -nodes \
	    -keyout $(PARTNER_KEYS)/server.key -out $(PARTNER_KEYS)/server.csr \
	    -subj "/CN=$(PARTNER_HOST)" 2>/dev/null; \
	  openssl x509 -req -in $(PARTNER_KEYS)/server.csr \
	    -CA $(PARTNER_KEYS)/ca.crt -CAkey $(PARTNER_KEYS)/ca.key -CAcreateserial \
	    -out $(PARTNER_KEYS)/server.crt -days $(PARTNER_CA_DAYS) \
	    -extfile $(PARTNER_KEYS)/server.ext 2>/dev/null; \
	  printf 'extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature\n' \
	    > $(PARTNER_KEYS)/client.ext; \
	  openssl req -newkey rsa:2048 -nodes \
	    -keyout $(PARTNER_KEYS)/client.key -out $(PARTNER_KEYS)/client.csr \
	    -subj "/CN=$(PARTNER_CLIENT_CN)" 2>/dev/null; \
	  openssl x509 -req -in $(PARTNER_KEYS)/client.csr \
	    -CA $(PARTNER_KEYS)/ca.crt -CAkey $(PARTNER_KEYS)/ca.key -CAcreateserial \
	    -out $(PARTNER_KEYS)/client.crt -days $(PARTNER_CA_DAYS) \
	    -extfile $(PARTNER_KEYS)/client.ext 2>/dev/null; \
	fi
	@chmod -R go-rwx $(PARTNER_KEYS)
	@openssl x509 -in $(PARTNER_KEYS)/server.crt -noout -subject -ext subjectAltName | sed 's/^/    /'
	@openssl x509 -in $(PARTNER_KEYS)/client.crt -noout -subject -enddate | sed 's/^/    /'

partner-sim-up: demo-guard partner-sim-keys
	@if docker ps --format '{{.Names}}' | grep -qx "$(PARTNER_BANK_NAME)"; then \
	  echo "==> Partner bank '$(PARTNER_BANK_NAME)' is already running"; \
	elif docker ps -a --format '{{.Names}}' | grep -qx "$(PARTNER_BANK_NAME)"; then \
	  echo "==> Starting the existing partner bank '$(PARTNER_BANK_NAME)'"; \
	  docker start $(PARTNER_BANK_NAME) >/dev/null; \
	else \
	  echo "==> Running the partner bank '$(PARTNER_BANK_NAME)' on $(PARTNER_NETWORK) at $(PARTNER_BANK_IP)"; \
	  docker run -d --name $(PARTNER_BANK_NAME) \
	    --network $(PARTNER_NETWORK) --ip $(PARTNER_BANK_IP) \
	    -v $(CURDIR)/$(PARTNER_KEYS):/certs:ro \
	    -v $(CURDIR)/$(PARTNER_CONF):/etc/nginx/conf.d/default.conf:ro \
	    $(PARTNER_BANK_IMAGE) >/dev/null; \
	fi
	@docker ps --filter name=$(PARTNER_BANK_NAME) --format '    {{.Names}} {{.Status}} {{.Image}}'

partner-sim-inject: demo-guard partner-sim-keys
	@echo "==> Waiting for namespace $(PARTNER_EGRESS_NS) (timeout $(PARTNER_NS_TIMEOUT)s)"
	@i=0; until kubectl get namespace $(PARTNER_EGRESS_NS) >/dev/null 2>&1; do \
	  i=$$((i+5)); \
	  if [ $$i -ge $(PARTNER_NS_TIMEOUT) ]; then \
	    echo "    $(PARTNER_EGRESS_NS) never appeared — is platform-ks reconciling?"; exit 1; \
	  fi; \
	  sleep 5; \
	done
	@kubectl -n $(PARTNER_EGRESS_NS) create secret generic $(PARTNER_SECRET) \
	  --type=kubernetes.io/tls \
	  --from-file=tls.crt=$(PARTNER_KEYS)/client.crt \
	  --from-file=tls.key=$(PARTNER_KEYS)/client.key \
	  --from-file=ca.crt=$(PARTNER_KEYS)/ca.crt \
	  --dry-run=client -o yaml | kubectl apply -f - | sed 's/^/    /'

partner-sim-down: demo-guard
	@echo "==> Removing the partner bank '$(PARTNER_BANK_NAME)'"
	@docker rm -f $(PARTNER_BANK_NAME) >/dev/null 2>&1 \
	  && echo "    removed" \
	  || echo "    (container not found)"

partner-sim-status: demo-guard
	@echo "==> Partner bank container"
	@docker ps -a --filter name=$(PARTNER_BANK_NAME) \
	  --format '    {{.Names}} {{.Status}} {{.Image}} {{.Networks}}' 2>/dev/null \
	  | grep . || echo "    (not created — run make partner-sim-up)"
	@echo "==> Address on $(PARTNER_NETWORK)"
	@docker inspect -f '    {{range $$k, $$v := .NetworkSettings.Networks}}{{$$k}} {{$$v.IPAddress}}{{end}}' \
	  $(PARTNER_BANK_NAME) 2>/dev/null || echo "    (not created)"
	@echo "==> Client credential in $(PARTNER_EGRESS_NS)"
	@kubectl -n $(PARTNER_EGRESS_NS) get secret $(PARTNER_SECRET) 2>&1 | sed 's/^/    /'
	@echo "==> Allow-list objects for $(PARTNER_HOST)"
	@kubectl -n egress-allowlist get serviceentry,destinationrule,authorizationpolicy \
	  api-partner-bank-test 2>&1 | sed 's/^/    /'
