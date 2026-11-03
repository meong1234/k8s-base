What: the inputs and the walkthroughs for the four just-in-time privileged-access
demos (`demo-jit`, `demo-breakglass`, `demo-privileged-guard`, `demo-gitops-only`).
Attached to: nothing. These are `kubectl` inputs, never pushed as an artifact.
Expected:
  handmade-debug-binding.yaml  denied by `jit-binding-lock` — `may not CREATE a rolebindings bound to ClusterRole/platform-debug`
  handmade-deployment.yaml     warned by `gitops-only-warn` on this cluster, denied by `gitops-only-deny` on prod

Every command below runs as a real OIDC identity, so it needs H5's
`make login USER=<user>` to have written `.keys/local/users/<user>/kubeconfig` first.
`make login-help` prints the passwords. The identities:

| Shell variable used below | Identity | Groups |
| --- | --- | --- |
| `ALICE` | `alice@team-a.local` | `team-a:dev` |
| `BOB` | `bob@team-a.local` | `team-a:admin` |
| `CAROL` | `carol@team-b.local` | `team-b:dev` |
| `OPS` | `ops@platform.local` | `platform:operator` |
| `OPS2` | `ops2@platform.local` | `platform:operator` |

```sh
ALICE=.keys/local/users/alice@team-a.local/kubeconfig
BOB=.keys/local/users/bob@team-a.local/kubeconfig
CAROL=.keys/local/users/carol@team-b.local/kubeconfig
OPS=.keys/local/users/ops@platform.local/kubeconfig
OPS2=.keys/local/users/ops2@platform.local/kubeconfig
```

## `demo-jit` — exec is granted just in time, by someone else, for a bounded window

```sh
# 1. no standing exec, for anyone
KUBECONFIG=$ALICE kubectl -n team-a-apps exec deploy/podinfo -- true
# forbidden: User "alice@team-a.local" cannot create resource "pods/exec"

# 2. and no hand-made shortcut either
KUBECONFIG=$BOB kubectl apply -f demos/access/handmade-debug-binding.yaml
# denied by jit-binding-lock: bob@team-a.local may not CREATE a rolebindings bound to
#         ClusterRole/platform-debug

# 3. alice files a request for herself
KUBECONFIG=$ALICE make access-request ROLE=debug NS=team-a-apps DURATION=2m \
  REASON='podinfo 5xx after 14:00, need to inspect /tmp'
NAME=<printed by the previous command>

# 4. the wrong team cannot approve it
KUBECONFIG=$CAROL make access-approve NAME=$NAME NS=team-a
# denied by access-request-approve: carol@team-b.local may not approve debug on team-a-apps

# 5. neither can the requester
KUBECONFIG=$ALICE make access-approve NAME=$NAME NS=team-a
# denied by access-request-approve: alice@team-a.local may not approve their own request

# 6. the team lead can
KUBECONFIG=$BOB make access-approve NAME=$NAME NS=team-a
# Approved; the warden moves it to Active within a second

kubectl -n team-a-apps get rolebinding -l access.k8s-base/managed-by=access-warden
# jit-alice-debug-<stamp>   ClusterRole/platform-debug   2m

make access-list
# shows the request Active with its expiresAt and approver

# 7. the window works
KUBECONFIG=$ALICE kubectl -n team-a-apps exec deploy/podinfo -- ls /tmp
make audit-exec                      # the CONNECT, with alice's email and the command

# 8. and closes itself
sleep 130
make access-list                     # phase Expired, no live binding
KUBECONFIG=$ALICE kubectl -n team-a-apps exec deploy/podinfo -- true
# forbidden again
```

Cleanup: `make access-revoke NAME=$NAME NS=team-a` (a no-op once Expired), then
`kubectl -n team-a delete accessrequest $NAME`.

## `demo-breakglass` — four eyes on cluster-admin

