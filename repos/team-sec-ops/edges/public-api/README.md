# `public-api` — the company's public edge

Everything the internet can reach goes through an `HTTPRoute` in this namespace.
`team-sec-ops` owns the namespace; this repo is pushed as the OCI artifact
`team-sec-ops:local`, signed with the sec-ops cosign key, and reconciled into
`public-api` by that team's `flux` ServiceAccount.

Four parties must agree before a service is public, and removing any one of them
takes it offline:

| Party | Object | Where |
| --- | --- | --- |
| platform | `Gateway public`, whose single HTTPS listener admits routes only from namespaces labelled `platform.k8s-base/role: public-edge` | `repos/platform/ingress/base/` |
| team-sec-ops | the `HTTPRoute` in `public-api`, plus the edge policies below | this unit, `repos/team-sec-ops/edges/public-api/base/` |
| platform (again) | the path prefix the route claims, allocated in the fleet repo's `teams.yaml` (`apiPaths`) and rendered into `ConfigMap flux-system/api-paths-<team>` | `repos/fleet/clusters/local/` |
| the owning team | a `ReferenceGrant` naming the Service the route targets | `repos/<team>/<ns>/public-consent.yaml` |

Without the `ReferenceGrant` the route reports `ResolvedRefs: False` and the edge
serves 500. Without the route there is no hostname. Without the label on this
namespace the Gateway refuses the route altogether.

## This whole edge is in `base/`

Every edge in `repos/team-sec-ops/` is a unit, `base/` + `envs/<env>/`, and the
public edge is entirely in `base/`: it is the same in every environment.
`envs/local/kustomization.yaml` is the trivial `resources: [../../base]` and
nothing more. There is no roster here and
nothing per-environment — one public host, and each team's API a path prefix on
it that the platform allocated in `teams-inputs.yaml`. The route set *does*
differ between environments in the sense that a team may not exist on all of
them, but that is not expressed by an overlay: a route whose backend is absent
reports `ResolvedRefs: False` and the edge serves a 503, which is a louder
signal than a route that quietly is not there. Reviewing an environment's
`teams-inputs.yaml` against `base/routes/` is the control, not a per-env patch.

`base/` is a root and builds alone, and so is `envs/local/`. The repo's roster
(`repos/team-sec-ops/clusters/local/kustomization.yaml`) names `envs/local`,
and the Flux `Kustomization` reads that roster.

`${CLUSTER_DOMAIN}` and `${PUBLIC_PORT}` in this directory and below are Flux
post-build variables, not strings a reviewer invents: the `Kustomization` the
fleet repo stamps for this team substitutes them from `ConfigMap
flux-system/cluster-vars`, where the environment declares its own zone and
browser-facing port. On `local` they resolve to
`local-dev.test` and `8443`. The prefix in front of the zone — `api.`, `dex.`,
`*.` — is a platform convention and stays literal in the manifest.

## What is in here

| Path | Object | Note |
| --- | --- | --- |
| `base/routes/team-a-podinfo.yaml` | `HTTPRoute team-a-podinfo` | `api.${CLUSTER_DOMAIN}/podinfo` → `podinfo` in `team-a-apps`, `auth: none`; arrived as a PR from team-a |
| `base/routes/team-a-catalog.yaml` | `HTTPRoute team-a-catalog` | `api.${CLUSTER_DOMAIN}/catalog` → the same Service, `auth: jwt` |
| `base/routes/team-b-orders.yaml` | `HTTPRoute team-b-orders` | `api.${CLUSTER_DOMAIN}/orders` → `podinfo` in `team-b-apps`, `auth: jwt` |
| `base/routes/platform-dex.yaml` | `HTTPRoute platform-dex` | `dex.${CLUSTER_DOMAIN}` → `dex` in `platform-identity`; arrived as a PR from the platform team. `platform-identity` is the one namespace in `publicBackendNamespaces` |
| `base/routes/https-redirect.yaml` | `HTTPRoute https-redirect` | the `http` listener's only route: 301 to `https` on `${PUBLIC_PORT}`. No backend, so `public-route-owner` lets it keep the `*.${CLUSTER_DOMAIN}` wildcard |
| `base/edge-policies/request-authentication.yaml` | `RequestAuthentication public-edge-jwt` in `platform-ingress` | the Dex JWT provider on the public Gateway: `aud: public-api`, JWKS fetched by istiod from `dex.platform-identity.svc:5556`, `email` and `groups` forwarded as `x-user-email` and `x-user-groups` |
| `base/edge-policies/authorization-require-jwt.yaml` | `AuthorizationPolicy public-edge-require-jwt` in `platform-ingress` | `DENY` every request on `api.${CLUSTER_DOMAIN}` port 443 without a verified token, except the `notPaths` prefixes (the open ones) and `OPTIONS` preflights |
| `base/edge-policies/ratelimit.yaml` | `EnvoyFilter public-edge-ratelimit` in `platform-ingress` | local rate limit, 20 requests per minute per distinct client address, draft-03 `x-ratelimit-*` headers, across the whole Gateway |

