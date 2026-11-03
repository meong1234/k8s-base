# Glossary

> **Who this is for.** Anyone who met a word on another page and wants it
> explained in a few sentences, with where it shows up. Grouped by theme
> rather than alphabetically, because the words come in families.

## Repositories and delivery

**Fleet repo.** `repos/fleet/`. The repository that declares the cluster: the
Flux instance, the platform Kustomizations, and every team. The one file
that lists the teams is `clusters/<env>/teams-inputs.yaml`. Owned by the
platform team.

**Platform repos.** `fleet`, `infra` and `platform`. All signed with the
platform's key and reconciled by the platform's own Flux controllers. `infra`
holds the rules (CRDs, RBAC, admission policies, network baseline);
`platform` holds the shared services (mesh, gateways, Dex, egress, warden).

**Team repo.** `repos/<team>/`. Signed with that team's key, reconciled as
that team's service account, into that team's namespaces and nowhere else.
A set of units under `apps/` and `batch/`, plus a `clusters/<env>/` roster.
Flux renders `./clusters/<env>` of it.

**Reconcile.** What Flux does continuously: compare the cluster with the
source and apply the difference. "The Kustomization is Ready" means the
last reconcile succeeded at the revision it names.

**Kustomization.** A Flux object that says: take this path from that
source, render it, apply it as this service account, and prune what
disappears. Each team has one; the platform has four.

**ResourceSet.** A Flux operator object that renders a template once per
input. The `teams` ResourceSet turns each team's five-line input into
everything the team needs.

**Shard.** One of two sets of Flux controllers. A team's objects carry a
label naming a shard, and that shard does the work. A lane for load, not a
boundary for security; a team moves lanes by changing one word.

**Artifact.** A directory packaged and pushed to an OCI registry, with a
revision annotation. On the laptop it is what the cluster pulls instead of
git; a real environment may use a real registry or git repositories.

**Digest.** The hash that identifies an artifact's exact bytes. Signatures
are on the digest, and promotion moves a tag to a digest.

**Signature.** A cosign signature on an artifact's digest, made with the
owner's private key. The cluster verifies it against one public key per
source, before reading any content.

**Tag.** `:local`, `:dev`, `:prod`. Names an environment, not a version.
Each cluster pulls one tag.

**Promotion.** Retagging a signed digest from one environment's tag to the
next. Nothing is rebuilt. The previous digest is parked as `<tag>-prev` for
rollback.

**`env-check`.** Sixteen offline checks that run before every push. The
mechanism that keeps the base-and-envs boundary and the secret rules
honest without anyone remembering them.

**Smoke.** What a real environment runs instead of the demos: three
assertions, no literals, safe after every promotion.

## Environments

**Unit.** One deployable thing and the objects that belong to it: an app
(`apps/<unit>/`), a batch job (`batch/<unit>/`), an edge (`edges/<edge>/`),
a platform or infra component (`<component>/`). A directory with a `base/`
and an `envs/<env>/` for every environment. Nothing in it refers to
anything outside it.

**Base.** `base/` inside a unit. The reviewed default every environment
inherits. Must build on its own and must contain nothing specific to any one
cluster.

**Envs.** `envs/<env>/` inside a unit. What is true only in that
environment, layered on the unit's `base/` (always its first resource).
States only what it changes; the only place a `*.enc.yaml` may live. If
nothing differs, it is `resources: [../../base]` and nothing else.

**Roster.** A list of what exists in an environment, with no other content.
A repo's `clusters/<env>/kustomization.yaml` is one: one line per unit,
`../../<group>/<unit>/envs/<env>`, and it is what Flux renders. The repo
root lists `clusters/local` so `kustomize build repos/<repo>` renders the
same thing. The partner edge has a second kind of roster, below.

**Cluster variables.** The ConfigMap an environment declares, substituted
into manifests after rendering. Teams see a copy with five keys.

**Tier.** `CLUSTER_TIER`, `dev` here. The one variable that changes
behaviour: what human admins may do, and whether hand-applied objects are
warned or denied.

**Partner roster.** The per-environment list of which partners are live,
in `edges/partner-api/envs/<env>/`. A partner's contract is in the edge's
`base/partners/<name>/`; its presence in an environment is a roster line
beside its encrypted keys.

## Identity and permissions

**Home namespace.** The namespace named after the team, `team-b`. Holds the
team's deployment machinery (service account, Flux source and
Kustomization, injected keys, access requests) and no workloads.

**Workload namespace.** `team-b-apps`, `team-b-batch`. Where the team's pods
run. Stamped with the baseline policies and enrolled in the mesh.

**RBAC.** Kubernetes's permission system: roles list what may be done, and
bindings attach roles to identities per namespace. The floor.

