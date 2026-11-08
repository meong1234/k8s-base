# access-warden

The just-in-time privileged access controller. It watches `AccessRequest`
objects and turns an **approved** one into a time-bound RBAC binding, then takes
it away again. Nobody on this platform — the platform team included — holds
standing `exec`, `attach`, `port-forward`, `ephemeralcontainers` or
`cluster-admin`; this is how those rights are obtained for a bounded window,
with a second person's name on the record.

## Where the pieces live

| What | Where |
| --- | --- |
| this Go module (source, tests, Dockerfile) | `warden/` |
| the `AccessRequest` CRD, generated from the Go types | `repos/infra/crds/base/access/accessrequests.yaml` |
| ServiceAccount, RBAC, Deployment | `repos/platform/access-warden/base/` |
| the five admission policies that cap it | `repos/infra/policies/base/{access-request-create,access-request-approve,jit-binding-lock,privileged-access-guard,gitops-only}.yaml` |
| the ClusterRoles it binds | `repos/infra/rbac/base/{platform-debug,platform-team-admin}.yaml` + built-in `cluster-admin` |
| the human interface | `scripts/access.mk` (`make access-request` / `-approve` / `-deny` / `-list` / `-revoke`) |
| a second, unrelated command in the same module | `warden/cmd/dexproxy` — see below |

The source is **not** inside `repos/platform/access-warden/base/`: that directory is
pushed to the registry as the `platform` OCI artifact, and a Go module there
would ship `go.sum`, test files and module-cache references into every
reconcile. The manifests are what Flux ships; the source is what
`make warden-image` builds.

### `cmd/dexproxy` lives here too

`warden/cmd/dexproxy` has nothing to do with access requests: it is the ~90-line
loopback CONNECT proxy that stands in for the `/etc/hosts` line kubelogin needs. It lives in this module
because this is the repo's only Go module, it ships in no image, and
`make dex-proxy` compiles it on demand into `.keys/local/platform/dexproxy`. It is
excluded from nothing: `go vet ./...` and `go test ./...` cover it, and the
warden image's `go build ./cmd` ignores it.

## The state machine

```
         (created by a human; status is cleared on CREATE)
                     │
 warden ────────────▶ Pending ──── human: approve ────▶ Approved
                     │  │                                  │
                     │  └── human: deny ──▶ Denied         │ warden: create jit-<name>,
                     │  └── human: revoke ▶ Revoked        │   expiresAt = now + min(duration, cap)
                     │                                     ▼
                     │                                  Active ─── now >= expiresAt ──▶ Expired
                     │                                     │
                     │                                     └── human: revoke ──▶ Revoked
                     ▼
            Denied / Revoked / Expired: binding deleted, nothing requeued
```

- Phases a **human** may write: `Approved`, `Denied`, `Revoked` from
  `''`/`Pending`, and `Revoked` from `Active`. `Active` and `Expired` are the
  warden's, enforced by `access-request-approve`.
- `Active` re-asserts its binding every reconcile, so a binding deleted by hand
  comes back inside the window and a warden restart converges from `status`
  plus the `access.k8s-base/managed-by=access-warden` label.
- Requeue is `min(expiresAt - now, --sweep-interval)`. `expiresAt` is never
  recomputed once written, so the window cannot slide.
- A `cluster-admin` grant is a ClusterRoleBinding and cannot carry an owner
  reference to a namespaced `AccessRequest`, so the warden holds the finalizer
  `access.k8s-base.io/revoke`: deleting the request revokes the grant.
  Same-namespace RoleBindings also get a controller reference.
- **Warden down = nothing granted and nothing revoked.** That is the safe
  failure mode: no new access appears, and `make access-list` shows what is
  still live. `kubectl delete rolebinding jit-...` as the break-glass identity
  is the manual revocation.

## The role catalog

`api/v1alpha1/roles.go` is the only place a request role maps to a ClusterRole
and a cap. `jit-binding-lock`'s `isJitRole` list and this map must change
together.

