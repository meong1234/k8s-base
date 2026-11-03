# The big picture

> **Who this is for.** Anyone who wants to understand what this repository
> builds before touching any file in it.
> **Afterwards you can** draw the platform on a whiteboard at four levels of
> detail, and trace a change and a request through it step by step.

This page starts from a helicopter and zooms in four times. Each level is
one diagram and the explanation of what is in it. Read it top to bottom once;
afterwards each level stands on its own as a reference.

## Level 0: the helicopter view

One company, one cluster, several kinds of people, and three kinds of
traffic crossing the boundary.

```
                       ┌────────────────────────────────────────────────┐
   product teams       │                   THE CLUSTER                  │
   team-a  team-b  ──▶ │                                                │
   team-c  team-d      │   team-a   team-b   team-c   team-d            │
     write code,       │   ──────   ──────   ──────   ──────            │
     push signed       │   their workloads, isolated from each other,   │
     artifacts         │   talking only where both sides agreed         │
                       │                                                │
   security team  ──▶  │   public edge   partner edge   egress edge      │
     reviews the       │   ───────────   ────────────   ───────────      │
     three edges       │                                                │
                       │   platform: mesh, gateways, identity, policies │
   platform team  ──▶  │                                                │
     owns the base     └──┬────────────────────┬──────────────────┬─────┘
                          │                    │                  │
   the internet ──────────┘                    │                  └──────▶ the internet
   (users of public APIs)       a business partner ──┘                     (only listed hosts,
                                (own hostname, own keys)                    only through one proxy)
```

Three groups of people write to this cluster, and each writes through its
own repositories, signed with its own keys:

- **Product teams** own their workloads. Four of them here, called team-a to
  team-d, each a stand-in for a real team with real services.
- **The security team** (`team-sec-ops`) owns what crosses the boundary:
  which routes are public, which partners may call in, which outside hosts
  may be called. It does not own the gateways themselves, only what passes
  through them.
- **The platform team** owns everything underneath: the cluster, the mesh,
  the gateways, the identity provider, the admission rules, and the template
  that stamps a team into existence.

Three kinds of traffic cross the boundary, each through a different door:

- **Public users** reach `api.<domain>` and each team's API is a path on
  that one host.
- **Business partners** reach `<partner>.partners.<domain>` on a separate
  port with their own certificate and API keys.
- **Outbound calls** leave through one proxy that only carries listed hosts.

Nobody in the picture holds a permanent admin credential. That is not drawn
because it is an absence, but it is the most important fact about the
diagram.

## Level 1: inside the cluster

Zoom in once and the cluster separates into layers that never share a
writer.

```
 ┌───────────────────────────────────────────────────────────────────────────┐
 │  CONTROL                                                                  │
 │  flux-system:  Flux operator, Flux controllers (two shards), the          │
 │                ResourceSet that stamps teams, cluster-vars                │
 │  cluster-wide: 13 admission policies, RBAC tiers, Pod Security,           │
 │                audit log, two cluster-wide network rules                  │
 ├───────────────────────────────────────────────────────────────────────────┤
 │  PLATFORM SERVICES                                                        │
 │  istio-system          ztunnel on every node, istiod, mesh-wide STRICT    │
 │  envoy-gateway-system  three Envoy proxies: public, internal, partner     │
 │  platform-ingress      the three Gateways and their certificates          │
 │  platform-identity     Dex                                                │
 │  platform-egress       the egress waypoint and the partner credential     │
 │  platform-access       the access warden                                  │
 │  cert-manager          the local CA issuer                                │
 ├─────────────────────────────────────┬─────────────────────────────────────┤
 │  TENANTS                            │  EDGES (team-sec-ops)               │
 │  team-a / team-a-apps               │  public-api      routes on api.<z>  │
 │  team-b / team-b-apps, team-b-batch │  partner-api     one dir per partner│
 │  team-c / team-c-apps               │  egress-allowlist one file per host │
 │  team-d / team-d-analytics          │                                     │
 └─────────────────────────────────────┴─────────────────────────────────────┘
```

**Control** is what the platform's own Flux controllers reconcile from the
`fleet` and `infra` repositories: the rules of the game. A team never writes
here, and two cluster-wide network rules make sure a team's pod cannot even
reach these namespaces.

**Platform services** come from the `platform` repository. They are the
things every team uses and no team configures: the mesh that encrypts
pod-to-pod traffic, the proxies that terminate public TLS, the identity
provider, the single egress proxy, the warden that grants timed access.

**Tenants** are stamped by the ResourceSet from one input block each. A
team's Flux controllers run on a shard in `flux-system`, but they apply
*as* the team's service account, which exists only in the team's own
namespaces. That is the line between the top half and the bottom half of the
picture: the top half is reconciled by the platform's identity, the bottom
half by each team's.