**The policies live next to the Gateway, not next to the routes.** Istio
attaches `RequestAuthentication`, `AuthorizationPolicy` and `EnvoyFilter` to a
Gateway only from the Gateway's own namespace, so the three files above carry
`namespace: platform-ingress` and this unit's `kustomization.yaml` has no
`namespace:` transformer — it would rewrite them to `public-api`, where they
are accepted and attach to nothing. The sec-ops Flux identity holds a Role in
`platform-ingress` for exactly those three kinds
(`repos/platform/ingress/base/rbac-secops-edge-policies.yaml`). The platform
owns the door; sec-ops owns the rules on it; a team can write neither.

**A route is covered the moment it is merged, by construction rather than by
label.** The rate limit is Gateway-wide. The DENY policy is fail-closed: every
prefix on the public host needs a token unless it is listed in `notPaths`, so
a new `jwt` route is secured with no edit anywhere, and a new `none` route is
*closed* until its prefix is added to `notPaths` — the `auth` label on the
route and the `notPaths` entry are reviewed together. CORS is the one thing a
Gateway-scoped policy cannot express, so it is a Gateway API `CORS` filter on
every route that reaches a backend, and `public-route-owner` refuses a route
without one. The `platform.k8s-base/public-route` label the kustomization
stamps is for the operator (`kubectl get httproute -l`), not for attachment.

**The security response headers are a route filter, not a policy.** The first
version put them in a Gateway-scoped response override, which on a running
proxy replaced the response body with an empty one and dropped `Content-Type`.
They are a `ResponseHeaderModifier` filter on each route, like CORS: still
sec-ops-owned, still unweakenable by a team, one attachment level further
down; the cost is that a new route needs both filters copied in, so they are
on the checklist.

## The real flow

In a company repo this directory is behind CODEOWNERS:

```
/edges/public-api/base/routes/   @company/sec-ops
/edges/public-api/base/edge-policies/ @company/sec-ops
```

1. The owning team opens a PR adding one file under `base/routes/`, and a second PR
   against its own repo adding the `ReferenceGrant`.
2. Sec-ops reviews against the checklist below and merges. CI pushes and signs
   the artifact with the sec-ops key.
3. Flux reconciles. The route only resolves once the team's own PR has merged
   too.

Locally the PR is simulated by editing `base/` and running
`make push REPO=team-sec-ops`. The signature **is** the approval: a team that
edits this repo on its laptop and runs `make push REPO=team-sec-ops SIGN_AS=team-a`
produces an artifact the `team-sec-ops` `OCIRepository` refuses with
`SourceVerified: False`, because it is pinned to the sec-ops public key.

## Review checklist

Before merging a file under `base/routes/`:

- [ ] **Owner label.** `metadata.labels['platform.k8s-base/owner-team']` names the
      team that owns the backend. `public-route-owner` denies a route without it.
