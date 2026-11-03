.PHONY: help build test vet generate manifests tidy docker-build run

MODULE := github.com/meong1234/k8s-base/warden
BIN_DIR := bin
CONTROLLER_GEN_VERSION ?= v0.23.0
CONTROLLER_GEN := $(BIN_DIR)/controller-gen
CRD_OUT := ../repos/infra/crds/base/access/accessrequests.yaml
IMAGE ?= docker.io/k8s-base/access-warden:dev

help:
	@echo "access-warden"
	@echo "-------------"
	@echo "  build         - compile ./cmd into $(BIN_DIR)/access-warden"
	@echo "  test          - go test ./..."
	@echo "  vet           - go vet ./..."
	@echo "  generate      - regenerate zz_generated.deepcopy.go"
	@echo "  manifests     - regenerate $(CRD_OUT) from the Go types"
	@echo "  docker-build  - build $(IMAGE)"
	@echo ""

$(CONTROLLER_GEN):
	GOBIN=$(CURDIR)/$(BIN_DIR) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION)

generate: $(CONTROLLER_GEN)
	$(CONTROLLER_GEN) object paths=./api/...

manifests: $(CONTROLLER_GEN)
	@mkdir -p $(dir $(CRD_OUT))
	$(CONTROLLER_GEN) crd paths=./api/... output:crd:stdout > $(CRD_OUT)

build:
	go build -o $(BIN_DIR)/access-warden ./cmd

test:
	go test ./...

vet:
	go vet ./...

tidy:
	go mod tidy

run:
	go run ./cmd

docker-build:
	docker build -t $(IMAGE) .