**Edges** are the odd one out. They are tenant namespaces, stamped by the
same template, reconciled by the security team's own service account, but
the objects inside them are what the gateways and the egress proxy obey. The
security team is a tenant whose namespaces happen to be the cluster's
boundary, and that is exactly what makes their pull-request review the
company's security review.

## Level 2: one team's slice

Zoom in on team-b. Everything in this diagram came from the four-line input
block below, rendered by the one template in `repos/fleet/base/teams.yaml`.
The template points every team at `./clusters/${CLUSTER_ENV}` inside its
artifact, so there is no path to get wrong per team.

```yaml
- team: team-b
  shard: shard-1
  namespaces: [apps, batch]
  apiPaths: [orders]
```

```
 namespace team-b  (home, role team-home, no workloads)
 ┌─────────────────────────────────────────────────────────────────────┐
 │ ServiceAccount flux          the identity everything is applied as  │
 │ OCIRepository team-b-source  pulls oci://registry/team-b:local       │
 │                              verify: cosign-pub  (team-b's public key)│
 │ Kustomization team-b         path ./clusters/local, as SA flux,      │
 │                              shard-1, decrypt with sops-age          │
 │ ConfigMap cluster-vars       the five keys a team may read           │
 │ Secret sops-age              injected by the platform, never in git  │
 │ Secret cosign-pub            injected by the platform                │
 │ RoleBindings                 team-b:dev → developer, team-b:admin →  │
 │                              team-admin + approver, company:viewer   │
 │ AccessRequests               filed here when someone needs exec      │
 └──────────────┬──────────────────────────────────────────────────────┘
                │ applies into
 namespace team-b-apps  (workload)           namespace team-b-batch  (workload)
 ┌──────────────────────────────────────┐    ┌──────────────────────────────────┐
 │ the team's objects:                  │    │ the team's objects:              │
 │   HelmRelease podinfo                │    │   CronJob, egress probe Job,     │
 │   ServiceAccount orders              │    │   partner Job as SA payments     │
 │   Deployment caller                  │    │                                  │
 │   ReferenceGrant allow-public-api    │    │ stamped by the platform:         │
 │   depends-on-team-a-podinfo          │    │   same baseline as the left      │
 │                                      │    │                                  │
 │ stamped by the platform:             │    │                                  │
 │   NetworkPolicy team-baseline-       │    │                                  │
 │     default-deny                     │    │                                  │
 │   AuthorizationPolicy team-baseline- │    │                                  │
 │     allow-same-team                  │    │                                  │
 │   OCIRepository podinfo-chart        │    │                                  │
 │   RoleBinding team-admin (SA flux)   │    │                                  │
 │   PSA restricted, ambient enrolled   │    │                                  │
 └──────────────────────────────────────┘    └──────────────────────────────────┘

 flux-system: ConfigMap api-paths-team-b   { team: team-b, paths: orders }
```

Read it as two kinds of objects in every workload namespace. The ones the
team ships arrive through the signed artifact and change whenever the team
pushes. The ones the platform stamps are re-applied by the ResourceSet every
ten minutes and are locked against edits by an admission policy where it
matters (the baseline policy) or self-heal where it does not (the chart
catalog).

The home namespace holds no workloads and no network reachability from
them, so a compromised pod in `team-b-apps` cannot read the age key or
re-point the source.

## Level 3: one change, step by step

Zoom in on the arrow between "a team edits a file" and "a pod runs". Every
step is a place where something can be refused, and the refusal is the
design.

```
 1  edit repos/team-b/apps/podinfo/base/podinfo.yaml
         │
 2  make env-check         16 offline checks: every root builds, no plaintext
         │                 secret, no variable left unresolved, no k3d literal
         │                 outside envs/local, repo is self-contained
         │
 3  flux push artifact     repos/team-b/  ──▶  oci://registry/team-b:local
         │                 revision = hash of the files
         │
 4  cosign sign            the digest, with .keys/cosign/team-b/cosign.key
         │
 5  OCIRepository          polls the tag, finds a new digest
    team-b-source          verifies the signature against Secret cosign-pub
         │                 ✗ wrong key or no key  → SourceVerified=False, stop
         │
 6  Kustomization          renders ./clusters/local with kustomize: the roster,
    team-b                 one line per unit, each unit's envs/local on its base
         │                 substitutes ${CLUSTER_DOMAIN} etc. from cluster-vars
         │                 decrypts *.enc.yaml with Secret sops-age
         │
 7  server-side dry run    as system:serviceaccount:team-b:flux
         │                 ✗ object in another namespace → forbidden, stop
         │                 ✗ image from unknown registry  → admission deny, stop
         │                 ✗ privileged pod                → PodSecurity deny, stop
         │                 ✗ wrong shard label             → admission deny, stop
         │
 8  apply, then wait       objects land in team-b-apps / team-b-batch
         │                 Kustomization reports Ready=True with the revision
         ▼
 9  pod runs               enrolled in the mesh, fenced by the baseline
```