**Tiered roles.** `platform-developer`, `platform-team-admin`,
`platform-operator`, plus the built-in `view`. Aggregated, so each contains
the one below, and bound per namespace by the fleet template.

**Ceiling and floor.** RBAC is the floor: what your role lets you do.
Admission policies are the ceiling: what nobody may do regardless of role. A
grant raises the floor and never touches the ceiling.

**VAP.** `ValidatingAdmissionPolicy`. A rule written in CEL that the API
server evaluates itself on every matching request. No webhook, nothing to
fail open. Thirteen run here.

**PSA.** Pod Security Admission. Built into Kubernetes; `restricted` by
default cluster-wide here. Refuses pods that run as root, escalate
privilege or share host namespaces.

**OIDC.** The login protocol. Dex issues a token; the API server trusts it;
your email is your username and your groups come with it.

**Dex.** The identity provider. Six static users here; a company directory
behind it in a real environment.

**`AccessRequest`.** The custom object you create to ask for a privileged
role for a bounded time. Admission checks it on create and on approve.

**JIT grant.** The `RoleBinding` named `jit-<request>` the warden creates on
approval and deletes at expiry.

**Warden.** The access warden, the one custom controller on the platform.
Turns an approved request into a timed binding. Down means nothing granted
and nothing revoked.

**Four eyes.** Nobody approves their own request. Enforced at admission.

**Break-glass.** A cluster-admin request: one hour, platform operators
only, a second operator to approve, revocable early. The bootstrap
certificate is the other break-glass, and the hand-apply policy
deliberately catches it.

**Bootstrap identity.** The client certificate k3d issued, `system:admin`.
The one identity that existed before Flux, needed to install Flux, and
listed by name in the policies so it is not locked out.

## Network and mesh

**Baseline.** The default-deny `NetworkPolicy` and the same-team
`AuthorizationPolicy` every workload namespace is stamped with. A team may
add rules and may not delete them.

**Cilium.** The CNI. Enforces network policies by namespace and label.
Hubble is its flow viewer and shows every verdict.

**Ambient.** Istio's sidecar-less mode. A node agent, ztunnel, provides mTLS
and identity; an optional per-namespace proxy, a waypoint, provides HTTP
rules.

**ztunnel.** The per-node agent that wraps pod-to-pod connections in mTLS.
Its logs name both identities on every connection.

**HBONE.** The tunnel ztunnel carries traffic in, on port 15008. Cilium
sees only the tunnel, which is why every cross-namespace network policy
names that port.

**SPIFFE identity.** `spiffe://cluster.local/ns/<namespace>/sa/<serviceaccount>`.
What mTLS asserts about a workload and what authorization policies name.

**Waypoint.** An Envoy proxy in front of a Service, stamped when a team's
input says `waypoint: true`. Where method and path rules run. Also, the one
in `platform-egress` that is the only way out of the cluster.

**`istio.io/use-waypoint`.** The Service label that routes traffic through
the waypoint. Without it an `AuthorizationPolicy` targeting the waypoint is
never consulted.

**Allow and depends-on.** The two halves of a cross-team call: the owner's
allow (who may come in, for what) and the caller's depends-on (we go out
there). Both in git, both required, either side can close the path.

## Edges

**Edge.** One of the three namespaces owned by sec-ops: `public-api`,
`partner-api`, `egress-allowlist`. The gateways are the platform's; what
goes through them is sec-ops's.

**Gateway.** A Gateway API object: a listener with a port, a hostname
pattern and a certificate. Platform-owned. Decides which namespaces may
attach routes.

**HTTPRoute.** A Gateway API object: requests matching this host and path
go to that Service. On this platform, sec-ops-owned.

**ReferenceGrant.** The owning team's consent: routes from that namespace may
target my Service. Without it a route does not resolve. The team's veto over
its own exposure.

**Auth class.** The `platform.k8s-base/auth` label on a route: `none`, `jwt`
or `api-key`. Selects which `SecurityPolicy` covers the route. Required by
admission.

**Path prefix.** The first URL segment a team owns on the public host,
allocated in the fleet input under `apiPaths` and enforced by admission.

**`ServiceEntry`.** The Istio object that declares an external host and
steers it to the egress waypoint. One per listed host, paired with an
`AuthorizationPolicy` naming who may use it.

**Passthrough versus terminated.** A 443 entry passes TLS through by server
name and can only be audited by host. An HTTP entry is terminated at the
waypoint, can be re-originated as mutual TLS from a certificate only the
waypoint holds, and can be audited by method and path.

**Consent.** The `ReferenceGrant`, for both the public and the partner door.
