What: three request bodies for `demo-vap`, taken verbatim from the denied/allowed
one-liners in `repos/infra/policies/base/README.md`. They are `kubectl` inputs, not a
kustomize root, and are never pushed as an artifact — two of them must be
rejected by the API server, the third must be accepted.
Attached to: nothing. `demo-vap` applies them impersonating `system:serviceaccount:team-a:flux`.
Expected:
  wrong-shard-helmrelease.yaml  denied by `team-shard-label`    — `must carry label sharding.fluxcd.io/key=shard-1 but has "shard-2"`
  bad-registry-pod.yaml         denied by `allowed-registries`    — `image registry not in the platform allow-list`
  ok-kustomization.yaml         allowed (server dry-run) — the regression guard: a guardrail that blocks the platform is an outage
