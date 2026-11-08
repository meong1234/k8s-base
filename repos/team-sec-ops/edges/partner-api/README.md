# `partner-api` — the partner edge

A named business partner reaches one backend, on its own hostname, with its own
API keys and its own rate limit. Nothing here is on `api.${CLUSTER_DOMAIN}`: the
partner edge is a second Gateway, a second proxy Deployment, a second
certificate and a second port, so a partner flood and a partner
misconfiguration land on the partner proxy only and can never shadow a path on
the public host.

| Party | Object | Where |
| --- | --- | --- |
| platform | `Gateway partner`, one HTTPS listener on 9443 for `*.partners.${CLUSTER_DOMAIN}`, admitting routes only from namespaces labelled `platform.k8s-base/role: partner-edge`; istiod renders its proxy and LoadBalancer Service | `repos/platform/ingress/base/gateway-partner.yaml` |
| platform | `Certificate partners-wildcard`; `AuthorizationPolicy partner-edge-api-key`, which sends every request on the door to the `edge-authz` service; the rate-limit filter slot | `repos/platform/ingress/base/`, `repos/platform/edge-policies/base/`, `repos/platform/edge-authz/` |
| team-sec-ops | one directory per partner under `base/partners/`: the route and the rate limit — the partner's **contract**, the same wherever it is onboarded | `repos/team-sec-ops/edges/partner-api/base/` |
| team-sec-ops | the **roster** and the SOPS-encrypted key Secret, per environment | `repos/team-sec-ops/edges/partner-api/envs/<env>/` |
| the owning team | a `ReferenceGrant` in the backend namespace naming `partner-api` as `from` | `repos/<team>/<ns>/public-consent.yaml` |

The partner name is not registered anywhere else, and the registration is now
two halves: `base/partners/<name>/` declares that the partner *exists*, and a
`resources:` line in `envs/<env>/kustomization.yaml` declares that it is
**live in that environment**. Both are behind CODEOWNERS the way
`edges/public-api/base/routes/` is.

## Why the split falls there

A partner's route and rate limit are its contract, with the one
environment-dependent string already a variable
(`<partner>.partners.${CLUSTER_DOMAIN}`). What differs between environments is
**whether the partner exists here** and **what its keys are**. So a partner live
on `uat` before `prod` is one `resources:` line and one encrypted file, and a
per-environment rate limit would be a `patches:` entry against
`EnvoyFilter/<partner>-ratelimit` in that `envs/<env>/` — never a fork of
`base/`.

Keys are in `envs/<env>/` *and* SOPS-encrypted for two separate reasons: the
values differ per environment, and so does the recipient. No variable could
carry either.

**`base/kustomization.yaml` is deliberately `resources: []`.** A real root there
would be a second answer to "which partners exist", and the only answer is the
`envs/<env>/` roster. The empty root exists only so that `base/` builds like
every other unit's; it renders nothing, and `envs/<env>/kustomization.yaml`
does **not** list `../../base` — it lists `../../base/partners/<partner>`, one
line per live partner. Each `base/partners/<partner>/` is a root and builds
alone.

**An environment with no partners yet** gets `resources: []` in its roster — it
builds clean and renders nothing. The `partner-api` namespace is still stamped by
the fleet `ResourceSet`, and a partner edge with no routes is the correct state
for an environment that has onboarded nobody.

`${CLUSTER_DOMAIN}` is a Flux post-build variable substituted from `ConfigMap
flux-system/cluster-vars` by the `Kustomization` the fleet repo stamps for this
team; on `local` it is `local-dev.test`. The
`<partner>.partners.` part in front of it is the convention and stays literal,
and so does the port: `9443` is a listener, not a URL the environment picks.

## What is in here

| Path | Object | Note |
| --- | --- | --- |
| `base/partners/partner-a/route.yaml` | `HTTPRoute partner-a` | `partner-a.partners.${CLUSTER_DOMAIN}/v1/orders` → `podinfo` in `team-b-apps`, `owner-team: team-b`, `auth: api-key`; strips `x-api-key` before the backend |
| `base/partners/partner-a/ratelimit.yaml` | `EnvoyFilter partner-a-ratelimit` in `platform-ingress` | local rate limit, 100 requests per minute per distinct client address, on the virtual host `partner-a.partners.${CLUSTER_DOMAIN}:9443` only |
| `base/partners/partner-b/*` | the same two objects | 50 requests per minute, so a partner's limit is visibly its own |
| `envs/local/kustomization.yaml` | — | the roster: the `partner-route` label and one `resources:` line per onboarded partner. No `namespace:` transformer, because the rate limits live in `platform-ingress` |
| `envs/local/partner-a-keys.enc.yaml` | `Secret partner-a-keys` | Opaque, one entry per client id (`partner-a-prod`, `partner-a-staging`), SOPS-encrypted to this environment's sec-ops age recipient |
| `envs/local/partner-b-keys.enc.yaml` | `Secret partner-b-keys` | partner-b's own keys |

