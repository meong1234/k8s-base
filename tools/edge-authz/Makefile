.PHONY: help build test vet tidy docker-build run

BIN_DIR := bin
IMAGE ?= docker.io/k8s-base/edge-authz:dev

help:
	@echo "edge-authz"
	@echo "----------"
	@echo "  build         - compile into $(BIN_DIR)/edge-authz"
	@echo "  test          - go test ./..."
	@echo "  vet           - go vet ./..."
	@echo "  docker-build  - build $(IMAGE)"
	@echo "  run           - run against the current kubeconfig (KUBECONFIG or ~/.kube/config)"
	@echo ""

build:
	go build -o $(BIN_DIR)/edge-authz .

test:
	go test ./...

vet:
	go vet ./...

tidy:
	go mod tidy

docker-build:
	docker build -t $(IMAGE) .

run:
	go run . --kubeconfig=$${KUBECONFIG:-$$HOME/.kube/config}
