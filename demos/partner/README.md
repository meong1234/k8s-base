What: two request bodies for `demo-partner-api`. They are `kubectl` inputs, not a
kustomize root that is ever pushed as an artifact — both must be rejected by the API
server.
Attached to: nothing. Both are applied impersonating
`system:serviceaccount:team-sec-ops:flux`, the identity that really writes in these two
namespaces, so RBAC is never the thing that denies.
Expected:
  partner-route-on-public.yaml  denied by `public-route-owner` — `claims a hostname its edge does not serve`
  jwt-route-on-partner.yaml     denied by `public-route-owner` — `the partner edge serves api-key only`

Impersonation per file:
  partner-route-on-public.yaml  system:serviceaccount:team-sec-ops:flux  -n public-api
  jwt-route-on-partner.yaml     system:serviceaccount:team-sec-ops:flux  -n partner-api

Each file fails **exactly one** validation, which is why neither is the obvious shape.
`partner-route-on-public.yaml` carries `auth: none` and team-b's own `/orders` prefix, so
the auth-class rule and `api-path-owner` both pass and only the public edge's host class
bites — the `api-key`-on-the-public-edge case is already `demos/exposure/api-key-on-public.yaml`.
`jwt-route-on-partner.yaml` is a correct partner route in every respect except its class
label: one hostname in the partner subzone, a `PathPrefix`, a backend its `owner-team`
owns. `api-path-owner` is bound to `public-edge` only and never sees it.

The happy path is not a file here: it is `repos/team-sec-ops/edges/partner-api/base/` plus the roster in `repos/team-sec-ops/edges/partner-api/envs/local/`, shipped the
normal way with `make push REPO=team-sec-ops`.