| `spec.role` | ClusterRole | Cap | Scope |
| --- | --- | --- | --- |
| `debug` | `platform-debug` | 4h | RoleBinding in `spec.targetNamespace` |
| `team-admin` | `platform-team-admin` | 8h | RoleBinding in `spec.targetNamespace` |
| `cluster-admin` | `cluster-admin` | 1h | ClusterRoleBinding |

The cap is enforced twice on purpose: `access-request-create` rejects an
over-cap `spec.duration` at admission (VAP has no `now()`, so the cap is a
property of the request string), and the warden clamps again when it computes
`expiresAt`, so a policy that is somehow absent cannot widen a window.

## Why a privileged component is safe here (risk H12)

The warden holds `bind` on `cluster-admin`. That is unavoidable for a component
that grants cluster-admin, so the blast radius is cut from the outside instead:

- `jit-binding-lock` admits a binding from the warden **only** if it is named
  `jit-<request>` and carries `access.k8s-base/request-uid`, and admits a
  binding to any of the three JIT ClusterRoles from nobody else except the
  platform writers and the break-glass certificate.
- `privileged-access-guard` denies the sessions themselves in namespaces
  labelled `platform.k8s-base/privileged-access: forbidden` — for everyone,
  including a holder of a fresh `cluster-admin` grant. The policy is the
  ceiling; RBAC is the floor.
- Restricted PSA, read-only root filesystem, non-root uid 65532, all
  capabilities dropped, one replica, no Service and no network ingress.
- Every write it makes is audited at `RequestResponse`
  (`k3d/audit-policy.yaml`), as is every approval.

The image is **not** signed. This repo signs OCI *artifacts* with cosign, not
container images, and nothing in the cluster verifies image signatures — no
Kyverno, no sigstore policy controller — so signing it would be decoration.
Called out rather than silently skipped; the real mitigations are the two
policies above.

In production the warden is replaceable: with an IdP that does privileged
identity management the approval happens there and the group `<team>:debug`
arrives in the token for the approved window, bound by a standing RoleBinding.
With Teleport, request, approval and session recording all move into Teleport.
The admission policies and the audit rules stay in either case.

## Development

```sh
cd warden
make vet test build          # go vet, 14 controller tests against a fake client, go build
make manifests               # regenerate ../repos/infra/crds/base/access/accessrequests.yaml
make generate                # regenerate zz_generated.deepcopy.go
make docker-build            # docker.io/k8s-base/access-warden:dev, distroless, ~47 MB
```

From the repo root, `make warden-image` builds it and pushes it into the k3d
registry; `make images-build-local` is what `make up` calls. The node resolves
`docker.io/k8s-base/access-warden:dev` through the existing `docker.io`
containerd mirror in `k3d/cluster.yaml`, so there is no `imagePullSecrets` and
`allowedRegistries` already carries the `docker.io/` prefix.

`make warden-logs` tails it on the cluster.

## Trying it

```sh
make login USER=alice@team-a.local
make login USER=bob@team-a.local
ALICE=.keys/local/users/alice@team-a.local/kubeconfig
BOB=.keys/local/users/bob@team-a.local/kubeconfig

KUBECONFIG=$ALICE kubectl -n team-a-apps exec deploy/podinfo -- true      # forbidden
KUBECONFIG=$ALICE make access-request ROLE=debug NS=team-a-apps DURATION=2m \
  REASON='podinfo 5xx after 14:00, need to inspect /tmp'
KUBECONFIG=$BOB   make access-approve NAME=<printed> NS=team-a
KUBECONFIG=$ALICE kubectl -n team-a-apps exec deploy/podinfo -- ls /tmp   # works
make access-list ; make audit-exec
```

`make demo-jit`, `make demo-breakglass`, `make demo-privileged-guard` and
`make demo-gitops-only` run the whole thing with assertions.
