# team-d — units, base and envs

This repo is pushed as the OCI artifact `team-d:local`, signed with team-d's
cosign key, and reconciled by the Flux shard `shard-2`. Anything under here is
applied into `team-d-analytics` by the `flux` ServiceAccount.

```
kustomization.yaml            resources: [clusters/local]
clusters/local/               the roster: one line per unit, nothing else
apps/podinfo/base/            podinfo in the data-plane namespace
apps/podinfo/envs/local/      resources: [../../base] — nothing else yet
```

`base/` is the contract: it must `kustomize build` on its own and every object
in it must be admissible in a `restricted` namespace on any tier. team-d's
`teams-inputs.yaml` entry says `psa: restricted` and
`privilegedAccess: forbidden`, so an env that added a privileged pod would be
refused at apply time. An env only ever **adds** to a base that already
deploys, which is why `envs/local/` holds nothing but the seam: there is one
environment, and `team-d` has no value this one needs to set differently.

`repos/team-a/README.md` is the long form: what may and may not differ per
environment, the five substitutable variables, and how to add a unit or an
environment.
