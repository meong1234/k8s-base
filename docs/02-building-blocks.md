# Building blocks

> **Who this is for.** Anyone who has used Kubernetes a little and is about to
> meet a lot of names at once: Flux, OCI artifacts, cosign, SOPS, Cilium,
> Istio ambient, Gateway API, admission policies, Dex.
> **Afterwards you can** read any other page here without stopping to look
> up what a word means, and say for each technology why this platform picked
> it.

You do not need to be an expert in any of these. You need a working picture
of what each one does and which question it answers. That is what this page
gives you, one block at a time, in the order you will meet them.

## Namespaces, and who owns them

A Kubernetes namespace is a named compartment. Objects live in exactly one
namespace, and permissions are granted per namespace. That is the whole
basis of multi-tenancy here: every team gets its own namespaces, and every
permission the team has is scoped to them.

On this platform each team has a *home* namespace named after the team
(`team-b`) and one or more *workload* namespaces named with the team as a
prefix (`team-b-apps`, `team-b-batch`). Workloads run in the workload
namespaces. The home namespace holds the team's deployment machinery and
nothing that serves traffic. Keeping them apart means a compromised workload
cannot reach the objects that deploy it.

## Flux: the controller that applies git

Flux is a set of controllers that run inside the cluster and continuously
make the cluster match a source. You tell it "here is a source and here is a
path inside it"; it fetches the content, renders it, applies it, and then
keeps checking. If someone changes an object by hand, Flux puts it back. If
the source changes, Flux applies the change. This loop is called
*reconciling*, and you will see the word everywhere.

```
                ┌──────────────────────────────────────────────────────┐
                │                                                      ▼
   source ──fetch──▶ render (kustomize, variables, decrypt) ──▶ apply as the team's SA ──▶ cluster
   (registry/git)                                                      │
                ▲                                                      │
                └────────────── again at every interval ───────────────┘

   someone edits the cluster by hand  ──▶ next pass puts it back
   the source changes                 ──▶ next pass applies it
   an object is removed from source   ──▶ next pass deletes it (prune)
```

Two Flux objects matter for you:

- A **source** says where content comes from. On this platform every source
  is an `OCIRepository`, explained next.
- A **Kustomization** says what to do with it: which path to render, which
  identity to apply as, and whether to delete objects that disappear from
  the source (`prune`).

The one thing to really absorb is that a Kustomization applies **as a
service account you choose**. Team-b's Kustomization applies as
`system:serviceaccount:team-b:flux`. That service account has permissions
only in team-b's namespaces. So when team-b's repo accidentally contains an
object for `team-a-apps`, Flux tries to apply it as team-b's identity, the
API server says `forbidden`, and the Kustomization reports the error. Nothing
custom is involved; it is Kubernetes permissions doing their ordinary job.

Flux can also run several copies of its controllers, called *shards*. Each
team's objects carry a label naming a shard, and that shard's controllers do
the work. Think of a shard as a lane, not a wall: it spreads load and limits
how much one busy team can slow the others, and a team can be moved between
lanes by changing one word.

The platform installs Flux through the *Flux operator*, which adds one more
object you will meet: a **ResourceSet**. A ResourceSet is a template plus a
list of inputs; it renders the template once per input. The platform has one
ResourceSet, `teams`, whose inputs are the list of teams. Everything a team
needs (namespaces, service account, role bindings, Flux source and
Kustomization, baseline network policies) is stamped from that single
template. Onboarding a team is adding an input.

## OCI artifacts: publishing a directory as a package

OCI is the standard behind container images and the registries that store
them. The same registries can store arbitrary files, and Flux can push a
directory of manifests to a registry as an *artifact* and later pull it
back. That is how every repository reaches the cluster on this laptop:
there is no git server here, so `make push` turns the working tree of
`repos/team-b/` into `oci://registry/team-b:local` in a local registry, and
Flux pulls from that.

Flux can also read git directly, and the fleet repo is written so that it
could: Kustomizations refer to their source by *name*, and for the platform
sources the kind is a cluster variable (`SOURCE_KIND`). A real environment
can point those names at a real registry that CI publishes to, or at real
git repositories. The local registry is the laptop's stand-in for whichever
a company chooses.

The OCI route is the default for a few reasons worth knowing:

- A registry pull needs only a read token for the registry. The cluster
  never holds git credentials.
- A git branch can be force-pushed and rewritten. An artifact's content is
  identified by a digest, a hash of its bytes, and the digest the cluster
  verified is the digest it applies.
- Promoting content from one environment to the next becomes a retag of the
  same digest. Nothing is rebuilt, so what passed in `dev` is byte-for-byte
  what reaches `prod`.

The artifact carries a *revision* annotation computed from the file contents,
so Flux can report "I applied revision `local@sha1:3f9c…`" and a reviewer can
tie that to a tree.

The tag (`:local`, `:dev`, `:prod`) names an environment. Each cluster is
configured to pull one tag. That is a key idea on this platform and it has
its own page later.

## cosign: a signature on the artifact

cosign is a tool for signing things stored in OCI registries. After `make
push` uploads the artifact, it signs the artifact's digest with the owner's
private key. The signature is stored in the registry next to the artifact.

