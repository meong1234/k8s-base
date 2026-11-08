# What we use

> **Who this is for.** Anyone who wants to know what the platform is made of
> before reading how it fits together, and anyone upgrading a component.
> **Afterwards you can** name every moving part, its version, the job it
> does here, and the file that pins it.

Everything on this page is pinned in the repo. The version column is what
runs on the laptop cluster today; the last column is where to change it.
When one of these is bumped, that file is the only place to edit, and
`make up` or `make push` does the rest.

## The cluster itself

| Component | Version | What it does here | Pinned in |
| --- | --- | --- | --- |
| k3d | installed via Homebrew | runs a k3s cluster inside Docker: one server, two agents, a load balancer, a registry | `k3d/cluster.yaml` |
| k3s | v1.35.5 | the Kubernetes distribution, with its bundled CNI and network policy disabled so Cilium can take over | `k3d/cluster.yaml` |
| Pod Security Admission | built into k3s | `restricted` by default in every namespace except `kube-system` | `k3d/admission.yaml` |
| API server audit | built into k3s | records privileged sessions, RBAC and access-request writes, and every write in a team namespace | `k3d/audit-policy.yaml` |
| Structured authentication | built into k3s | trusts Dex as an OIDC issuer; rendered from the identity roster at `make up` | `k3d/authn.yaml.tmpl` |
| ValidatingAdmissionPolicy | built into k3s | the thirteen rules that form the admission ceiling | `repos/infra/policies/base/` |

## Networking and mesh

| Component | Version | What it does here | Pinned in |
| --- | --- | --- | --- |
| Cilium | 1.20.4 | the CNI; enforces every `NetworkPolicy` and the two cluster-wide rules | `k3d/cilium-helmchart.yaml`, `scripts/images.mk` |
| Hubble (relay and UI) | 1.20.4, UI 0.13.6 | shows every flow and its verdict; the UI is behind the internal gateway with login | same |
| Istio, ambient mode | 1.31.4 | ztunnel on every node for mTLS and identity; istiod; waypoints where a team opts in; the egress waypoint; and the three ingress Gateways (public, internal, partner), rendered by istiod from Gateway API objects. `RequestAuthentication` and `AuthorizationPolicy` do JWT and the fail-closed edge, `EnvoyFilter` the rate limits | `repos/platform/istio/base/`, `repos/platform/ingress/base/`, `repos/platform/edge-policies/base/`, `scripts/images.mk` |
| Gateway API CRDs | v1.6.0, experimental channel | the `Gateway`, `HTTPRoute` and `ReferenceGrant` kinds, for the ingress Gateways and the waypoints alike | `repos/infra/crds/base/gateway-api/` |
| edge-authz | built from `tools/edge-authz/`, Go 1.26, client-go v0.37.0 | the partner API-key check as an Envoy ext_authz service: reads the partner key Secrets, answers 200 with `x-partner-id` or 401 | `tools/edge-authz/`, `repos/platform/edge-authz/base/` |
| oauth2-proxy | v7.15.6 | the Hubble UI login as an ext_authz service: runs the Dex authorization-code flow and holds the session cookie | `repos/platform/identity/base/oauth2-proxy.yaml`, `scripts/images.mk` |
| cert-manager | v1.21.3 | issues the wildcard certificates for the three gateways from the local CA | `repos/infra/cert-manager/base/`, `repos/infra/issuers/envs/local/` |

## Delivery

| Component | Version | What it does here | Pinned in |
| --- | --- | --- | --- |
| Flux | 2.10.x (source v1.10.1, kustomize v1.10.1, helm v1.7.1, notification v1.10.0) | pulls artifacts, renders, applies as each team's service account, in two shards | `repos/fleet/base/flux-system/flux-instance.yaml`, `scripts/images.mk` |
| Flux operator | v0.62.1 | installs and manages Flux from a `FluxInstance`; provides the `ResourceSet` that stamps teams | `scripts/fluxcd.mk` |
| flux CLI | via Homebrew tap | `flux push artifact`, `flux tag artifact`, and inspection | `scripts/setup.mk` |
| kustomize | via Homebrew | renders every root; a unit's `base/` plus its `envs/<env>/`, listed by a `clusters/<env>/` roster | `scripts/setup.mk` |
| cosign | 3.x via Homebrew | signs each artifact's digest and verifies it; the cluster side is Flux's `verify` block | `scripts/artifacts.mk` |
| SOPS and age | via Homebrew | encrypt Secret values in git to a per-team, per-environment key; Flux decrypts on apply | `scripts/teams.mk`, each repo's `.sops.yaml` |
| kubeconform | via Homebrew | schema-checks manifests offline | `scripts/setup.mk` |
| The local registry | k3d's registry image | holds the eight signed artifacts and a mirror of every image the cluster needs, so the cluster never pulls from the internet | `scripts/k8s.mk`, `scripts/images.mk` |