**The key check is the platform's, the keys are sec-ops's.** Istio has no
API-key primitive, so `AuthorizationPolicy partner-edge-api-key` on the Gateway
(`repos/platform/edge-policies/base/`) sends every request on the door to
`edge-authz`, a small service in `platform-ingress`
(`tools/edge-authz/`). It takes the hostname's first label, reads
`Secret <partner>-keys` in this namespace through a watch, compares the
presented `x-api-key` against every entry in constant time, and answers 200
with the entry's name as `x-partner-id` or an identical 401 for a missing key,
an unknown key, an unknown hostname and another partner's key. The fleet
template grants it read on this namespace's Secrets because the namespace's
role is `partner-edge`. Nothing in a partner directory names the authorizer;
the Secret name is the contract.

**The rate limit attaches to the Gateway, scoped by hostname.** Istio's
`EnvoyFilter` can only attach to the partner Gateway from `platform-ingress`,
so each `ratelimit.yaml` carries that namespace and matches the virtual host
istiod names `<partner>.partners.${CLUSTER_DOMAIN}:9443`. The platform inserts
the rate-limit filter itself with no bucket
(`repos/platform/edge-policies/base/ratelimit-partner-filter.yaml`); a partner
without its own `EnvoyFilter` is not limited at all. The sec-ops Flux identity
holds a Role in `platform-ingress` for exactly this kind.

**Nothing here may be renamed by kustomize, and no `namespace:` transformer
may sit above these files.** The Secret is found by hostname, the rate limit
by virtual-host name, and a rewritten `EnvoyFilter` namespace is accepted by
the API server and ignored by the Gateway. None of these errors; a mis-scoped
rate limit limits nothing. Hence: no `namePrefix`, no `nameSuffix`, no
`secretGenerator`, anywhere in this repo, and `metadata.namespace` on every
object.

## Onboarding a partner

Onboarding a partner is three things: **the base files, a roster line in every
`envs/<env>/` the partner is live in, and the keys in that same `envs/<env>/`.**
Steps 1 and 5 below are those three; the rest is what to put in them.

1. **New directory in `base/`.** `base/partners/<partner>/` with
   `route.yaml`, `ratelimit.yaml` and a `kustomization.yaml` listing both,
   copied from `partner-a` and renamed. Every object is named `<partner>`:
   edge-authz finds the Secret as `<partner>-keys` from the hostname's first
   label, and the rate limit names the virtual host
   `<partner>.partners.${CLUSTER_DOMAIN}:9443`. No `keys.enc.yaml` here — it is
   `envs/<env>/`'s.
2. **Owner team.** `platform.k8s-base/owner-team` is the team that owns the
   **backend** Service, not team-sec-ops. `public-route-owner` checks the
   backend namespace against that label, so a partner route pointing at
   `team-b-apps` must be labelled `team-b`.
3. **Hostname.** Exactly one, exactly `<partner>.partners.${CLUSTER_DOMAIN}`. Four
   labels, first label not `*`: the zone wildcard is the *listener's* hostname
   and is denied on a route, because one route serving two partner hostnames
   would share one key set between two partners.
4. **Auth class.** `platform.k8s-base/auth: api-key`, and only in this
   namespace. `none` and `jwt` belong to `public-api`; admission refuses either
   class on the wrong edge.
5. **Roster line and keys, once per environment the partner goes live in.** In
   `repos/team-sec-ops/edges/partner-api/envs/<env>/kustomization.yaml` add

   ```yaml
   resources:
     - ../../base/partners/<partner>
     - <partner>-keys.enc.yaml
   ```

   and write that `<partner>-keys.enc.yaml` beside it: two client ids per
   partner, random 32-byte values, `namespace: partner-api` in the Secret's own
   metadata.

   ```sh
   openssl rand -hex 32
   make team-sops-encrypt TEAM=team-sec-ops \
     FILE=edges/partner-api/envs/<env>/<partner>-keys.enc.yaml
   ```

   The committed file must contain `ENC[`. The plaintext goes to the partner
   through whatever channel the contract names, never into this repo. The keys
   differ per environment and so does the recipient, which is the whole reason
   they are not in `base/`. Leaving the roster line out of an environment is how
   a partner is *not* onboarded there — the base files are inert on their own.
