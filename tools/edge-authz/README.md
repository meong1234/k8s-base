# edge-authz

The partner API-key check for the partner edge, as an Envoy HTTP ext_authz
service. Istio has no API-key primitive; this is the forty lines that replace
one, and it keeps the key Secrets, their format and their rotation exactly as
they were.

## What it decides

```
request on the partner Gateway
  Host: partner-a.partners.<zone>:9443      x-api-key: <k>
        │
        ▼
  partner := first DNS label of Host, port stripped            "partner-a"
  secret  := Secret "<partner>-keys" in partner-api              (informer cache)
  for every entry (client id → key) in the Secret:
      constant-time compare key with <k>  ──match──▶  200, x-partner-id: <client id>
  otherwise                                 ──────────▶  401, www-authenticate: ApiKey realm="partner-api"
```

A missing header, an unknown hostname, a wrong key and another partner's key
all produce the identical 401. The service never answers 5xx on purpose:
Envoy reads 5xx as "the authorizer is down" and returns the mesh's
`statusOnError`, never an allow.

## The contract with Envoy

Wired in `repos/platform/istio/base/istiod.yaml` as the `edge-authz`
`envoyExtAuthzHttp` provider and attached to the partner Gateway by
`repos/platform/edge-policies/base/authz-partner-api-key.yaml`.

| Aspect | What Envoy does |
| --- | --- |
| Method, path, Host | The client's own, forwarded as-is (path includes the query string) |
| Headers that arrive | `Host`, `Method`, `Path`, `Content-Length`, `Authorization`, plus `includeRequestHeadersInCheck` (`x-api-key`). Nothing else |
| Body | None |
| Allow | Exactly `200`. Response headers named in `headersToUpstreamOnAllow` (`x-partner-id`) are set on the upstream request, overwriting any value the client sent |
| Deny | Any other non-5xx status. Status and body reach the client; response headers reach it only if listed in `headersToDownstreamOnDeny` |
| Error | 5xx, timeout, connection failure → `statusOnError` (503), `failOpen: false` |

`x-api-key` is removed from the upstream request by a `RequestHeaderModifier`
on each partner route, not here: the HTTP ext_authz protocol can set upstream
headers but cannot remove one, and the router runs after this check has read
it.

## Why a watch, and why `platform-ingress`

The Secrets live in `partner-api` (sec-ops's, SOPS-decrypted by their Flux
identity) and the pod lives in `platform-ingress` (the platform's). A volume
cannot cross namespaces, and a mounted Secret needs a restart on rotation,
while the partner README promises rotation with no gap. So the service holds
a `SharedInformer` on Secrets in one namespace and picks up a change within
the watch latency. The read grant is a `Role` the fleet template stamps into
every `partner-edge` namespace, pointing at this ServiceAccount; it cannot
ship from the platform repo, because `partner-api` does not exist until the
teams `ResourceSet` runs, and the ResourceSet waits for the platform.

In `partner-api` the pod could not have run at all: the team baseline
NetworkPolicy has no egress to the API server. In `platform-ingress` there is
no NetworkPolicy, the partner gateway reaches it in-namespace, and the pod is
enrolled in ambient individually (a pod label; the namespace stays out, so
its gateways are not captured) so that hop is HBONE with the gateway's
identity.

## Flags

```
--listen=:8080              the check endpoint Envoy calls
--probe-listen=:8081        /healthz, /readyz; separate so no partner path can hit it
--secrets-namespace=partner-api
--secret-suffix=-keys       Secret name is <partner><suffix>
--key-header=x-api-key
--partner-id-header=x-partner-id
--kubeconfig=               used when not running in-cluster (make run)
```

One JSON log line per decision: `allow` with the client id, or `deny` with
the reason. `make edge-authz-logs` tails it.

Readiness is "serving", not "watch synced", on purpose. The Role that lets
this pod list the partner Secrets is stamped into `partner-api` by the teams
`ResourceSet`, and that ResourceSet waits for the platform stage this
Deployment is part of. A readiness probe tied to the watch would deadlock
`make up`. Until the watch syncs every key is a 401 and the reflector logs
the forbidden list on each retry; `secret watch synced` in the log is the
moment the partner door starts admitting keys.

## Build and run

```sh
cd tools/edge-authz
make test                     # the decision table
make docker-build             # docker.io/k8s-base/edge-authz:dev
make -C ../.. edge-authz-image   # build + push to the local registry (part of make up)
```

`repos/platform/edge-authz/base/` is the Deployment, Service and
ServiceAccount; PSA `restricted`, distroless, no token mounted anywhere but
the one informer needs.