## Identity and access

| Component | Version | What it does here | Pinned in |
| --- | --- | --- | --- |
| Dex | v2.46.1 (chart 0.26.0) | the OIDC identity provider; six static users here, a company directory behind it for real | `repos/platform/identity/base/`, `repos/platform/identity/envs/local/` |
| kubelogin | via Homebrew tap | the `kubectl` credential plugin that logs in through Dex and caches the token | `scripts/identity.mk` |
| access-warden | built from `tools/warden/`, Go 1.26, controller-runtime v0.25.2, client-go v0.37.0 | the custom controller: turns an approved `AccessRequest` into a timed role binding | `tools/warden/go.mod`, `tools/warden/Dockerfile`, `repos/platform/access-warden/base/` |
| dexproxy | same Go module | a tiny loopback proxy that stands in for the `/etc/hosts` line on laptops without root | `tools/warden/cmd/dexproxy/`, `scripts/identity.mk` |
| controller-gen | v0.23.0 | regenerates the `AccessRequest` CRD and deep-copy code from the Go types | `tools/warden/Makefile` |

## Workloads and demo fixtures

| Component | Version | What it does here | Pinned in |
| --- | --- | --- | --- |
| podinfo | image 6.17.0 on `local`, 6.16.0 in `base/`; chart `6.x` from the platform catalog | the stand-in service every team runs | `repos/<team>/apps/podinfo/base/`, `repos/<team>/apps/podinfo/envs/local/`, `repos/fleet/base/teams.yaml` |
| busybox | 1.37 | the one curated `kubectl debug` image, and small probe pods | `scripts/images.mk`, `repos/infra/policies/base/params.yaml` |
| curl | 8.11.1 | the caller pods and egress probes | `scripts/images.mk` |
| nginx | 1.29-alpine | the simulated partner that demands a client certificate, outside the cluster | `sim/partner-bank/`, `scripts/partner.mk` |

## Laptop tools

Installed with `make brew-setup-all` and checked with `make tools-check`:
k3d, kubectl, kustomize, flux, helm, istioctl, cosign, sops, age, cilium-cli,
hubble, jq, yq, kubeconform, kubelogin. Plus `htpasswd` and `openssl`, which
macOS ships, and Go only if you rebuild the warden, edge-authz or the login
proxy.

## How the pieces depend on each other

```
   k3d + k3s ──▶ Cilium (CNI; nothing schedules before it)
                   │
                   ├──▶ Flux operator ──▶ Flux (two shards) ──▶ pulls the signed artifacts
                   │                                               │
                   │          ┌────────────────────────────────────┤
                   │          ▼                                    ▼
                   │     infra: CRDs (Gateway API,                 platform: Istio ambient and the three
                   │            AccessRequest), RBAC, policies,    Gateways it renders, Dex, oauth2-proxy,
                   │            network baseline, cert-manager     the egress waypoint, edge-authz, warden
                   │          │                                    │
                   │          └──── cert-manager issues ───▶ gateway certificates
                   │                                               │
                   └──────────────────────▶ teams ResourceSet ────▶ team namespaces, each pulling
                                                                    its own signed artifact
   on the laptop:  cosign signs what flux push publishes; sops/age encrypt what the teams commit;
                   kubelogin logs humans in through Dex; the registry mirrors every image above
```

The order matters at bootstrap and is the same chain the
[big picture](03-the-big-picture.md) page walks: nothing schedules before
Cilium, nothing reconciles before Flux, no custom resource applies before
the chart that installs its CRD, and no team exists before the platform
services it depends on are Ready.

## Where the detail lives

- Every image the cluster needs, with its exact tag and why: `scripts/images.mk`
- The Flux distribution and shard layout: `repos/fleet/base/flux-system/flux-instance.yaml`
- Each Helm chart's values and the reasons for them: the `helmrelease.yaml` next to each component
