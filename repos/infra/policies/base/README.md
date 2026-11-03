# `repos/infra/policies/base` — native admission guardrails

Thirteen `ValidatingAdmissionPolicy` objects and fourteen
`ValidatingAdmissionPolicyBinding`s (`gitops-only` ships one policy and two
bindings)
(`admissionregistration.k8s.io/v1`) and the **two** `ConfigMap`s most of them read
parameters from (`api-path-owner` reads a registry the fleet repo renders, below).
No webhook, no controller: the API server evaluates the CEL itself, so there is
nothing to make highly available and nothing that can fail open.
Every policy sets `failurePolicy: Fail`.

`params.yaml` → `ConfigMap flux-system/platform-policy-params`:

| key | used by | meaning |
| --- | --- | --- |
| `allowedRegistries` | `allowed-registries` | comma-separated image-name prefixes, matched with `startsWith`. The file says `${ALLOWED_REGISTRIES}`; the value is the environment's, from `ConfigMap flux-system/cluster-vars` (`repos/fleet/clusters/<env>/cluster-vars.yaml`), and on `local` it ends with the k3d registry `k3d-local-dev-registry:5000/` |
| `platformWriters` | `team-baseline-lock`, `team-namespace-labels` | comma-separated `system:serviceaccount:<ns>:<name>` usernames allowed to write platform-owned objects |
| `unprefixedTeamNamespaces` | `team-namespace-labels` | comma-separated namespaces a team may own without the `<team>-` name prefix (`public-api`, `partner-api`, `egress-allowlist`) |
| `bootstrapWriters` | `jit-binding-lock`, `privileged-access-guard`, `access-request-approve` | the cluster's break-glass client-certificate identities. The file says `${BOOTSTRAP_WRITERS}`, from `cluster-vars`; on `local` it is `system:admin`, which is what `kubectl auth whoami` prints for the k3d-issued admin kubeconfig. Without it `flux-bootstrap`, which creates `cluster-admin` ClusterRoleBindings under that certificate, would be denied by `jit-binding-lock` and `make up` would never finish |
| `wardenServiceAccount` | `access-request-approve`, `jit-binding-lock` | the one identity allowed to drive `status.phase` into `Active`/`Expired` and to own `jit-*` bindings |
| `debugImages` | `privileged-access-guard` | image-name prefixes an ephemeral container may use. Must stay a **subset** of `allowedRegistries`, because `allowed-registries` matches ephemeral containers too, and every entry must be preloaded by `images.mk` or `kubectl debug` fails on the image pull rather than on the policy |

`exposure-params.yaml` → `ConfigMap flux-system/platform-exposure-params`. The
exposure policies read a **second** ConfigMap because a VAP has exactly one
`paramKind`, and these keys have nothing to do with registries or
`platformWriters`:

| key | value | used by |
| --- | --- | --- |
| `dnsZone` | `${CLUSTER_DOMAIN}`, which is `local-dev.test` on `local` | `public-route-owner`, which derives `api.<zone>`, `.partners.<zone>` and the zone's label count from it |
| `ingressNamespace` | `platform-ingress` | both, in the denial messages |
| `waypointGatewayName` | `waypoint` | `team-no-direct-exposure` |
| `waypointGatewayClass` | `istio-waypoint` | `team-no-direct-exposure` |
| `forbiddenServiceTypes` | `LoadBalancer,NodePort` | `team-no-direct-exposure` |
| `publicBackendNamespaces` | `platform-identity` | `public-route-owner` |
| `reservedNamespacePrefixes` | `platform-,flux-,kube-,istio-,cert-manager,envoy-gateway-,default` | `public-route-owner` |

Both exposure bindings use `parameterNotFoundAction: Deny`.

Three of those keys — `allowedRegistries`, `bootstrapWriters`, `dnsZone` — are
written as `${VAR}` in this directory and resolved by `infra-ks`'s
`postBuild.substituteFrom` against `ConfigMap flux-system/cluster-vars`.
Every hostname quoted in the admission matrix
at the bottom of this file is therefore the **resolved** value on `local`; on
another environment the same policies derive the same shapes from that
environment's zone.

`api-path-owner` reads a **third** set of ConfigMaps, which no file in this
directory declares: the path registry the `ResourceSet teams` renders from the
`apiPaths` input of `repos/fleet/clusters/local/teams-inputs.yaml` (rendered by `repos/fleet/base/teams.yaml`). There is one
`ConfigMap flux-system/api-paths-<team>` per team that was allocated a prefix,
labelled `platform.k8s-base/registry: api-paths`, holding two keys:

| key | value | meaning |
| --- | --- | --- |
| `team` | `team-a` | the team the allocation belongs to |
| `paths` | `podinfo,catalog` | the first path segments that team may claim on `api.<zone>` |

The binding selects them all with a `paramRef.selector` and
`parameterNotFoundAction: Deny`, so an empty registry takes every public route
write offline rather than opening the URL space. The `ResourceSet` reconciles
before any team `Kustomization`, so the registry exists before the first route is
dry-run.

