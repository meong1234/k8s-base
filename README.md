# k8s-base

A multi-team Kubernetes platform where every rule is enforced by the cluster
and every rule has a demo that proves it.

Several product teams share one cluster. Each ships its own repository as a
signed artifact that Flux applies under the team's own identity, so a team
cannot write outside its namespaces. Nothing flows between teams unless both
declared it in git. Nothing reaches the internet except through one proxy
that logs who called. A security team owns the public edge, and their
signature is the approval. Nobody, the platform team included, holds `exec`
or `cluster-admin` standing; you ask, someone else approves, it expires.

The whole thing runs on a laptop with k3d. `make up` brings it up,
`make demo-all` tries to break every rule and shows each refusal.

## What it looks like

```
   product teams ──signed push──▶ ┌───────────────────────────────────────────────┐
   team-a .. team-d               │  team-a   team-b   team-c   team-d            │
                                  │  isolated namespaces, mTLS between pods,      │
   security team ──review──────▶  │  cross-team calls only where both sides agreed│
   (public routes, partners,      │                                               │
    outbound allow-list)          │  public edge     partner edge    egress edge   │
                                  │                                               │
   platform team ──template────▶  │  Flux · Cilium · Istio ambient · Envoy Gateway │
   (the base, the rules)          │  Dex · admission policies · access-warden     │
                                  └───┬───────────────────┬──────────────────┬────┘
   public users ──────────────────────┘    a partner ──────┘   listed hosts ◀─┘
```

## What you get

- **Delivery.** Git to cluster with no hands in between: each repo is
  published as a signed OCI artifact, verified before a byte is read,
  promoted between environments by retagging the same digest.
- **Tenancy.** A team is a five-line input. One template stamps its
  namespaces, identity, role bindings, Flux objects and locked default-deny
  baseline. Thirteen native admission policies form a ceiling no role can
  pass.
- **Traffic.** Cilium default-deny between teams, Istio ambient mTLS with
  workload identity, two-party cross-team access, one egress waypoint with
  per-host, per-team grants and an access log that names the caller.
- **Edges.** One public host with a path prefix per team, JWT or open per
  route, rate-limited by label. A separate partner gateway with its own
  certificate, keys and limits. All of it reviewed by one team through
  pull requests.
- **People.** OIDC login, four tiers of role, just-in-time privileged access
  with four-eyes approval and expiry, and an audit log with real names.
- **Verification.** Twenty-two demos that each attempt the forbidden thing
  and assert the refusal, and sixteen offline checks that run before every
  push.

## Running it

```sh
make brew-setup-all      # the toolchain, through Homebrew
make up                  # cluster, registry, keys, images, Flux, teams, partner sim
make status              # cluster, Flux and artifact state
make demo-all            # every demo, with a PASS/FAIL table at the end
make down                # delete the cluster; keep the image cache and keys
```

`make help` lists every target by area. The first `make up` preloads images
and takes a while; later ones are faster. Docker Desktop is the only
prerequisite the toolchain does not install.

## The tree

```
repos/            eight repositories in one tree, each a real repo on a real platform
  fleet/          the cluster: Flux instance, platform Kustomizations, the team list
  infra/          the rules: CRDs, RBAC tiers, admission policies, network baseline
  platform/       the shared services: mesh, gateways, Dex, egress waypoint, access-warden
  team-a..d/      four tenant teams, each signed with its own key
  team-sec-ops/   the three edges: public routes, partner routes, egress allow-list

  every repo but fleet is a set of units, each with the same two halves,
  and a roster per environment that says which units run there:
    <group>/<unit>/base/          the reviewed default, builds on its own
    <group>/<unit>/envs/<env>/    ../../base plus only what differs here
    clusters/<env>/               one line per unit; what Flux renders
    kustomization.yaml            resources: [clusters/local]
  <group> is apps/ or batch/ in a team repo, edges/ in team-sec-ops,
  and one directory per component in infra/ and platform/
warden/           the one custom component: the just-in-time access controller (Go)
scripts/          the make modules behind every target
demos/            inputs and walkthroughs for the demos
k3d/              the cluster definition, admission defaults, audit policy
sim/              the partner that demands a client certificate, outside the cluster
ci/               the publisher that replaces `make push` once the repos are split
docs/             start here
```

## Reading

[`docs/`](docs/README.md) explains the platform from the helicopter view
down, with a reading path for each role. If you have twenty minutes, read
[why](docs/01-why.md) and [the big picture](docs/03-the-big-picture.md).
If you are about to ship something, [walkthroughs](docs/06-walkthroughs.md).
If you are judging the design, [capabilities](docs/04-capabilities.md) and
[guarantees](docs/05-guarantees.md), where every claim names the command
that proves it.

The README next to each component is the reference for that component.

## What is real and what stands in

Every rule is enforced by the real API server, the real network layer and
the real mesh. Some surroundings are stand-ins for what a company would
have: one environment instead of several, Dex with six static users
instead of a directory, an nginx container as the mutual-TLS partner, and
`make push` from a laptop instead of CI. Each is confined to a unit's
`envs/local/` that the checks fence off, and the docs say where it matters.
