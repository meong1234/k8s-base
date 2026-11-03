# team-b — units, base and envs

This repo is pushed as the OCI artifact `team-b:local`, signed with team-b's
cosign key, and reconciled by the Flux shard `shard-1`. Anything under here is
applied into `team-b-apps` and `team-b-batch` by the `flux` ServiceAccount.

```
kustomization.yaml            resources: [clusters/local]
clusters/local/               the roster: one line per unit, nothing else
apps/podinfo/                 podinfo and the public ReferenceGrant
apps/orders/                  the orders identity, caller, depends-on/
batch/hello/                  hello-cronjob
batch/egress-probe/           egress-job
batch/partner/                partner-job and its ServiceAccount
```

Every unit is `<unit>/base/` plus `<unit>/envs/local/`. `base/` is the
contract: it must `kustomize build` on its own and every object in it must be
admissible in a `restricted` namespace on any tier; `namespace:` (`team-b-apps`
for `apps/`, `team-b-batch` for `batch/`) is set there. An env only ever
**adds** to a base that already deploys, which is why every `envs/local/` here
holds nothing but the seam (`resources: [../../base]`) — no repo has a second
env, because there is one environment, and `team-b` has no value this one
needs to set differently. `repos/team-a/README.md` shows what an env carries
when it does.

`batch/partner/base/partner-job.yaml` names `api.partner-bank.test`. That is
the hostname sec-ops allow-listed — a contract, not a k3d address — so it stays
in `base/`, and it is the one named exception in `ENV_BOUNDARY_SKIP_RE`
(`make env-check` check 4).

`repos/team-a/README.md` is the long form: what may and may not differ per
environment, the five substitutable variables, and how to add a unit or an
environment.