```
   laptop                              registry                          cluster
   ──────                              ────────                          ───────
   repos/team-b/ ──flux push──▶  team-b:local ──▶ digest sha256:ab12…
                                       │
   .keys/cosign/team-b/cosign.key ─────┴─cosign sign──▶ signature, stored beside the digest

                                                          OCIRepository team-b-source
                                                            pulls :local, finds sha256:ab12…
                                                            verifies the signature with
                                                            Secret cosign-pub (team-b's public key)
                                                              match ──▶ read the content
                                                              no match ──▶ SourceVerified=False, stop
```

Each team has its own key pair; the platform repos share one; the security
team has its own. The cluster side is a `verify` block on each Flux source
naming a Secret that holds exactly one public key. Before Flux reads a single
byte of content, it checks that the artifact's signature matches that key.
If not, the source reports `SourceVerified: False` and nothing proceeds.

This is the mechanism behind "a signature is an approval". The security team
owns the public edge repo; only their key can sign it; so the only way for a
team's route to go live is for the security team to merge and push it. A
team that copies the repo and pushes it themselves produces an artifact the
cluster refuses. There is no second mechanism and no exception.

## SOPS and age: secrets that are safe in git

A Kubernetes Secret manifest is just YAML with base64 values, which is not
encryption. Committing one to git leaks it. SOPS is a tool that encrypts the
values inside a YAML file while leaving the structure readable, so `kind:
Secret` and `metadata.name` stay in clear text and only the data is
ciphertext. age is the encryption scheme it uses here, a small modern
public-key system.

```
   laptop                             git                              cluster
   ──────                             ───                              ───────
   db.enc.yaml (plain)                db.enc.yaml                      Secret db
     stringData:                        stringData:                      password: s3cret
       password: s3cret   ─encrypt─▶      password: ENC[AES256…]  ─push─▶
                                        sops: {age: age1q…}       Flux decrypts with
   needs: team's age PUBLIC key                                    Secret sops-age (age PRIVATE key,
   (in .sops.yaml, anyone has it)     readable kind/name/metadata   injected by the platform, never in git)
```

The flow: each team has an age key pair. The public half is in the team's
`.sops.yaml`, so anyone on the team can encrypt a new secret. The private
half exists only inside the cluster, in the team's home namespace, injected
by the platform. Flux decrypts on apply. Nobody on the team can decrypt what
is already committed from their laptop, and that is intentional: the repo is
a one-way channel for secrets into the cluster.

A repository check refuses any Secret under `repos/` that is not encrypted,
so this cannot be forgotten.

## Cilium: the network, and policies about it

Cilium is the CNI, the component that gives pods their network. It also
enforces `NetworkPolicy`: rules about which pods may talk to which, by
namespace and label. Its observability tool, Hubble, shows every flow and
whether it was forwarded or dropped, which makes "why can't my pod reach X"
answerable in one command.

Every workload namespace on this platform gets a default-deny policy: no
inbound, no outbound, except a short list (the team's own namespaces, DNS,
and the egress proxy). Anything else is dropped before it leaves the pod.
When you see `EGRESS DENIED` in Hubble, that is this policy on the caller's
side saying nobody declared this destination.

## Istio ambient: identity and encryption between pods

A service mesh adds a layer between pods that handles encryption,
identity, and fine-grained authorization. Classic Istio does this by
injecting a proxy container, a sidecar, into every pod. Ambient mode does it
without touching the pod: an agent on each node called **ztunnel**
transparently wraps every pod-to-pod connection in mutual TLS, and each
side proves its identity with a certificate that encodes the pod's namespace
and service account. That identity is written as
`spiffe://cluster.local/ns/team-b-apps/sa/orders` and is what authorization
rules name.

```
   pod A (team-b-apps)                                             pod B (team-a-apps)
     │                                                                   ▲
     │  1. Cilium: may namespace team-b-apps reach team-a-apps?          │   NetworkPolicy, port 15008
     │     no ──▶ packet dropped, Hubble shows EGRESS DENIED             │
     │                                                                   │
     ├──── ztunnel ══ HBONE tunnel, mTLS, identity A ⇄ identity B ══ ztunnel
     │                                                                   │
     │  2. waypoint (if B has one): may identity A do GET /api/info?     │   AuthorizationPolicy
     │     no ──▶ HTTP 403 RBAC: access denied                           │
     ▼                                                                   │
```

Two consequences shape everything on the network pages:

- ztunnel carries the traffic through its own tunnel, called HBONE, on
  port **15008**. Cilium sees the tunnel, not the application port. So every
  network policy that allows cross-namespace traffic names 15008, and the
  application port is enforced inside the mesh where it is visible.
- Where a namespace needs rules about HTTP methods and paths, not just
  identities, the platform adds a **waypoint**: a small Envoy proxy in front
  of a Service. "team-b's `orders` service account may `GET /api/info` and
  nothing else" is a waypoint rule.

The platform also runs one special waypoint that is the only way out of the
cluster to the internet. Every outbound call goes through it, it carries only
listed hosts, and its log names the caller by that SPIFFE identity.