- [ ] **Hostname is `api.${CLUSTER_DOMAIN}`.** There is one public host and every
      team API is a path prefix on it. A single-label hostname
      (`dex.${CLUSTER_DOMAIN}`) is only acceptable for a platform backend, and
      `*.${CLUSTER_DOMAIN}` only for a route that has no backend and only redirects
      — `public-route-owner` enforces both.
- [ ] **Path prefix belongs to the owner.** The first segment of every
      `PathPrefix` — and every rule must have one — is a prefix the platform
      allocated to the owner team in the fleet repo's `teams.yaml` (`apiPaths`).
      `api-path-owner` denies anything else, including an `Exact` path and a rule
      with no `matches`. Check the allocation, not the PR's word:
      `kubectl -n flux-system get cm -l platform.k8s-base/registry=api-paths -o yaml`.
      A new prefix is a PR against the fleet repo, reviewed by the platform team.
- [ ] **Prefix is stripped.** A `URLRewrite` filter with
      `ReplacePrefixMatch: /` so the backend serves its own paths and does not
      have to know its public prefix.
- [ ] **Auth class declared.** `metadata.labels['platform.k8s-base/auth']` is
      `none` for an open API or `jwt` for one behind a Dex token.
      `public-route-owner` denies a route without it. `api-key` belongs to the
      partner edge and is denied here.
      `jwt` needs no other edit: every request on the host must carry
      `Authorization: Bearer <id_token>` issued by Dex for the **`public-api`**
      client, or the edge answers before the backend is consulted — **403**
      `RBAC: access denied` with no token (the DENY policy), **401** with a token
      it cannot verify (the JWT filter), and **403** again with a token it
      verified but that was minted for another client, a developer's
      `kubernetes` kubelogin token included, because the provider pins
      `audiences: [public-api]`; that 403 carries `www-authenticate: …
      error="invalid_token"`, which the no-token 403 does not.
      `none` needs the prefix added to `notPaths` in
      `base/edge-policies/authorization-require-jwt.yaml`, as the client sends
      it (`/podinfo` and `/podinfo/*`); until then the route is live and closed.
      The label and the `notPaths` entry are one review.
      The verified `email` and `groups` claims arrive at the backend as
      `x-user-email` and `x-user-groups`, so a secured API reads its caller from
      a header and never parses a token; a client cannot pre-set either, because
      the Gateway strips both before the JWT filter writes them. Dex's local
      connector emits no `groups` claim for a static password, so on this
      cluster only `x-user-email` arrives; a missing claim is an omitted header,
      not an error. Mint one for the demo users with
      `make api-token USER=carol@team-b.local PASS=carol-local-dev`
      (`make login-help` lists the passwords); it is valid for 10 minutes.
- [ ] **Backend belongs to the owner.** Every `backendRefs` namespace is the owner
      team's, or one of the namespaces the platform opened for public backends
      (`platform-identity`, for Dex). Reserved prefixes — `platform-`, `flux-`,
      `kube-`, `istio-`, `cert-manager` — are denied by admission even with the
      right label.
- [ ] **Consent exists.** A `ReferenceGrant` in the backend namespace names this
      namespace as `from` and that Service as `to`. Check the team's PR, not
      their word:
      `kubectl -n <backend-ns> get referencegrant -o yaml`.
- [ ] **CORS filter present.** Every rule with `backendRefs` carries the
      `type: CORS` filter, copied from an existing route; `public-route-owner`
      denies the route without it. The redirect-only route is exempt.
- [ ] **Security headers present.** The `ResponseHeaderModifier` filter, copied
      from an existing route.
- [ ] **parentRef is the `public` Gateway with `sectionName: https`.** A route
      without a `sectionName` also attaches to the `http` listener and would be
      served in plaintext.
- [ ] **No path or header rewrite that widens the backend.** A public route
      exposes exactly the paths the PR describes.

## Validation without a cluster

```sh
kustomize build repos/team-sec-ops/edges/public-api/base
kustomize build repos/team-sec-ops/edges/public-api/envs/local   # identical output
kubeconform -ignore-missing-schemas $(find repos/team-sec-ops/edges/public-api -name '*.yaml')
```
