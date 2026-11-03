
.PHONY: k8s-help registry-create registry-delete cluster-create cluster-delete cluster-status cilium-mount-fix cilium-status hubble-ui hubble-port-forward

K3D_CONFIG   := k3d/cluster.yaml
CLUSTER_NETWORK  = k3d-$(CLUSTER_NAME)
WAIT_TIMEOUT := 120s
CNI_TIMEOUT  := 300s
export CLUSTER_NAME := local-dev

export CLUSTER_ENV ?= local
FLEET_DIR     = repos/fleet/clusters/$(CLUSTER_ENV)
CLUSTER_VARS  = $(FLEET_DIR)/cluster-vars.yaml
# The one cluster-vars value make itself needs: the demos build hostnames from
# it rather than from a literal.
CLUSTER_DOMAIN = $(shell yq -r '.data.CLUSTER_DOMAIN // ""' $(CLUSTER_VARS) 2>/dev/null)

REG_SHORT := local-dev-registry
export REG_NAME         := k3d-local-dev-registry
export REG_HOST_PORT    := 5050
export REG_CLUSTER_PORT := 5000

export OCI_LOCAL_URL   := localhost:5050
export OCI_CLUSTER_URL := k3d-local-dev-registry:5000

export TEAMS        := team-a team-b team-c team-d team-sec-ops
export PLATFORM_REPOS := fleet infra platform
export REPOS          := fleet infra platform team-a team-b team-c team-d team-sec-ops

# age and runtime material is per environment: a prod Secret must not decrypt on
# dev. Recursive, because artifacts.mk is read before CLUSTER_ENV is defined.
export KEYS_DIR = .keys/$(CLUSTER_ENV)
# The cosign key answers "the platform built this artifact", which is the same
# answer on every cluster; the environment gate is the tag, guarded by push.
export COSIGN_KEYS_DIR := .keys/cosign

export K3D_FIX_MOUNTS := 1

k8s-help:
	@echo "Cluster (k3d/k3s) Commands:"
	@echo "--------------------------"
	@echo "  cluster-create   - Create the local registry (if needed) and the k3d cluster"
	@echo "  cluster-delete   - Delete the k3d cluster (keeps the registry / image cache)"
	@echo "  cluster-status   - Show cluster, nodes and registry status"
	@echo "  registry-create  - Create the local image registry (idempotent)"
	@echo "  registry-delete  - Delete the local image registry"
	@echo "  cilium-mount-fix - Ensure a shared bpffs inside every k3d node"
	@echo "  cilium-status    - cilium status --wait"
	@echo "  hubble-ui        - Port-forward the Hubble UI to http://localhost:12000"
	@echo "  hubble-port-forward - Forward hubble-relay to localhost:4245 for the hubble CLI"
	@echo ""

registry-create:
	@if docker ps -a --format '{{.Names}}' | grep -qx "$(REG_NAME)"; then \
		echo "==> Registry '$(REG_NAME)' already exists"; \
		docker start $(REG_NAME) >/dev/null 2>&1 || true; \
	else \
		echo "==> Creating local registry '$(REG_NAME)' on localhost:$(REG_HOST_PORT)"; \
		k3d registry create $(REG_SHORT) --port $(REG_HOST_PORT); \
	fi

registry-delete:
	@echo "==> Deleting local registry '$(REG_NAME)'"
	@k3d registry delete $(REG_NAME) 2>/dev/null || echo "  (registry not found)"

cluster-create: registry-create
	@if k3d cluster list 2>/dev/null | awk 'NR>1{print $$1}' | grep -qx "$(CLUSTER_NAME)"; then \
		echo "==> Cluster '$(CLUSTER_NAME)' already exists"; \
	else \
		echo "==> Creating k3d cluster '$(CLUSTER_NAME)' from $(K3D_CONFIG)"; \
		k3d cluster create --config $(K3D_CONFIG) --wait; \
	fi
	@$(MAKE) --no-print-directory cilium-mount-fix
	@echo "==> Waiting for the Cilium HelmChart to produce the agent DaemonSet"
	@for i in $$(seq 1 60); do \
		kubectl -n kube-system get ds/cilium >/dev/null 2>&1 && break; \
		sleep 5; \
	done
	@kubectl -n kube-system rollout status ds/cilium --timeout=$(CNI_TIMEOUT)
	@kubectl -n kube-system rollout status deploy/cilium-operator --timeout=$(CNI_TIMEOUT)
	@kubectl wait --for=condition=Ready nodes --all --timeout=$(WAIT_TIMEOUT)
	@echo "==> Waiting for the default StorageClass provisioner to be ready"
	@kubectl -n kube-system rollout status deploy/local-path-provisioner --timeout=$(WAIT_TIMEOUT) 2>/dev/null || true
	@echo "==> Cluster is ready!"
	@kubectl get nodes -o wide

cluster-delete:
	@echo "==> Deleting k3d cluster '$(CLUSTER_NAME)'"
	@k3d cluster delete $(CLUSTER_NAME) 2>/dev/null || echo "  (cluster not found)"
	@if docker network inspect $(CLUSTER_NETWORK) >/dev/null 2>&1; then \
	  echo "==> Removing network '$(CLUSTER_NETWORK)' so the subnet in $(K3D_CONFIG) is reapplied on the next create"; \
	  docker network disconnect $(CLUSTER_NETWORK) $(REG_NAME) >/dev/null 2>&1 || true; \
	  docker network rm $(CLUSTER_NETWORK) >/dev/null 2>&1 || echo "  (network still in use; the next create will reuse its current subnet)"; \
	fi
	@echo "==> Registry '$(REG_NAME)' left running (image cache). Remove with: make registry-delete"

cluster-status:
	@echo "==> k3d clusters:"
	@k3d cluster list 2>/dev/null || echo "  (k3d not available)"
	@echo "==> Nodes:"
	@kubectl get nodes -o wide 2>/dev/null || echo "  (cluster not running)"
	@echo "==> Registries:"
	@k3d registry list 2>/dev/null || echo "  (none)"
	@echo "==> Registry catalog (http://$(OCI_LOCAL_URL)):"
	@curl -s http://$(OCI_LOCAL_URL)/v2/_catalog 2>/dev/null | jq -c . || echo "  (registry not reachable)"
	@echo "==> Cilium:"
	@kubectl -n kube-system get ds/cilium deploy/cilium-operator 2>/dev/null || echo "  (cilium not installed)"

cilium-mount-fix:
	@echo "==> Ensuring a shared bpffs in the k3d node containers"
	@for n in $$(docker ps --format '{{.Names}}' | grep -E '^k3d-$(CLUSTER_NAME)-(server|agent)-[0-9]+$$'); do \
		echo "  - $$n"; \
		docker exec $$n sh -c 'mountpoint -q /sys/fs/bpf || mount bpffs /sys/fs/bpf -t bpf; mount --make-shared /sys/fs/bpf' || true; \
	done

cilium-status:
	@cilium status --wait

hubble-ui:
	@echo "==> Hubble UI will be served on http://localhost:12000 (Ctrl-C to stop)"
	@cilium hubble ui

hubble-port-forward:
	@cilium hubble port-forward &
	@echo "==> hubble-relay forwarded to localhost:4245; try: hubble observe"