Three properties fall out of the order:

- The signature is checked at step 5, before any content is rendered. A bad
  artifact never reaches a dry run.
- Step 7 is a dry run of the whole revision before any of it is applied, so
  a revision with one bad object applies nothing. You never get half a
  release.
- Every refusal names the identity that was refused
  (`system:serviceaccount:team-b:flux`), which is why the error is always on
  the team's own Kustomization and never a mystery in someone else's
  namespace.

On a real platform steps 3 and 4 run in CI on merge to main, keylessly. The
file is `ci/artifact-publish.yml`. Nothing from step 5 on changes.

## Level 3, again: one request, step by step

Now the other arrow, a request from the internet to a pod. This one crosses
objects owned by four different parties, and each is required.

```
 https://api.local-dev.test:8443/orders/
         │
 1  Gateway public (platform-ingress)             owner: platform
         │  TLS terminated with the public wildcard certificate
         │  listener admits routes only from namespaces labelled public-edge
         │
 2  HTTPRoute team-b-orders (public-api)          owner: team-sec-ops
         │  host api.<zone>, PathPrefix /orders, rewrite to /
         │  label owner-team: team-b    → backend must be in team-b's namespaces
         │  label auth: jwt             → the jwt SecurityPolicy applies
         │  /orders is team-b's prefix  → ConfigMap api-paths-team-b says so
         │
 3  SecurityPolicy public-edge-jwt                owner: team-sec-ops
         │  no token           → 401
         │  token for the wrong audience (e.g. a kubectl login) → 403
         │  valid token for aud public-api → continue, add x-user-email
         │  BackendTrafficPolicy: 20 req/min per client IP
         │
 4  ReferenceGrant allow-public-api (team-b-apps) owner: team-b
         │  "routes from public-api may target Service podinfo"
         │  ✗ absent → ResolvedRefs=False, the edge serves an error
         │
 5  Service podinfo (team-b-apps)
         │  Envoy → pod over HBONE on 15008, mTLS, identity on both ends
         │  the baseline NetworkPolicy allows envoy-gateway-system on 15008
         ▼
 6  the podinfo pod, receiving x-user-email and never the token
```

The platform allocated the prefix, the security team wrote the route and
owns the authentication and rate-limit policies, the owning team consented
with a `ReferenceGrant`, and the platform's gateway admitted the route
because of a namespace label only the platform can set. Remove any one of
the four and the path is gone. The admission policies make sure none of the
labels at step 2 can be omitted or forged.

## How the cluster is built up, layer by layer

Finally, the order in which all of this comes into existence on `make up`.
It is a chain of Flux Kustomizations, each waiting for the one before, and
knowing the chain tells you where to look when something is not Ready.

```
 k3d cluster with Cilium as CNI, PodSecurity restricted, audit log on, OIDC authn
   │
 Flux operator installed; platform artifacts (fleet, infra, platform) pushed and signed
   │
 cluster-sync         (fleet)      reads clusters/local: cluster-vars, sources, the
   │                               FluxInstance with two shards, and the three below
   ├─▶ infra-ks       (infra)      path ./clusters/local: namespaces, CRDs, RBAC tiers,
   │                               13 admission policies, cluster-wide network rules,
   │                               cert-manager chart
   │     └─▶ infra-config-ks       path ./clusters/local/issuers: the ClusterIssuer
   │                               (needs cert-manager's CRD first)
   │
   ├─▶ platform-ks    (platform)   path ./clusters/local: Istio ambient, Envoy Gateway,
   │     │                         the three Gateways and certificates, Dex, the egress
   │     │                         waypoint, the warden
   │     └─▶ platform-config-ks    path ./clusters/local/config: mesh-wide STRICT mTLS,
   │                               the Envoy proxy definitions (custom resources whose
   │                               CRDs the stage above installs)
   │
   └─▶ ResourceSet teams           waits for platform-config-ks, then stamps every team
         │
         └─▶ Kustomization team-a, team-b, team-c, team-d, team-sec-ops
               each on its shard, each as its own service account, each pulling its
               own signed artifact and rendering its ./clusters/local roster; make up injects each team's age key and cosign key
               into the home namespace and pushes the team artifacts
```

Two of the splits in that chain exist for one reason, worth knowing because
you will meet it again: Flux dry-runs a whole revision before applying any of
it, so a custom resource cannot share a Kustomization with the chart that
installs its CRD. That is why `infra-config-ks` and `platform-config-ks`
exist as second stages.

`make flux-status` prints the chain's state. If a team is not Ready, walk up
the chain until you find the first thing that is not.

## Where to go next

- What all of this gives you, and the security practices behind each part:
  [capabilities](04-capabilities.md)
- The promises as a checklist, each with the demo that proves it:
  [guarantees](05-guarantees.md)
- Doing things: [walkthroughs](06-walkthroughs.md)