## Gateway API on Istio: traffic coming in

Gateway API is the Kubernetes standard for describing inbound traffic. A
`Gateway` is a listener (a port, a hostname pattern, a certificate), and an
`HTTPRoute` says "requests matching this host and path go to that Service".
Istio is the implementation: istiod renders each `Gateway` into a running
Envoy Deployment, the same way it renders a waypoint, so the doors and the
mesh share one control plane.

Three objects from this family show up constantly:

- The **Gateway**, owned by the platform, which decides which namespaces are
  allowed to attach routes to it.
- The **HTTPRoute**, owned by the security team, which names a backend
  Service in a team's namespace.
- The **ReferenceGrant**, owned by the team, which says "routes from that
  namespace may target my Service". Without it the route does not resolve.
  This is how the owning team keeps a veto over its own exposure.

Istio's own policy objects do the rest, attached to the Gateway from its
namespace: a `RequestAuthentication` validates JWTs, an `AuthorizationPolicy`
demands one (or, as `CUSTOM`, hands the request to an external authorizer:
the partner API-key check and the Hubble UI login), and an `EnvoyFilter`
carries the rate limit Istio has no API of its own for. CORS is a filter on
the route. Because the policies attach to the door rather than to a route,
a new route is covered by default: the JWT policy is fail-closed and the
rate limit is Gateway-wide.

## ValidatingAdmissionPolicy: rules the API server enforces itself

Every request to the Kubernetes API passes through *admission* before it is
stored. Historically custom admission rules needed a webhook: a separate
service the API server calls out to, which has to be kept running and which
can fail open. Kubernetes now has `ValidatingAdmissionPolicy`, where the rule
is written in a small expression language called CEL and the API server
evaluates it in-process. No extra component, nothing to be unavailable.

```
   ┌──────────────── the ceiling: admission policies, Pod Security ────────────────┐
   │  exec into a forbidden namespace · image from an unknown registry · a route   │  applies to
   │  without an owner · a hand-made binding to a privileged role · a root pod     │  everyone,
   │                                                                               │  even cluster-admin
   │          ▲                                                                    │
   │          │  a just-in-time grant raises your floor for an hour, then lowers it│
   │          │                                                                    │
   └──────────┴───── the floor: your RBAC role (dev · admin · viewer · operator) ──┘
```

This platform has thirteen of them. They are the "ceiling" from the previous
page: things forbidden for every identity. A few examples of what they say:

- a pod in a team namespace may only use images from an allow-listed registry
- a route on the public edge must carry an owner label and an auth class,
  and may only claim URL prefixes allocated to that owner
- nobody may create a role binding to the debug role except the access
  warden, and only in the shape it uses
- nobody may `exec` into a namespace labelled as forbidding it

Each policy has `failurePolicy: Fail`, so an error in evaluation denies
rather than allows. The denial messages are written to tell you what to do
instead, which you will appreciate the first time you hit one.

Alongside them, **Pod Security Admission** is on, cluster-wide, at the
`restricted` level. A pod has to run as non-root, drop capabilities, and
declare a seccomp profile, or the API server will not create it. This is
built into Kubernetes; the platform simply turns it on by default.

## Dex and OIDC: who you are

Dex is an identity provider that speaks OIDC, the standard login protocol.
The API server is configured to trust tokens Dex issues; your kubeconfig does
not contain a token but a small plugin that logs you in through a browser
and caches the result. Your email becomes your Kubernetes username and your
groups (`team-a:dev`, `platform:operator`) come with the token. Role
bindings on the cluster name those groups, so what you may do follows from
who the identity provider says you are.

Dex here holds six static users so the platform can be demonstrated without
a directory. The same Dex, connected to a company directory, would issue the
same groups from real accounts, and nothing on the cluster side would
change.

## The access warden: the one custom component

Everything above is off-the-shelf. The one thing written for this platform
is a small controller, the access warden, that implements just-in-time
privilege. You create an `AccessRequest` naming a role, a namespace, a
duration and a reason. Someone else approves it. The warden creates a role
binding with an expiry and deletes it when the time is up. The admission
policies make sure the warden is the only thing that can create such a
binding, that nobody approves their own request, and that durations respect
a cap.

It is about a thousand lines of Go with tests, and the design is written so
that an organisation with a commercial privileged-access product could
replace it without touching the policies around it.

## How they stack

```
  who you are          Dex / OIDC  ──▶  groups  ──▶  RBAC role bindings       (the floor)
  what nobody may do   ValidatingAdmissionPolicy, Pod Security                 (the ceiling)
  what runs            git ──▶ OCI artifact + cosign ──▶ Flux, as the team's SA
  secrets              SOPS/age in git, decrypted only in the cluster
  who may talk         Cilium NetworkPolicy (namespaces)  +  Istio ambient (identities, paths)
  in and out           Gateway API on Istio  +  one egress waypoint
  for an hour          AccessRequest ──▶ approval ──▶ warden ──▶ timed binding
```

The next page shows how these are laid out across the repositories and how
one change travels through them.
