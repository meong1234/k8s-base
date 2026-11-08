# edge-policies — the platform's half of the edge rules

Every Istio custom resource the platform itself attaches to the three ingress
Gateways. It is applied by `platform-config-ks`, the second stage: these
kinds exist only once the `istio-base` chart in the first stage has installed
their CRDs, and kustomize-controller dry-runs a whole revision before applying
any of it.

| File | Object | What it does |
| --- | --- | --- |
| `authz-partner-api-key.yaml` | `AuthorizationPolicy partner-edge-api-key`, `CUSTOM` | every request on the partner Gateway is checked by `edge-authz` before routing |
| `authz-hubble-oidc.yaml` | `AuthorizationPolicy internal-edge-hubble-oidc`, `CUSTOM` | every request for the Hubble host on the internal Gateway is handed to oauth2-proxy, which runs the Dex login |
| `ratelimit-partner-filter.yaml` | `EnvoyFilter partner-edge-ratelimit-filter` | inserts Envoy's local rate limiter on the partner Gateway with no bucket: the slot each partner's own `EnvoyFilter` fills for its hostname |
| `public-identity-header-sanitize.yaml` | `EnvoyFilter public-identity-header-sanitize` | strips `x-user-email` and `x-user-groups` from every request on the public Gateway before the JWT filter writes the verified values |

The two ext_authz providers these policies name (`edge-authz`, `oauth2-proxy`)
are declared in `meshConfig.extensionProviders` in
`repos/platform/istio/base/istiod.yaml`.

## Who owns what in `platform-ingress`

Istio attaches `RequestAuthentication`, `AuthorizationPolicy` and
`EnvoyFilter` to a Gateway only from the Gateway's own namespace. So
`platform-ingress` holds two sets of policy with two owners:

| Owner | Objects | Applied by |
| --- | --- | --- |
| platform | the four above; the Gateways, certificates and class defaults in `repos/platform/ingress/base/` | `platform-ks` / `platform-config-ks` |
| team-sec-ops | `RequestAuthentication public-edge-jwt`, `AuthorizationPolicy public-edge-require-jwt`, `EnvoyFilter public-edge-ratelimit`, `EnvoyFilter <partner>-ratelimit` | the sec-ops Flux identity, under `Role secops-edge-policies` (`repos/platform/ingress/base/rbac-secops-edge-policies.yaml`), which grants exactly those three kinds and nothing else |

The split is the same as before Istio: the platform owns the door, sec-ops
owns the rules on it. What changed is only that the rules now sit in the
door's namespace. `kubectl -n platform-ingress get
requestauthentication,authorizationpolicy,envoyfilter -L platform.k8s-base/team`
shows both sets; Flux stamps the team label on everything sec-ops applies.

## Reading what the proxy actually holds

An `EnvoyFilter` is accepted by the API server whether or not it matches
anything. The checks that matter run against the proxy:

```sh
istioctl proxy-status                                          # every *-istio SYNCED; STALE means a rejected patch
istioctl proxy-config route deploy/partner-istio -n platform-ingress -o json \
  | jq '.[].virtualHosts[] | {name, rl: .typedPerFilterConfig["envoy.filters.http.local_ratelimit"].value.tokenBucket.maxTokens}'
istioctl proxy-config listener deploy/public-istio -n platform-ingress -o json \
  | jq '[.. | objects | select(.name? == "envoy.filters.http.ext_authz" or .name? == "envoy.filters.http.local_ratelimit")] | length'
```

Virtual hosts are named `<hostname>:<listener port>` — `api.local-dev.test:443`,
`partner-a.partners.local-dev.test:9443` — never the laptop's 8443.

## Why the gateways are not ambient, and the one exception for Dex

`platform-ingress` is deliberately not labelled `istio.io/dataplane-mode:
ambient`. A gateway terminates TLS itself, so the plaintext TCP servicelb
forwards into it never meets ztunnel; labelling the namespace would capture
the gateways and the mesh-wide STRICT rule would refuse every connection from
the laptop. The gateways still speak HBONE *outbound* to every ambient
backend with their own identity, which is why the team baseline admits
`platform-ingress` on 15008.

istiod fetches the Dex JWKS for the public edge's `RequestAuthentication`
itself, and istiod is not a mesh workload, so
`repos/platform/mesh-config/base/peer-authentication-dex-jwks.yaml` opens Dex's
port 5556 to plaintext while the rest of Dex stays STRICT. Without it every
JWT on the public edge is a 401 `Jwks remote fetch is failed`.