`platformWriters` holds exactly two identities:

- `system:serviceaccount:flux-system:flux-operator` — the flux-operator applies
  the `ResourceSet teams` output under its own ServiceAccount, so the
  `team-baseline-*` NetworkPolicy, the chart-catalog `OCIRepository`s and the
  `team-*` namespaces are created by this identity.
- `system:serviceaccount:flux-system:kustomize-controller` — applies the
  `infra` and `operators` artifacts. The sharded kustomize-controllers reuse
  this one ServiceAccount (flux-operator's shard kustomization `nameSuffix`es
  the Deployment and `$patch: delete`s the
  ServiceAccount/ClusterRole/ClusterRoleBinding), so one entry covers every
  controller however many shards there are. Team `Kustomization`s set
  `serviceAccountName: flux`, so a shard reconciling team content is seen as
  `system:serviceaccount:<team>:flux` and is correctly denied.

A human cluster-admin is *not* in the list. That is intentional — the point of
`team-baseline-lock` is to stop anyone, including devops at a terminal, from
hand-editing a baseline object. The escape hatch is to add an identity to the
ConfigMap through a reviewed change to this directory.

## The policies

| Policy | Matches | Blocks | Applies to | Action |
| --- | --- | --- | --- | --- |
| `team-shard-label` | `kustomizations`, `helmreleases`, `ocirepositories`, `helmrepositories`, `gitrepositories`, `helmcharts`, `buckets` — CREATE/UPDATE | a Flux object whose `sharding.fluxcd.io/key` label is missing or does not equal the namespace's `platform.k8s-base/shard` label | namespaces with `platform.k8s-base/team` that also carry `platform.k8s-base/shard` (any writer, teams and platform alike) | **Deny** |
| `team-service-account` | `kustomizations`, `helmreleases` — CREATE/UPDATE | nothing; warns when `spec.serviceAccountName != flux` | namespaces with `platform.k8s-base/team` | Warn + Audit |
| `team-baseline-lock` | `networkpolicies` — CREATE/UPDATE/**DELETE** | any write to an object whose name starts with `team-baseline` | namespaces with `platform.k8s-base/team`, every user except `platformWriters` | **Deny** |
| `team-namespace-labels` | `namespaces` — CREATE/UPDATE, name `team-*` **or** carrying a `platform.k8s-base/team` label | a team namespace without `platform.k8s-base/team`, without `pod-security.kubernetes.io/enforce`, or whose name is neither its team name, nor `<team>-*`, nor listed in `unprefixedTeamNamespaces` | cluster-wide (no namespace selector — namespaces are cluster-scoped). UPDATE is exempt for `platformWriters` | **Deny** |
| `allowed-registries` | `pods` — CREATE | a pod with any container / initContainer / ephemeralContainer image not prefixed by an entry of `allowedRegistries` | namespaces with `platform.k8s-base/team` | **Deny** |
| `team-no-direct-exposure` | `services`, `ingresses`, `gateways`, `httproutes`, `grpcroutes`, `tlsroutes` — CREATE/UPDATE | a `Service` of type `LoadBalancer` or `NodePort`; any `Ingress`; a `Gateway` whose class is not `istio-waypoint`; a route that `parentRef`s anything but the namespace's own `waypoint` Gateway | namespaces with `platform.k8s-base/team`, **`public-api` included** — except that the route rule is lifted for namespaces labelled `platform.k8s-base/role` `public-edge` or `partner-edge` | **Deny** |
| `public-route-owner` | `httproutes`, `grpcroutes` — CREATE/UPDATE | a route with no `platform.k8s-base/owner-team` label; a route whose `platform.k8s-base/auth` label is missing or not one of `none`/`jwt`/`api-key`; an `auth` class that does not match the namespace's edge (`api-key` only on `partner-edge`, `none`/`jwt` only on `public-edge`); a hostname outside `dnsZone`; a `partner-edge` route with anything but exactly one hostname; a hostname outside its edge's host class (`public-edge`: `api.<zone>`, or a single-label name when the owner is `platform` and every backend is in `publicBackendNamespaces` or the route only redirects. `partner-edge`: exactly one `<partner>.partners.<zone>`); a `backendRefs` namespace that is neither the owner team's nor one of `publicBackendNamespaces`, or that carries a reserved platform prefix | namespaces labelled `platform.k8s-base/role` `public-edge` **or** `partner-edge` | **Deny** |
| `api-path-owner` | `httproutes` — CREATE/UPDATE | a route whose `owner-team` is a team in the path registry and that does not match every rule with a `PathPrefix` whose first segment is one of that team's allocated prefixes; and any route, whatever its owner, that claims a prefix allocated to a *different* team | namespaces labelled `platform.k8s-base/role: public-edge` (only `public-api`) | **Deny** |
| `access-request-create` | `accessrequests` — CREATE | an AccessRequest filed for someone else, for a namespace outside the requester's teams, from the wrong home namespace, over the per-role duration cap, or with a reason under 10 characters | cluster-wide (no selector — requests live in team home namespaces and in `platform-access`) | **Deny** |
| `access-request-approve` | `accessrequests/status` — UPDATE | self-approval, an `approvedBy` that is not the patching user, an approver whose groups do not cover the request, a phase transition reserved for the warden (`Active`, `Expired`), and an approval that pre-sets `expiresAt` or `bindingRef` | cluster-wide | **Deny** |
| `jit-binding-lock` | `rolebindings`, `clusterrolebindings` — CREATE/UPDATE/**DELETE** | anyone but the warden and the platform/bootstrap writers binding `platform-debug`, `platform-team-admin` or `cluster-admin`; any warden-written binding that is not named `jit-<request>` with an `access.k8s-base/request-uid`; anyone else writing a `jit-*` name | cluster-wide (ClusterRoleBindings are cluster-scoped) | **Deny** |
| `privileged-access-guard` | `pods/exec`, `pods/attach`, `pods/portforward` — **CONNECT**; `pods/ephemeralcontainers` — UPDATE; `serviceaccounts/token` — CREATE | any session into a namespace labelled `platform.k8s-base/privileged-access: forbidden`, for **everyone** including an approved grant and a fresh `cluster-admin`; an ephemeral container whose image is not in `debugImages`; a token minted by a human in a namespace carrying `platform.k8s-base/team` | cluster-wide | **Deny** |
| `gitops-only` | `deployments`, `statefulsets`, `daemonsets`, `replicasets`, `jobs`, `cronjobs`, `pods`, `services`, `configmaps`, `secrets`, `serviceaccounts`, `networkpolicies`, `httproutes`, `authorizationpolicies` — CREATE/UPDATE/DELETE | a write by an identity that is neither a ServiceAccount nor a node | namespaces with `platform.k8s-base/team` | **Warn** here, **Deny** on prod |

### The five access policies, in one sentence each

- The four access policies are the **ceiling**, RBAC is the **floor**. A JIT
  `team-admin` grant does not bypass `gitops-only`, and no grant at all bypasses
  `privileged-access-guard`: the first keys on *identity type*, the second on the
  *namespace label*, and neither reads the binding.
- `gitops-only` ships **one** policy and **two** bindings. `gitops-only-warn` is
  in this directory; `gitops-only-deny` is in `prod/`, which no
  `kustomization.yaml` here references, so it reaches a cluster only through a
  prod `envs/<env>/` of this unit. `Warn` and `Deny` cannot be combined in one
  binding, and a single binding cannot be made conditional on a cluster-level setting — two
  bindings and a per-environment choice is the whole mechanism.
- `gitops-only` exempts `system:serviceaccount:` **and** `system:node:`. It does
  not exempt `system:admin`: the break-glass certificate is deliberately caught,
  because drift from a terminal is exactly what the policy is for.
- `privileged-access-guard` is the only policy here matching `CONNECT`. The
  admitted object differs per subresource — `PodExecOptions`,
  `PodAttachOptions`, `PodPortForwardOptions`, and for
  `pods/ephemeralcontainers` (an **UPDATE**, not a CONNECT) the whole `Pod`.
  Every validation therefore guards on `variables.sub` first, and only the
  ephemeral-container rule touches `object.spec`.
- `jit-binding-lock` must list the bootstrap identities, or `flux-bootstrap` is
  denied and the cluster never comes up.
- `access-request-create` enforces the duration cap, not the warden alone,
  because VAP has no `now()`: the cap is a property of the request string, and
  the expiry is a property of the grant. The warden clamps a second time so a
  policy that is somehow absent cannot widen a window.

Notes:

- `Deny` and `Warn` cannot be combined in one binding, which is why
  `team-service-account` is a separate, advisory policy rather than a second
  validation on `team-shard-label`.
- `allowed-registries` matches `pods`, not workload kinds: the Deployment /
  StatefulSet / CronJob controllers all create the Pod, so one rule covers everything a team can ship. The consequence is that
  the denial surfaces in the ReplicaSet/Job events, not on the `kubectl apply`
  of the Deployment.
- Images must be fully qualified. A bare `busybox:1.37` matches no prefix and is
  denied; use `docker.io/library/busybox:1.37`.
- `team-baseline-lock` is the only policy matching `DELETE`, where the API
  server passes `object == null` and `oldObject` as the stored object — hence the
  `object == null ? oldObject : object` variable.

## The chart catalog is not locked

The `teams` ResourceSet stamps one `OCIRepository <chart>-chart` into every
team workload namespace — the platform chart catalog, defined at the top of the
fleet repo's `teams.yaml`. Those objects carry `platform.k8s-base/catalog: "true"`,
which is purely informational: no policy matches on it.

Not protecting them is deliberate. A team holds `admin` in its workload
namespaces and *can* repoint a stamped source at another chart, but the
`ResourceSet` re-applies it on the next reconcile, so the drift is self-healing,
and until then the only HelmReleases affected are that team's own. A lock here
would additionally have to exempt `source-controller`, which has to add its own
finalizer to every source it reconciles.

## CEL notes

### The two exposure policies

- **A VAP cannot look up the backend namespace.** `namespaceObject` is the
  namespace of the *admitted object* — for a route in `public-api` that is
  `public-api`, never `team-a-apps`. So `public-route-owner` cannot read the
  backend namespace's `platform.k8s-base/team` label and the check is a **name**
  check instead: the namespace must be the owner team or start with `<owner>-`.
  The platform exception is a name check too — membership of
  `publicBackendNamespaces`, not a label. `platform.k8s-base/public-backend:
  allowed` is still stamped on `platform-identity` as documentation of intent,
  but nothing enforces on it.
- `reservedNamespacePrefixes` closes the hole the name check would otherwise
  leave: a route labelled `owner-team: platform` would match every `platform-*`
  namespace by prefix. A backend namespace carrying a reserved prefix is admitted
  only if it is explicitly in `publicBackendNamespaces`.
- `team-no-direct-exposure` matches four unrelated kind groups in one policy,
  so every validation is guarded by `variables.resource`
  (`request.resource.resource`) and every field read is wrapped in `has(...)`.
  CEL's `&&` absorbs errors in the other operand when one side is `false`, and
  `object` is a `dyn` map, so `has(object.spec.type)` is safe to evaluate against
  a `Gateway`. Splitting it into four policies would be three more bindings for
  one guarantee.
- The route rule is lifted inside a sec-ops edge namespace — role `public-edge`
  or `partner-edge` — by a `variables.isSecOpsEdge` guard read from
  `namespaceObject`, **not** by a binding-level `NotIn`: the binding has to keep
  matching those namespaces so the Service, Ingress and Gateway rules still apply
  there. Getting that wrong frees the public edge to publish its own
  LoadBalancer. `partner-edge` is in the guard from X0 onward even though no
  namespace carries the role until X2; without it the partner edge could not
  `parentRef` the `partner` Gateway at all.
- **The hostname rule is a host *class* keyed on the namespace, not on the
  owner.** Round two read "the label immediately before the zone" as the owning
  team; round three retired per-team hostnames, so the rule now switches on
  `namespaceObject.metadata.labels['platform.k8s-base/role']`. A `public-edge`
  route serves `api.<zone>` — the one public host, with each team's API under an
  allocated path prefix — and a `partner-edge` route serves exactly one
  `<partner>.partners.<zone>` (the first label may be neither empty nor `*`, so a
  wildcard cannot stand in for a partner). The zone's label count still comes
  from `dnsZone`, which is what makes `api.` and `.partners.` derived rather than
  written twice.
- **Two platform routes are not on `api.`, and both are admitted by a narrow
  escape rather than a name exception.** A single-label hostname is legal on the
  public edge only when the owner is `platform` *and* either every `backendRefs`
  namespace is in `publicBackendNamespaces` (`dex.local-dev.test` → `dex` in
  `platform-identity`) or the route has no `backendRefs` at all and every filter
  it carries is a `RequestRedirect` (`*.local-dev.test` → the HTTP→HTTPS
  redirect). The second half is the `redirectOnly` variable: a route that only
  redirects reaches no Service, so letting it keep the zone wildcard gives away
  nothing. Both conditions are `variables`, which CEL evaluates lazily, so the
  redirect route never pays for the backend walk and the other way round.
- **`api-path-owner` is two mirror-image validations, not one.** A VAP binding
  with a `paramRef.selector` is evaluated **once per matching param** and the
  request is admitted only if every evaluation passes, so no single expression
  ever sees the whole registry. The first validation fires only on the param
  whose `team` equals the route's `owner-team` and demands that every rule match a
  `PathPrefix` on one of that team's prefixes — that is what rejects an
  unallocated prefix, an `Exact` path and a rule with no `matches`. The second
  fires on every *other* param and demands that the route claim none of that
  team's prefixes — that is what rejects `owner-team: platform` reaching for
  `/orders`. Together they make a prefix single-owner; separately neither does.
  The cost of the per-param shape is that a prefix allocated to two teams is no
  longer a render error: it makes **both** teams' routes undeployable, which is a
  loud failure in a different place.
- `api-path-owner` matches `httproutes` only. A path prefix is an HTTP concept and
  a `GRPCRoute` has no `spec.rules[].matches[].path`, so including it would deny
  every GRPCRoute a registered team ever writes. Nothing in the design ships one;
  `public-route-owner` still covers both kinds.
- Empty-collection literals are avoided throughout: every list walk is written
  `!has(x) || x.all(...)` rather than `(has(x) ? x : []).all(...)`. Prefix lists
  come from `params.data[...].split(',')` and are matched with `exists(...)`,
  never with an `in` against an inline list literal.

### General

Details the policy files deliberately do not carry as comments:

- `namespaceObject` is populated for namespaced kinds, so `team-shard-label`
  reads the namespace's `platform.k8s-base/shard` label directly. It is null for
  `namespaces` themselves, which is why `team-namespace-labels` derives
  everything from `object` and binds without a `namespaceSelector`.
- `team-shard-label` is **permissive when the namespace carries no shard
  label** (`variables.expected == '' || ...`). Shards are decoupled from teams, so the expected value is namespace state that
  the `ResourceSet` stamps rather than something derivable from the namespace
  name. Without the guard, a namespace the ResourceSet has not yet relabelled —
  during a shard move, or during the round-one-to-round-two migration — would
  deny every write to the Flux objects that the same reconcile is trying to
  relabel, and the move could never complete. Flux's apply staging puts
  `Namespace` objects in an earlier stage than the rest, so in steady state the
  label is always there and the rule bites.
- On `DELETE` the API server passes `object == null` and `oldObject` as the
  stored object — hence `team-baseline-lock`'s `object == null ? oldObject : object`.
- Label accessors are guarded ternaries rather than `has(...) ? labels : {}`: an
  empty map literal makes the CEL type checker fall back to `map(dyn, dyn)`.
- `allowed-registries` uses three separate clauses rather than one concatenated
  image list for the same reason — and because under `failurePolicy: Fail` an
  expression error would deny every pod in the cluster.
- `team-namespace-labels` exempts `platformWriters` on `UPDATE` only: the
  `ResourceSet` re-applies every `team-*` namespace on each reconcile, while a
  devops-authored namespace must still be born with its labels.
- `team-service-account` is a separate advisory policy because `Deny` and
  `Warn` cannot be combined in one binding.

## Denied one-liners (verbatim, for the integration phase and `demo-vap`)

Each command must be **rejected by the API server**, with the message in the
comment. They assume E3 has run (team namespaces and the `flux` ServiceAccounts
exist).

```sh
# 1. team-shard-label — team-a parks a HelmRelease on the other shard
kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps apply -f - <<'EOF'
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: wrong-shard
  namespace: team-a-apps
  labels:
    sharding.fluxcd.io/key: shard-2
spec:
  interval: 10m
  serviceAccountName: flux
  chartRef: { kind: OCIRepository, name: podinfo-chart }
EOF
# denied: ... must carry label sharding.fluxcd.io/key=shard-1 but has "shard-2"

# 2. team-shard-label — no shard label at all
kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps create -f - <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: unsharded, namespace: team-a-apps }
spec:
  interval: 10m
  prune: true          # required by the CRD schema: schema validation runs
                       # before the policy, so omitting it hides the deny
  serviceAccountName: flux
  sourceRef: { kind: OCIRepository, name: team-a-source }
  path: ./
EOF
# denied: Kustomization team-a-apps/unsharded must carry label sharding.fluxcd.io/key=shard-1
#         but has no shard label; ...

# 3. team-baseline-lock — team deletes its baseline NetworkPolicy
kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps \
  delete networkpolicy team-baseline-default-deny
# denied: team-baseline-* objects are platform-owned: system:serviceaccount:team-a:flux may not DELETE networkpolicies/team-baseline-default-deny ...

# 4. team-baseline-lock — a cluster-admin edits the baseline NetworkPolicy.
#
# A cluster-admin is deliberately not in platformWriters, so this is the case
# where the POLICY denies rather than RBAC:
kubectl -n team-a-apps patch networkpolicy team-baseline-default-deny \
  --type=merge -p '{"spec":{"policyTypes":["Ingress"]}}'
# denied: team-baseline-* objects are platform-owned: system:admin may not UPDATE
#         networkpolicies/team-baseline-default-deny in namespace team-a-apps ...

# 5. allowed-registries — image from an unknown registry.
#
# The pod has to be `restricted`-compliant or PodSecurity rejects it FIRST and the
# policy is never reached (`kubectl run x --image=evil.example.com/x:1` only ever
# shows a PodSecurity error):
kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps create -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: x, namespace: team-a-apps }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 65534, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: x
      image: evil.example.com/x:1
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
EOF
# denied: image registry not in the platform allow-list. Images must start with one of: ghcr.io/,...

# 6. team-namespace-labels — devops creates a team namespace without labels
kubectl create namespace team-e
# denied: namespace team-e is team-named but has no platform.k8s-base/team label; ...

# 7. team-namespace-labels — labelled but PSA missing
kubectl create -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: team-e
  labels: { platform.k8s-base/team: team-e }
EOF
# denied: namespace team-e must set pod-security.kubernetes.io/enforce explicitly ...

# 8. team-namespace-labels — name does not match its team label
kubectl create -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: team-e-apps
  labels:
    platform.k8s-base/team: team-a
    pod-security.kubernetes.io/enforce: restricted
EOF
# denied: namespace team-e-apps claims team team-a but is not named team-a or team-a-<suffix>
```

Must be **allowed** (regression guards — a guardrail that blocks the platform is a outage):

```sh
# the shape the ResourceSet actually ships
kubectl auth can-i --as=system:serviceaccount:flux-system:flux-operator \
  create namespaces                                         # yes
kubectl --as=system:serviceaccount:flux-system:flux-operator create -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: team-a-scratch
  labels:
    platform.k8s-base/team: team-a
    pod-security.kubernetes.io/enforce: restricted
EOF
kubectl delete namespace team-a-scratch

# a correctly sharded, correctly impersonating team object: no deny, no warning
kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps apply --dry-run=server -f - <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ok
  namespace: team-a-apps
  labels: { sharding.fluxcd.io/key: shard-1 }
spec:
  interval: 10m
  prune: true
  serviceAccountName: flux
  sourceRef: { kind: OCIRepository, name: team-a-source }
  path: ./
EOF

# a team-owned NetworkPolicy that is NOT named team-baseline-*: allowed
kubectl --as=system:serviceaccount:team-a:flux -n team-a-apps apply --dry-run=server -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: my-own-policy, namespace: team-a-apps }
spec: { podSelector: {}, policyTypes: [Ingress] }
EOF
```

## Validation without a cluster

```sh
kustomize build repos/infra/policies/base
kubeconform -strict -ignore-missing-schemas $(find repos/infra/policies/base -name '*.yaml')
```

CEL itself is only checked by the API server, so every expression above is
re-run against the live cluster in the integration phase (risk R8).

## Integration result (Phase 3)

Every command above was run against the live cluster. All five policies behave as
documented, and risk **R8** is closed: `namespaceObject` is populated for
namespaced kinds, so `variables.expected` resolves and no fallback to
`startsWith(request.namespace, ...)` was needed. Round two re-ran the
`team-shard-label` cases against `platform.k8s-base/shard` with the same verdicts; `team-a-apps` is on `shard-1`.

| Policy | Command | Result |
| --- | --- | --- |
| `team-shard-label` | Kustomization with `sharding.fluxcd.io/key: shard-1` in `team-a-apps` | **allowed** |
| `team-shard-label` | HelmRelease labelled `shard-2` in `team-a-apps` | **denied** - `must carry label sharding.fluxcd.io/key=shard-1 but has "shard-2"` |
| `team-shard-label` | Kustomization with no shard label | **denied** - `but has no shard label` |
| `team-service-account` | Kustomization without `serviceAccountName` | **allowed with a warning** - `should set spec.serviceAccountName: flux` |
| `team-baseline-lock` | team SA deletes `team-baseline-default-deny` | **denied** - `team-baseline-* objects are platform-owned: system:serviceaccount:team-a:flux may not DELETE ...` |
| `team-baseline-lock` | cluster-admin patches `networkpolicy/team-baseline-default-deny` | **denied** - `system:admin may not UPDATE networkpolicies/...` |
| `team-baseline-lock` | team SA applies `networkpolicy/my-own-policy` | **allowed** |
| `allowed-registries` | restricted-compliant pod, `evil.example.com/x:1` | **denied** - `image registry not in the platform allow-list` |
| `allowed-registries` | same pod, `docker.io/library/busybox:1.37` | **allowed** |
| `team-namespace-labels` | `kubectl create namespace team-e` | **denied** - `is team-named but has no platform.k8s-base/team label` |
| `team-namespace-labels` | `team-e` with the team label but no PSA label | **denied** - `must set pod-security.kubernetes.io/enforce explicitly` |
| `team-namespace-labels` | `team-e-apps` claiming `platform.k8s-base/team: team-a` | **denied** - `claims team team-a but is not named team-a or team-a-<suffix>` |
| `team-namespace-labels` | flux-operator creates a correctly labelled `team-a-scratch` | **allowed** - the `ResourceSet` is never blocked |
| `team-namespace-labels` | `public-api` labelled `platform.k8s-base/team: team-sec-ops` | **allowed** - it is listed in `unprefixedTeamNamespaces`; the team and PSA label checks still apply to it |
| `team-no-direct-exposure` | `Service podinfo-lb` type `LoadBalancer` in `team-a-apps` | **denied** - `Service team-a-apps/podinfo-lb may not have type LoadBalancer: LoadBalancer,NodePort are reserved for the platform. Public exposure goes through an HTTPRoute in public-api (reviewed by team-sec-ops); the ingress Gateways in platform-ingress are platform-owned` |
| `team-no-direct-exposure` | team-a `HTTPRoute` with `parentRefs: platform-ingress/public` | **denied** - `HTTPRoute team-a-apps/podinfo-public-shortcut attaches to a Gateway this namespace does not own. There is no team self-service exposure: a team namespace may only parentRef its own waypoint Gateway. ...` |
| `team-no-direct-exposure` | the `waypoint` Gateway the ResourceSet stamps in `team-a-apps` | **allowed** - class `istio-waypoint` |
| `team-no-direct-exposure` | the five routes sec-ops ships in `public-api` | **allowed** - the route rule is lifted for a sec-ops edge role; the Service/Ingress/Gateway rules still bite there |
| `team-no-direct-exposure` | the two routes sec-ops ships in `partner-api` | **allowed** - `isSecOpsEdge` accepts `partner-edge` as well as `public-edge`; without that widening (landed by X0) every partner route would be denied here before `public-route-owner` ever saw it |
| `team-namespace-labels` | `partner-api` labelled `platform.k8s-base/team: team-sec-ops` | **allowed** - only after `partner-api` was added to `unprefixedTeamNamespaces`; until then the `ResourceSet` sat on a dry-run failure. **A fourth sec-ops namespace needs the same edit in the same PR** |
| `public-route-owner` | `owner-team: team-a` route with a `backendRefs` into `team-b-apps` | **denied** - `HTTPRoute public-api/team-a-steals-team-b is labelled platform.k8s-base/owner-team=team-a but a backendRef points elsewhere: every backend namespace must be team-a or start with team-a-, or be one of the platform namespaces opened for public backends (platform-identity)` |
| `public-route-owner` | `owner-team: platform` route with a `backendRefs` into `flux-system` | **denied** - same message with `platform` / `platform-`; `reservedNamespacePrefixes` is what stops the `platform-` prefix matching every platform namespace |
| `public-route-owner` | `owner-team: team-a`, `auth: none`, `api.local-dev.test` + `PathPrefix /podinfo` into `team-a-apps` | **allowed** |
| `public-route-owner` | the same route with no `platform.k8s-base/auth` label | **denied** - `HTTPRoute public-api/team-a-forgot-auth must carry the label platform.k8s-base/auth with one of none, jwt, api-key. It is what selects the sec-ops SecurityPolicy for the route, so a route without it would be served with no authentication class at all` |
| `public-route-owner` | the same route with `auth: api-key`, in `public-api` | **denied** - `... is labelled platform.k8s-base/auth=api-key in a namespace whose platform.k8s-base/role is public-edge. The public edge serves none and jwt; the partner edge serves api-key only` |
| `public-route-owner` | `auth: none` route for `partner-a.partners.local-dev.test` in **`public-api`** (`demos/partner/partner-route-on-public.yaml`) | **denied** - `... claims a hostname its edge does not serve. A route in a public-edge namespace serves api.local-dev.test ... A route in a partner-edge namespace serves <partner>.partners.local-dev.test` |
| `public-route-owner` | `auth: jwt` route in **`partner-api`**, correct in every other respect (`demos/partner/jwt-route-on-partner.yaml`) | **denied** - `... is labelled platform.k8s-base/auth=jwt in a namespace whose platform.k8s-base/role is partner-edge. The public edge serves none and jwt; the partner edge serves api-key only` |
| `public-route-owner` | the two partner routes sec-ops ships in `partner-api` | **allowed** - one hostname each in the partner subzone, `auth: api-key`, `owner-team: team-b` and a backend in `team-b-apps` |
| `public-route-owner` | `owner-team: platform`, `auth: none` route for `dex.local-dev.test` into `platform-identity` | **allowed** - a single-label hostname is legal for a `platform`-owned route whose every backend is in `publicBackendNamespaces`. This is the shape H5 needed for the Dex login page, and round three kept it unchanged |
| `public-route-owner` | `owner-team: platform`, `auth: none` route for `*.local-dev.test` with no `backendRefs` and one `RequestRedirect` filter | **allowed** - the `redirectOnly` escape. A route that reaches no Service gives nothing away by holding the zone wildcard, and the `http` listener needs exactly one such route |
| `api-path-owner` | `owner-team: team-a`, `PathPrefix /orders` on `api.local-dev.test` | **denied** - `HTTPRoute public-api/team-a-claims-orders is labelled platform.k8s-base/owner-team=team-a but claims a path outside the prefixes allocated to that team. Every rule must match a PathPrefix whose first segment is allocated to team-a in the fleet repo (teams.yaml apiPaths); the allocation for team-a is podinfo,catalog`. The same object also fails the mirror validation against `api-paths-team-b`; the API server reports one of the two, so `demo-exposure` greps the phrase they share |
| `api-path-owner` | the five routes sec-ops ships in `public-api` | **allowed** - `/podinfo` and `/catalog` for team-a, `/orders` for team-b, and the two `platform`-owned routes, whose owner matches no registry entry and which claim no team's prefix |

## Integration result (pass two: the five access policies)

Exercised live against `local-dev` with real OIDC identities, not `--as`, except
where a `system:masters` impersonation was needed to get past RBAC and reach
admission at all.

| Policy | Command | Result |
| --- | --- | --- |
| `privileged-access-guard` | `kubectl --as=tester --as-group=system:masters -n <labelled ns> exec <pod>` | **denied** - `namespace default is labelled platform.k8s-base/privileged-access=forbidden, so tester may not exec into pod guardprobe even with an approved AccessRequest; read its logs and events instead` |
| `privileged-access-guard` | the same `exec` in an **unlabelled** namespace | **allowed** - no warning, no denial |
| `privileged-access-guard` | the same `exec` as `system:admin` in the labelled namespace | **allowed** - `bootstrapWriters` is the one exemption, and `make up` needs it |
| `privileged-access-guard` | `port-forward` and `attach` into the labelled namespace | **denied** - same message with `portforward` / `attach` |
| `privileged-access-guard` | `kubectl debug pod/... --image=docker.io/library/alpine:3 --profile=restricted` | **denied** - `ephemeral containers may only run a curated debug image. Allowed prefixes: docker.io/library/busybox:,ghcr.io/stefanprodan/podinfo: (fully qualified names only -- a bare 'busybox' matches no prefix)` |
| `privileged-access-guard` | the same with `--image=docker.io/library/busybox:1.37` | **allowed** |
| `privileged-access-guard` | `KUBECONFIG=<alice> kubectl -n team-a-apps create token flux` | **denied** - `a workload token is a standing credential that outlives any AccessRequest window` |
| `privileged-access-guard` | `kubectl -n flux-system create token kustomize-controller` (no team label) | **allowed** |
| `jit-binding-lock` | `kubectl apply --dry-run=server` of a `cluster-admin` ClusterRoleBinding as `system:admin` | **allowed** - the `flux-bootstrap` regression guard; a wrong `bootstrapWriters` makes `make up` unbootstrappable |
| `jit-binding-lock` | `kubectl auth can-i --as=system:serviceaccount:flux-system:kustomize-controller create clusterrolebindings` | **yes** |
| `jit-binding-lock` | `KUBECONFIG=<bob> kubectl apply -f demos/access/handmade-debug-binding.yaml` | **denied by RBAC first** - `attempting to grant RBAC permissions not currently held: {Resources:["pods/ephemeralcontainers"] ...}`. Authorization runs before admission, so a team admin never reaches this policy |
| `jit-binding-lock` | the same file as `--as=tester --as-group=system:masters` | **denied** - `tester may not CREATE rolebindings/i-grant-myself-debug bound to ClusterRole/platform-debug; platform-debug, platform-team-admin and cluster-admin are granted only through an approved AccessRequest reconciled by system:serviceaccount:platform-access:access-warden` |
| `access-request-create` | `KUBECONFIG=<ops> make access-request ROLE=cluster-admin DURATION=8h` | **denied** - `role cluster-admin is capped at 3600s but spec.duration is 8h` |
| `access-request-create` | `KUBECONFIG=<bob> make access-request ROLE=debug NS=team-d-analytics` | **denied** - `may request access to team-d-analytics only from the home namespace of a team it belongs to` |
| `access-request-approve` | `KUBECONFIG=<carol> make access-approve` on alice's team-a request | **denied** - the approver's groups do not cover the request |
| `access-request-approve` | `KUBECONFIG=<alice> make access-approve` on her own request | **denied** - `alice@team-a.local may not approve their own request for debug on team-a-apps; four eyes are required` |
| `access-request-approve` | `KUBECONFIG=<bob> make access-approve` on the same request | **allowed** - the warden moves it Approved -> Active within a second |
| `gitops-only` | `KUBECONFIG=<bob> kubectl apply -f demos/access/handmade-deployment.yaml` | **allowed with a warning** - `bob@team-a.local may not CREATE deployments/drift in team-a-apps by hand: workload objects in a team namespace arrive only through a signed artifact applied by that team Flux ServiceAccount` |
| `gitops-only` | the same apply with `prod/gitops-only-deny.yaml` applied | **denied**, same message |
| `gitops-only` | the same Deployment through `make push REPO=team-a` | **allowed** - the writer is `system:serviceaccount:team-a:flux` |
| `gitops-only` | `make up` from clean, then every `ValidatingAdmissionPolicyWarning` event | **no `system:*` identity warned** - H13 closed; the ServiceAccount and node exemptions cover every controller, the warden included |

### Two things the staged rollout taught

- **A `Warn` binding is invisible on `CONNECT`.** Admission warnings ride a
  response header, and `kubectl exec` / `port-forward` upgrade the connection
  instead, so the warning is never printed. `privileged-access-guard` in
  `[Warn, Audit]` looks exactly like a policy that is not firing. The only
  observable mode for the CONNECT rules is `Deny` — H6's staged rollout
  therefore has to read the audit log, or go straight to `Deny` on a scratch
  namespace, which is what was done here.
- **`namespaceObject` *is* populated on the CONNECT subresources** (risk H11).
  The denial message interpolates `request.namespace` and the decision keys on
  the namespace label, and both behaved: labelled namespace denied, unlabelled
  allowed, from the same identity, in the same second. The documented fallback
  (an `execFreeNamespaces` key in params, matched against `request.namespace`)
  is **not needed** and was not added.
