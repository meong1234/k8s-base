# Environments

> **Who this is for.** Anyone adding a second cluster, and anyone unsure
> whether a value belongs in a unit's `base/` or in its `envs/<env>/`.
> **Afterwards you can** place any value correctly and say why, name the
> five variables a team may read, explain what the offline checks protect,
> and add an environment without inheriting the laptop's quirks.

## One environment, built for several

There is one cluster today, called `local`. Yet every repository is a set
of **units**, each split into a `base/` and an `envs/local/`; every
repository has a `clusters/local/` roster; and sixteen checks run before
every push to keep the halves honest. Why bother, with one environment?

Because the day a second environment appears is the day it is too late to
untangle what was true everywhere from what was only true on a laptop. A
unit's `base/` is what a new cluster inherits on its first day. Its
`envs/local/` is everything that is true only because this cluster is k3d
on Docker Desktop: a local DNS zone, a plain-HTTP registry, a smaller
resource request, a partner simulated by a container. The split costs
little now and is checked by a machine, so a second cluster starts from a
clean, reviewed default rather than from an archaeology project.

**A unit** is one deployable thing: an app, a batch job, an edge, a
platform component. In a team repo it is `apps/<unit>/` or
`batch/<unit>/`; in sec-ops it is `edges/<edge>/`; in `infra` and
`platform` it is one directory per component. Every unit has the same two
halves:

```
   <group>/<unit>/base/           builds on its own; nothing environment-specific in it
   <group>/<unit>/envs/<env>/     first resource is ../../base; then only what differs here
```

**A roster** is what the environment root of a repo is, and nothing else:
`clusters/<env>/kustomization.yaml` lists one line per unit,
`../../<group>/<unit>/envs/<env>`. No patches, no namespace, no generators.
A unit that should not run in an environment is simply not in that
environment's roster; the unit still has an `envs/<env>/`, so it can be
added with one line. The repo's root `kustomization.yaml` is
`resources: [clusters/local]`, and Flux renders `./clusters/<env>`, so
`kustomize build repos/<repo>` is exactly what Flux applies.

Why the environment lives *inside* the unit rather than at the top of the
repo, where a single `overlays/<env>/` would have been the obvious shape:

- The environment differences of a service are owned by the people who own
  the service. A reviewer of `apps/orders/` sees its base and every
  environment's deviation from it in one directory, not scattered across
  one tree per environment.
- Adding a unit touches one place (its directory, plus one roster line);
  adding an environment touches one place per unit (`envs/<env>/`), and
  the roster says what runs. Neither change edits another unit's files.
- A unit can be absent from an environment without a patch or a delete:
  it is a roster line that is not there.
- A unit moves between repositories, or into a repository of its own, by
  moving one directory. Nothing in it refers to anything outside it.

## Placing a value

The whole discipline is one question: **is this value the same in every
environment?**

| The value is | Where it goes | Example |
| --- | --- | --- |
| the same everywhere | the unit's `base/` | a chart's security context, a route's path, a partner's contract |
| a string that differs per environment, from a short fixed list | the unit's `base/`, written as `${VAR}` | the DNS zone, the public port, the registry |
| different in *shape* per environment: an object that exists here and not there, a secret, a sizing, a tag being tried | the unit's `envs/<env>/` | a partner's roster line, an encrypted key, a laptop-sized resource request |
| whether the unit runs here at all | the repo's `clusters/<env>/` roster | a batch job that only exists on one cluster |

```
   repos/team-a/
   ├── apps/podinfo/
   │   ├── base/             podinfo tag 6.16.0, 1 replica, 50m/64Mi     what any new cluster inherits
   │   ├── envs/local/       tag 6.17.0, 25m/32Mi (states only these)    true only on this laptop
   │   └── envs/prod/        resources: [../../base]                     (would) inherit base unchanged
   ├── clusters/local/       resources: [../../apps/podinfo/envs/local]  the roster: what runs here
   └── kustomization.yaml    resources: [clusters/local]

   kustomize build repos/team-a   ==   what Flux applies on local   (check 10 asserts it)

   .keys/local/team-a/age.agekey     .keys/prod/team-a/age.agekey      one age key per environment:
                                                                        a prod secret cannot open on dev
   .keys/cosign/team-a/cosign.key    one cosign key for every environment: "team-a built this"
```

