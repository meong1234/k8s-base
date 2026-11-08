FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/edge-authz .

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=build /out/edge-authz /edge-authz
USER 65532:65532
ENTRYPOINT ["/edge-authz"]
