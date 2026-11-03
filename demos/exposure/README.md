What: seven request bodies for `demo-exposure`. They are `kubectl` inputs, not a
kustomize root, and are never pushed as an artifact — all seven must be rejected by the
API server.
Attached to: nothing. The demos apply them impersonating the Flux ServiceAccount of the
namespace each object claims, so RBAC is never the thing that denies.
Expected:
  lb-service.yaml              denied by `team-no-direct-exposure` — `may not have type LoadBalancer`
  public-parentref-route.yaml  denied by `team-no-direct-exposure` — `attaches to a Gateway this namespace does not own`
  foreign-backend-route.yaml   denied by `public-route-owner`        — `a backendRef points elsewhere`
  platform-backend-route.yaml  denied by `public-route-owner`        — `flux-system` is a reserved namespace prefix
  no-auth-label-route.yaml     denied by `public-route-owner`        — `must carry the label platform.k8s-base/auth`
  wrong-prefix-route.yaml      denied by `api-path-owner`            — `/orders` is allocated to team-b
  api-key-on-public.yaml       denied by `public-route-owner`        — `the auth class does not match the edge`

Impersonation per file:
  lb-service.yaml              system:serviceaccount:team-a:flux       -n team-a-apps
  public-parentref-route.yaml  system:serviceaccount:team-a:flux       -n team-a-apps
  everything else              system:serviceaccount:team-sec-ops:flux -n public-api

Each file is shaped to fail **exactly one** validation: a route that trips two rules
proves nothing about which one bit. So the three route files aimed at the backend,
`auth` and prefix rules all sit on `api.local-dev.test` with a prefix their owner label
is entitled to, and only the one field under test is wrong.

`team-route-hostname` and `foreign-hostname-route.yaml` are gone: there is no team
self-service exposure to fence a hostname inside, so `team-no-direct-exposure`
absorbed the route rule — a team namespace may only `parentRef` its own `waypoint`
Gateway, and everything else is a PR to team-sec-ops.

The happy path is not a file here: it is the content of `repos/team-sec-ops/edges/public-api/base/`
and `repos/team-a/apps/podinfo/base/public-consent.yaml` + `repos/team-b/apps/podinfo/base/public-consent.yaml`,
shipped the normal way with `make push REPO=team-sec-ops` / `make push REPO=team-a`.
`demo-exposure` adds and removes the `ReferenceGrant` to show that the owning team holds
a veto, and pushes the sec-ops repo signed with team-a's key (`SIGN_AS=team-a`) to show
that sec-ops' signature is the approval.