```sh
# nobody holds it standing
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + ([.subjects[]?|.kind+"/"+.name]|join(","))'
# only bootstrap ServiceAccounts and the k3s admin certificate, no OIDC subject

KUBECONFIG=$OPS make access-request ROLE=cluster-admin DURATION=1h \
  REASON='restore the flux-system HelmRelease history after the failed upgrade'
NAME=<printed>

# a developer cannot approve it even in their own namespace
KUBECONFIG=$BOB make access-approve NAME=$NAME NS=platform-access
# denied: cluster-admin needs platform:operator

# the requester cannot approve it
KUBECONFIG=$OPS make access-approve NAME=$NAME NS=platform-access
# denied: may not approve their own request

# the second platform engineer can
KUBECONFIG=$OPS2 make access-approve NAME=$NAME NS=platform-access
kubectl get clusterrolebinding jit-$NAME -o yaml | grep access.k8s-base/
# request-uid, expires-at, requester, approved-by, reason

KUBECONFIG=$OPS kubectl get secrets -A | head        # works for the hour
make access-revoke NAME=$NAME NS=platform-access     # end it early
KUBECONFIG=$OPS kubectl get secrets -A               # forbidden again
```

Also worth showing: a request for `cluster-admin` with `DURATION=8h` is rejected
at creation by `access-request-create` (`role cluster-admin is capped at 1h0m0s`),
and one filed outside `platform-access` is rejected too.

## `demo-privileged-guard` — data namespaces are exec-free for everyone

`team-d-analytics` and every `platform-*` namespace carry
`platform.k8s-base/privileged-access: forbidden`.

```sh
# bob gets a legitimate, approved debug grant in the data namespace
KUBECONFIG=$BOB make access-request ROLE=debug NS=team-d-analytics DURATION=10m \
  REASON='analytics pod wedged, inspect the data directory'
# denied by access-request-create: team-d-analytics belongs to no team bob is in
#         (this is the RBAC half of the guard)

# so do it the only way it can be done: ops requests it for a namespace they own
KUBECONFIG=$OPS make access-request ROLE=cluster-admin DURATION=10m \
  REASON='analytics pod wedged, inspect the data directory'
KUBECONFIG=$OPS2 make access-approve NAME=$NAME NS=platform-access

# cluster-admin and all, exec into the data namespace is still refused
KUBECONFIG=$OPS kubectl -n team-d-analytics exec deploy/podinfo -- true
# denied by privileged-access-guard: namespace team-d-analytics is labelled
#         platform.k8s-base/privileged-access=forbidden

# kubectl debug: image allow-list
KUBECONFIG=$BOB kubectl -n team-a-apps debug deploy/podinfo --image=docker.io/library/alpine:3 -it
# denied by privileged-access-guard: ephemeral containers may only run a curated debug image
KUBECONFIG=$BOB kubectl -n team-a-apps debug deploy/podinfo --image=docker.io/library/busybox:1.37 -it
# allowed, inside an active debug grant

# token minting is not a back door
KUBECONFIG=$ALICE kubectl -n team-a-apps create token flux
# denied by privileged-access-guard: a workload token is a standing credential
```

## `demo-gitops-only` — drift is caught

```sh
KUBECONFIG=$BOB kubectl apply -f demos/access/handmade-deployment.yaml
# deployment.apps/drift created
# Warning: ValidatingAdmissionPolicy 'gitops-only' ... bob@team-a.local may not CREATE
#          deployments/drift in team-a-apps by hand
KUBECONFIG=$BOB kubectl -n team-a-apps delete deployment drift

# switch the cluster to the deny binding (repos/infra/policies/base/prod/)
kubectl apply -f repos/infra/policies/base/prod/gitops-only-deny.yaml
KUBECONFIG=$BOB kubectl apply -f demos/access/handmade-deployment.yaml
# denied

# a JIT team-admin grant does not help: the policy keys on identity type, not role
# the same object through git does
cp demos/access/handmade-deployment.yaml repos/team-a/apps/podinfo/base/drift.yaml
yq -i '.resources += ["drift.yaml"]' repos/team-a/apps/podinfo/base/kustomization.yaml
make push REPO=team-a
kubectl -n team-a-apps get deployment drift     # applied by system:serviceaccount:team-a:flux

kubectl delete validatingadmissionpolicybinding gitops-only-deny
rm repos/team-a/apps/podinfo/base/drift.yaml
yq -i '.resources -= ["drift.yaml"]' repos/team-a/apps/podinfo/base/kustomization.yaml
make push REPO=team-a
```
