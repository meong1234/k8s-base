# team-a — units, base and envs

This repo is pushed as the OCI artifact `team-a:local`, signed with team-a's
cosign key, and reconciled by the Flux shard `shard-1`. Anything under here is
applied into `team-a-apps` by the `flux` ServiceAccount.

team-a is the first team repo split into units, each with a `base/` plus one
`envs/<env>/` per environment. The environment picks which one by the `path`
on its stamped `Kustomization` — `./clusters/local` from
`repos/fleet/clusters/local/teams-inputs.yaml` — and the repo root still lists
`clusters/local`, so `kustomize build repos/team-a` renders exactly what the
`local` cluster gets.

```
kustomization.yaml            resources: [clusters/local]
clusters/local/               the roster: one line per unit, nothing else
apps/podinfo/base/            podinfo, the public ReferenceGrant, allow/
apps/podinfo/envs/local/      base plus podinfo-small.yaml
```

A unit is one deployable thing — here the podinfo HelmRelease together with
the objects that belong to it. `apps/<unit>/base/` is the contract: it must
`kustomize build` on its own, every object in it must be admissible in a
`restricted` namespace on any tier, and the values it carries are the
**reviewed default a new environment inherits** — one replica,
`image.tag: 6.16.0`, a real-cluster resource request — and it must stay
deployable on its own, because it is what a second environment starts from.
`namespace:` is set in the unit's `base/kustomization.yaml`, never in
`clusters/`.

There is **one environment**, so there is one `envs/local/` per unit. `local`
is the only cluster that exists, and the split earns its keep anyway: `base/`
is what a second cluster would inherit on day one, and `envs/local/` is
everything true only because this one is k3d on a laptop. That is the same
boundary `make env-check` check 4 enforces for hostnames and ports, applied to
sizing.

## The worked example: what the env changes

| | `image.tag` | `replicaCount` | requests | limits |
| --- | --- | --- | --- | --- |
| `base/` | `6.16.0` | 1 | 50m / 64Mi | 200m / 128Mi |
| `envs/local/` | **6.17.0** | 1 | **25m / 32Mi** | **100m / 64Mi** |

```sh
for e in base envs/local; do
  kustomize build repos/team-a/apps/podinfo/$e \
    | yq ea 'select(.kind=="HelmRelease") | {"tag": .spec.values.image.tag,
             "replicas": .spec.values.replicaCount, "req": .spec.values.resources.requests}'
done
```

Three rules that shape follows, and they are the rules for any team repo:

1. **An env states only what it changes.** `envs/local/` says nothing about
   `replicaCount`, because `base/` already says 1. A restated value compiles
   identically today and drifts silently the first time `base/` moves. Two of
   the four columns above are inherited, and that is the point.
2. **`base/` holds the figure a real cluster wants; the env holds the one
   that fits here.** 50m/64Mi is a defensible request for a service with a
   waypoint in front of it. 25m/32Mi is not — it is what is left after one k3d
   node has paid for Cilium, Istio (istiod, two DaemonSets, three waypoints),
   three ingress gateways, Dex, Flux's 17 controllers and four other teams. Putting
   the laptop's figure in `base/` would make every future cluster inherit a
   number that was never about the workload.
3. **A per-environment value is a literal in `envs/<env>/`, never a
   `cluster-vars` key.** A post-build variable would move "which version runs
   where" out of git and into a ConfigMap, and that is the one fact a review
   exists to show. The five keys a team namespace can read are below, and an
   image tag is deliberately not among them.

`base/` pins `image.tag` and `envs/local/` overrides it, not the reverse:
`base/` is the reviewed default, and the laptop is where a new release gets
exercised before that default moves. Bumping `base/` to `6.17.0` is then a
one-line diff a reviewer can read, and the day a second environment appears it
inherits the reviewed tag rather than whatever `local` happened to be testing.

## What may and may not differ per environment

| Thing | May `envs/<env>/` do it? |
| --- | --- |
| add or remove an object (a feature flag, a `PodDisruptionBudget`, a Job) | **yes** — this is what an env directory is for |
| change a value inside one by patch (a backend URL, a log level, a `HelmRelease` `values` field) | **yes** |
| `image.tag` | **yes** — and it is how a promotion is read: `base/` pins the reviewed default and an env may run ahead of it |
| `replicaCount`, requests, limits | **yes**, and it is the reason `envs/local/` here is not empty — `base/`'s real-cluster request does not fit beside everything else on one k3d node. The old rule here was **no**, on the grounds that a per-environment sizing knob is how a second cluster quietly stops resembling the first. That risk is real and the answer is reviewability, not prohibition: `base/` holds the default, the env states only the fields it changes, and the table above renders in one command — so a cluster that has drifted shows up as a column, not as a surprise |
| PSA, namespaces, the shard, `apiPaths`, cross-team `allowFrom`, the waypoint | **no** — those are stamped from `teams-inputs.yaml` and are not in this artifact at all |
| the public route, its hostname, its auth class | **no** — `repos/team-sec-ops/` owns every route |
| an external host, its address, its client certificate | **no** — the platform egress waypoint owns them |

## Variables

Flux substitutes from the `ConfigMap cluster-vars` in namespace `team-a`, and
that copy carries exactly five keys: `CLUSTER_ENV`, `CLUSTER_TIER`,
`CLUSTER_DOMAIN`, `PUBLIC_PORT`, `INTERNAL_PORT`. Substitution is **strict**, so
any other `${...}` in this repo fails the build; a team-shipped second
`substituteFrom` does not work either, because substitution runs before the apply
that would create the ConfigMap. `${CLUSTER_TIER}` is for behaviour inside a
workload, never for deciding whether to ship an object — kustomize cannot branch
on a value that only exists after the build; that is what `envs/<env>/` is for.

## Adding a unit

1. `mkdir -p repos/team-a/apps/<unit>/{base,envs/local}`. `base/` sets
   `namespace:` and lists the unit's objects; `envs/local/kustomization.yaml`
   starts as `resources: [../../base]` and nothing else.
2. Add `../../apps/<unit>/envs/local` to `clusters/local/kustomization.yaml`.
   The roster is the only thing that lives there — no patches, no namespace.

## Adding an environment

1. For every unit, `mkdir repos/team-a/apps/<unit>/envs/<env>` with
   `resources: [../../base]` plus whatever that environment adds or patches.
   Start with nothing: inheriting `base/` unchanged is a valid env, and every
   line you add is a line a reviewer has to justify against the table above.
2. `mkdir repos/team-a/clusters/<env>` listing each unit's `envs/<env>`.
3. `make env-check` — it discovers every unit's `base/` and `envs/*` and
   builds all of them.