6. **Rotation is two merges.** edge-authz compares the presented key against
   *every* entry of the Secret and watches it, so merge one adds the new client
   id next to the old one, the partner switches over, and merge two removes the
   old id. There is no window in which neither key works, no restart, and the
   `x-partner-id` the backend sees says which one the caller used.
7. **Rate limit.** Pick the partner's contractual number. It is a local limit,
   so it is per gateway replica (the partner Gateway runs one); a global limit
   needs a rate limit service. It is scoped to the partner by the virtual host
   istiod names `<partner>.partners.${CLUSTER_DOMAIN}:9443`; a typo there
   limits nothing and errors nowhere, so after merging check
   `istioctl proxy-config route deploy/partner-istio -n platform-ingress`.
8. **Consent.** The owning team adds `partner-api` as a second `from` entry in
   its `ReferenceGrant`. Without it the route reports `ResolvedRefs: False` and
   the partner gets a 500.

## What the backend sees

```
x-partner-id: partner-a-prod
```

and no `x-api-key`: the route's `RequestHeaderModifier` removes the credential
after edge-authz has read it, so the key never reaches `team-b-apps` and the
backend authorizes on the client id, which Envoy sets from edge-authz's answer
and overwrites if a client sent one. A key is a partner identity, not a user
identity — the backend must not treat `x-partner-id` as an end user.

## Review checklist

- [ ] One hostname, `<partner>.partners.${CLUSTER_DOMAIN}`.
- [ ] `owner-team` is the backend's team; `auth: api-key`.
- [ ] `parentRefs` is `platform-ingress/partner` with `sectionName: https`.
- [ ] `PathPrefix` plus a `URLRewrite` so the backend serves its own paths.
- [ ] A `RequestHeaderModifier` filter removes `x-api-key`, so the credential
      stops at the edge.
- [ ] `<partner>-keys.enc.yaml` contains `ENC[` and the client ids are prefixed
      with the partner name.
- [ ] An `EnvoyFilter <partner>-ratelimit` exists with the contractual number,
      `namespace: platform-ingress`, and its `vhost.name` is exactly
      `<partner>.partners.${CLUSTER_DOMAIN}:9443`.
- [ ] The owning team's `ReferenceGrant` lists `partner-api`.
- [ ] **Roster and keys agree.** Every `base/partners/<partner>` path in an
      `envs/<env>/` `resources:` has a `<partner>-keys.enc.yaml` beside it, and every
      `*-keys.enc.yaml` has a roster line. A key with no route is dead weight; a
      route with no key is a hostname edge-authz answers 401 for.
- [ ] **Nothing new in `base/` that is environment-specific**, and no
      `*.enc.yaml` in `base/` at all.

## Validation without a cluster

```sh
kustomize build repos/team-sec-ops/edges/partner-api/envs/local   # the roster, keys included
kustomize build repos/team-sec-ops/edges/partner-api/base/partners/partner-a
kubeconform -ignore-missing-schemas $(find repos/team-sec-ops/edges/partner-api -name '*.yaml')
```

`kustomize build repos/team-sec-ops/edges/partner-api/base` succeeds and prints
nothing — that is the empty root doing its job, not a check that failed.

## The partner's client certificate is the platform's slot, not a file here

A partner that demands mutual TLS outbound is served by a `DestinationRule` in
`egress-allowlist` whose `credentialName` names a Secret — but that Secret lives
in `platform-egress` and is **platform-owned**. It is not a sec-ops file in any
environment: sec-ops holds nothing in `platform-egress` and could not apply it,
the content is the client half of a certificate the *partner* issued rather than
configuration anyone here writes, and moving it would widen sec-ops RBAC into a
platform namespace.

The slot has the same shape everywhere — `Secret <partner>-client`, type
`kubernetes.io/tls`, keys `tls.crt`, `tls.key`, `ca.crt`, in `platform-egress`,
named by the `credentialName` sec-ops writes:

| | Who fills it | With what |
| --- | --- | --- |
| `local` | `make partner-sim-inject` | `$(KEYS_DIR)/partner-bank/{ca,server,client}.{crt,key}`, minted by `make partner-sim-keys` from a throw-away CA — git-ignored and staying so |
| a real environment | devops, through the platform repo: a SOPS Secret at `repos/platform/egress/envs/<env>/<partner>-client.enc.yaml`, or an `ExternalSecret` where that environment has a store | encrypted to that environment's platform recipient, so a prod credential cannot decrypt on dev |

Devops owns the file because it owns the repo; **sec-ops is the second
reviewer**, because sec-ops owns the `DestinationRule` whose `credentialName`
names it. A credential that is missing or unreadable is the silent `WARMING`
state `repos/platform/egress/README.md` warns about — no error on any
Istio object, just a handshake that never happens.