Three rules keep an `envs/<env>/` small enough to review:

**An env states only what it changes.** If `base/` says one replica,
`envs/local/` says nothing about replicas. A restated value compiles
identically today and drifts silently the first time `base/` moves. In
`repos/team-a/`, two of the four values in the worked example are inherited
and that is the point.

**`base/` holds the figure a real cluster wants; `envs/<env>/` holds the
one that fits here.** A 50m CPU request is a defensible default for a service.
25m is what is left after one k3d node has paid for the mesh, three Envoy
proxies, Dex, seventeen Flux controllers and four other teams. Putting the
laptop's number in `base/` would make every future cluster inherit a figure
that was never about the workload.

**A per-environment value is a literal in `envs/<env>/`, never a variable.**
An image tag in particular. A variable would move "which version runs
where" out of git and into a ConfigMap, and that is the one fact a
promotion review exists to show.

`repos/team-a/README.md` has a table of exactly what an `envs/<env>/` may
and may not change, with the rendered values side by side.

## Cluster variables

Each environment declares one ConfigMap,
`repos/fleet/clusters/<env>/cluster-vars.yaml`, and the platform's
Kustomizations substitute `${KEY}` references from it after rendering. It
carries the environment's name and tier, its DNS zone and the two
browser-facing ports, which registry to pull from and which tag, the image
registries pods may use, the bootstrap identity, and the source kind.

A team sees a *copy* with exactly five keys, stamped into its home
namespace by the fleet template: `CLUSTER_ENV`, `CLUSTER_TIER`,
`CLUSTER_DOMAIN`, `PUBLIC_PORT`, `INTERNAL_PORT`. Substitution is strict, so
a team manifest that references anything else fails to build, and a check
catches it before the push.

The five are enough to write a hostname or a redirect correctly in every
environment. They are deliberately *not* enough to decide what to deploy:
kustomize cannot branch on a value that only exists after the build, and an
object that should exist in one environment and not another belongs in
the unit's `envs/<env>/` or in the roster, not behind a variable.

`CLUSTER_TIER` is the one variable that changes behaviour rather than
strings. On a tier other than `dev`, team admins are bound to the developer
role, and the admission binding that catches hand-applied objects is meant
to be the `Deny` one in `repos/infra/policies/base/prod/` rather than the
`Warn` one in the policies unit's `base/`. No environment selects that
binding today; the file exists so that the day one does, it is a one-line
choice in that environment's `envs/<env>/`.

## The sixteen checks

`make env-check` runs before every push, needs no cluster for fifteen of its
checks, and is the reason the boundary holds without anyone remembering it.
What each one protects, in plain words:

1. **Every root builds.** Every directory with a `kustomization.yaml` under `repos/` and `demos/` renders. A root nobody builds is a root nobody can trust, which is why the prod policy directory is listed explicitly.
2. **Every Secret is encrypted.** A `kind: Secret` under `repos/` whose file lacks `ENC[` fails.
3. **No variable is left unresolved**, and every default is a declared key. A `${VAR}` that cluster-vars does not define would reach the cluster as a literal.
4. **No laptop literal outside `envs/local/`.** The local zone, the local registry, the local ports, the partner container's address: if one appears in a `base/`, in a roster, or in another environment, the check names the file.
5. **Team roots use only the five team-readable keys.** A team manifest with `${OCI_TAG}` passes check 3 and fails on the cluster; this check closes that gap.
6. **Every unit has an `envs/<env>/` for every environment**, every `envs/<env>/` starts from `../../base`, and no `base/` points back at an `envs/`.
7. **The partner roster matches its key files**, both ways.
8. **Every secret in this environment's `envs/<env>/` is encrypted to this environment's recipient.** A prod secret cannot decrypt on dev, and this check is where that is asserted.
9. **No secret sits outside an `envs/<env>/`.** A `*.enc.yaml` in a `base/` or a roster is refused.
10. **A repo's root and its `clusters/<env>/` render byte-identical output**, so `kustomize build repos/team-b` is always what Flux applies.
11. **No renaming under the sec-ops repo**, because a renamed object leaves a policy attached to nothing, silently.
12. **The infra Kustomizations point at `./clusters/<env>`** and `./clusters/<env>/issuers`, and the tier component matches `CLUSTER_TIER` where one is selected.
13. **The Dex roster matches the identity file**, so a user added to one and not the other cannot log in and cannot be told why.
14. **The just-in-time role list agrees with itself** across the policy parameters, the ClusterRole labels and the warden's bind grant, which are three copies of one list in two repos.
15. **Every egress credential a `DestinationRule` names exists** in `platform-egress`. Needs a cluster; prints `skip` without one.
16. **No repo reaches into a sibling.** A relative path that climbs out of `repos/<name>/` would work on this disk and nowhere else.

Each failure prints the check number, the file, and what to do.

## Keys are per environment

Age keys live under `.keys/<env>/<owner>/`. Each team's `.sops.yaml` is
rendered from the public halves, one creation rule per environment, and is
never hand-edited. A file under any unit's `envs/prod/` is therefore
encrypted to the prod recipient and cannot be decrypted by the dev cluster, which is
what check 8 asserts.

Cosign keys live under `.keys/cosign/<owner>/` and are *not* per
environment. A signature answers "the owner built this", and that answer is
the same on every cluster; the environment gate is the tag, guarded by the
push rule on the previous page.

## Adding an environment

1. **Declare it.** `mkdir repos/fleet/clusters/<env>` with a
   `cluster-vars.yaml` (every key the local one has, with that
   environment's values), a `sources.yaml` naming that environment's
   registry or git repositories and the shape of its trust, a
   `teams-inputs.yaml`, a `bootstrap/`, and an `identity/users.yaml`. Copy
   `local` and change every value; check 4 will tell you which ones you
   missed.
2. **Give every unit an env.** In every repo, for every unit,
   `mkdir <group>/<unit>/envs/<env>` with `resources: [../../base]` and
   nothing else. Inheriting `base/` unchanged is a valid env, and every
   line you add later is a line a reviewer has to justify. Check 6 lists
   the units you missed.
3. **Give every repo a roster.** `mkdir repos/<repo>/clusters/<env>` with
   one `../../<group>/<unit>/envs/<env>` line per unit that should run
   there. Start by copying `clusters/local/` and deleting the lines for
   units this environment does not want; `infra` and `platform` also carry
   their second-stage rosters, `clusters/<env>/issuers/` and
   `clusters/<env>/config/`. Flux finds the roster at
   `./clusters/${CLUSTER_ENV}` with no further configuration.
4. **Keys.** `make team-keys CLUSTER_ENV=<env>` generates that environment's
   age pairs; `make team-render-pubkeys` adds the new rule to every
   `.sops.yaml`.
5. **Check.** `make env-check CLUSTER_ENV=<env>`.
6. **Content arrives by promotion.** Never push to the new tag; promote
   into it from the environment before it.

A real environment does not run the demos; they deliberately break and
repair things. It runs `make smoke CLUSTER_ENV=<env>`: every Flux object is
Ready, traffic inside a team is allowed and traffic across a team boundary
is dropped, and a secured public path answers 401 without a token. Three
assertions, no literals, cheap enough to run after every promotion.

## Where the detail lives

- The worked example of what an `envs/local/` changes, with rendered values side by side: `repos/team-a/README.md`
- Why a secret lives in `envs/<env>/` and what happens if it does not: `repos/team-c/README.md`
- The roster pattern for objects that exist per environment: `repos/team-sec-ops/edges/partner-api/README.md`
- Every check with its exact reasoning in the comments: `scripts/env.mk`
