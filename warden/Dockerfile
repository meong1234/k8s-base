FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY api/ api/
COPY internal/ internal/
COPY cmd/ cmd/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/access-warden ./cmd

FROM gcr.io/distroless/static:nonroot
WORKDIR /
COPY --from=build /out/access-warden /access-warden
USER 65532:65532
ENTRYPOINT ["/access-warden"]
