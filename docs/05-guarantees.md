# Guarantees

> **Who this is for.** Reviewers, auditors, and anyone deciding whether to
> trust the design. **Afterwards you can** state each promise the cluster
> makes, explain what enforces it, and run the command that shows it holding.

## How to read this page

A guarantee here is not a policy document. It is a claim that the cluster
refuses something, backed by a demo that tries to do that something and
asserts the refusal. The demos live in `scripts/demos.mk`; `make demo-<name>`
runs one and `make demo-all` runs all twenty-two and prints a PASS or FAIL
line for each. Transcripts land in `tmp/demos/<name>.log`.

Each entry below has three parts. **The promise**, in one sentence. **What
enforces it**, so you know which component to look at and why it cannot be
bypassed. **How you see it**, meaning the demo and what its output looks
like when the promise holds. If you only have time for one thing per
entry, run the demo.

The demos deliberately break things and put them back, so they only run on
the laptop cluster. A real environment runs `make smoke` instead, which
asserts the three most important promises without touching anything.

## Tenancy: a team stays inside its own lines

### A team's content lands only in its own namespaces

*What enforces it.* The team's Flux Kustomization applies as
`system:serviceaccount:<team>:flux`, and that service account is bound as
`admin` only in the team's workload namespaces. When a manifest names
another namespace, the API server's ordinary RBAC refuses the write. No
custom code is involved, which is why this one is hard to get wrong.

*How you see it.* `make demo-misconfig-namespace` pushes a ConfigMap whose
manifest says `namespace: team-a-apps` as team-b, attaches it, and watches
team-b's Kustomization go `Ready=False` with:

```
configmaps "stray" is forbidden: User "system:serviceaccount:team-b:flux"
cannot create resource "configmaps" in API group "" in the namespace "team-a-apps"
```

and then shows that `team-a-apps` has no ConfigMap named `stray`. The
mistake stopped on team-b's own reconcile.

### An artifact that is unsigned, or signed with the wrong key, is never applied

*What enforces it.* Every Flux `OCIRepository` carries a `verify` block
naming a Secret with one cosign public key. Verification happens before the
content is read.

*How you see it.* `make demo-signature` pushes with `SIGN=0` and then with
`SIGN_AS=<another team>`. Both times the source reports
`SourceVerified: False` and the Kustomization keeps applying the last good
revision.

### A secret is never plaintext in git

*What enforces it.* Three things together. SOPS encrypts the values of any
`*.enc.yaml` to the team's age public key. The private key exists only as a
Secret in the team's home namespace, injected by the platform, so Flux can
decrypt and a laptop cannot. And `make env-check`, which runs before every
push, refuses any Secret under `repos/` whose file does not contain `ENC[`.

*How you see it.* `make demo-sops` shows the committed file is ciphertext,
that the Secret in the cluster has the real value, and that a file
encrypted to the wrong recipient fails to decrypt.

### Pods run restricted unless the platform says otherwise

*What enforces it.* Pod Security Admission is configured at the API server
with `restricted` as the default for every namespace. A namespace can carry
a different level only through the fleet input, which the platform reviews.

*How you see it.* `make demo-psa` ships a deployment with `privileged: true`
and `hostPID: true`. The Deployment is created but its ReplicaSet cannot
create a pod; the event reads `violates PodSecurity "restricted:latest"` and
lists every violation.

### A team cannot step off its shard, pull from an unknown registry, or touch its baseline

*What enforces it.* Three `ValidatingAdmissionPolicy` objects, evaluated by
the API server itself. `team-shard-label` denies a Flux object whose shard
label does not match the namespace's. `allowed-registries` denies a pod
whose image prefix is not on the list. `team-baseline-lock` denies any write
to an object named `team-baseline-*` by anyone except the platform's own
identities, and a human cluster-admin is deliberately not on that list.

*How you see it.* `make demo-vap` applies a HelmRelease labelled with the
wrong shard and a pod with an image from `evil.example.com`, both as the
team's own reconciler; both are denied with messages that say what to do.
It also server-dry-runs a correct object to prove the guardrail does not
block the happy path, because a guardrail that blocks the platform is an
outage.

### A shard is an operational choice, not a team boundary

*What enforces it.* Nothing has to; the point is that the design keeps the
two decoupled. Two sets of controllers serve four teams, no controller is
named after a team, and the shard is one word in the fleet input.

*How you see it.* `make demo-shards` lists the controllers, moves team-c
from `shard-2` to `shard-1` by editing one line and pushing the fleet repo,
waits for the other shard's controller to log team-c, and moves it back.

### Removing a team from the input does not delete its namespaces

*What enforces it.* The ResourceSet stamps every namespace with
`fluxcd.controlplane.io/prune: disabled`. Removing the input removes the
Flux objects and leaves the namespaces and everything in them.

*How you see it.* `make demo-no-prune` removes a team's input, pushes,
confirms the Kustomization is gone and the namespace is not, and restores it.

### A workload object applied by hand is caught

*What enforces it.* The `gitops-only` policy flags any create, update or
delete of a workload-shaped object in a team namespace by an identity that
is neither a service account nor a node. On this `dev` tier it warns; a
`prod` tier selects a second binding that denies. The break-glass
certificate is deliberately not exempt, because drift from a terminal is
what the policy is for.

*How you see it.* `make demo-gitops-only` applies a Deployment as bob, a
team admin, and shows the warning; applies the deny binding and shows the
refusal; then ships the same Deployment through git and shows it applied by
the team's service account.

## Traffic: nothing flows that nobody declared

### Undeclared cross-team traffic is dropped

*What enforces it.* Every workload namespace has a default-deny
`NetworkPolicy` in both directions, stamped by the platform and locked
against deletion. The drop happens on the caller's side, because the
caller's own baseline has no rule for the destination.

*How you see it.* `make demo-netpol` curls from team-b to team-c. Inside
team-b the call returns 200. To team-c curl exits 56 after ztunnel's tunnel
deadline, and Hubble shows:

```
team-b-apps/podinfo-… <> team-c-apps/podinfo-…:15008  policy-verdict:none EGRESS DENIED
```

Note the port: 15008, the mesh tunnel, never 9898.

### Pod-to-pod traffic is mTLS with a workload identity on both ends

*What enforces it.* Istio ambient with a mesh-wide `PeerAuthentication` in
`STRICT` mode. ztunnel wraps every connection; a plaintext connection to the
application port is refused.

*How you see it.* `make demo-mtls` runs a Job in `team-b-batch` that calls
`team-b-apps` six times. Every packet Cilium sees is on 15008, and ztunnel
logs `src.identity=spiffe://…/ns/team-b-batch/sa/default` and
`dst.identity=spiffe://…/ns/team-b-apps/sa/default`.

### A cross-team call needs both teams' consent, naming one identity and one route

*What enforces it.* The owner ships an allow: an ingress `NetworkPolicy` on
15008 plus an `AuthorizationPolicy` naming the caller's service account, a
method and a path. The caller ships a depends-on: an egress `NetworkPolicy`
on 15008. Both are files in their own repos.

*How you see it.* `make demo-cross-team-access` removes both halves and
shows the call reset by Cilium; restores them and shows 200; then shows a
`POST` and a different path refused with `403 RBAC: access denied`, and the
same call from a pod with the wrong service account refused the same way.

### Nothing reaches the internet except through one proxy, per host, per team, logged

*What enforces it.* The team baseline has no rule to the world. The only
exit is the egress waypoint in `platform-egress`, which is only on the path
for hosts that have a `ServiceEntry`, and each `ServiceEntry` has an
`AuthorizationPolicy` naming who may use it. The waypoint's access log is
configured to print the caller's SPIFFE identity.

*How you see it.* `make demo-egress` runs three probes from `team-b-batch`:
`api.github.com` returns 200, `example.com` times out on a Cilium drop, and a
raw IP does the same. Then it shows team-a reaching `httpbin.org` and being
refused `api.github.com` at the waypoint with a TLS error, and the
waypoint's `tcp.rbac.denied` counter going up. The log line reads:

```
caller=spiffe://cluster.local/ns/team-b-batch/sa/default sni=api.github.com …
```

### A partner's client certificate lives only in the egress namespace

*What enforces it.* For a partner that demands mutual TLS, the waypoint
terminates the pod's plaintext call and re-originates it with a certificate
from a Secret in `platform-egress`. Team namespaces hold nothing to present.

*How you see it.* `make demo-partner-egress` shows the partner container
answering `400` to anyone without the certificate, the Secret present only
in `platform-egress`, the waypoint's credential loaded (`ACTIVE`), the grant
restricted to `POST /transfers` from one service account, and the partner's
own log showing `client="CN=k8s-base-egress" verify=SUCCESS`.

## Edges: what crosses the boundary is reviewed

### Public exposure needs four parties

*What enforces it.* The platform's Gateway admits routes only from a
namespace labelled `public-edge`. Two admission policies require an owner
label, an auth class, backends in the owner's namespaces and prefixes
allocated to the owner. The owner's `ReferenceGrant` is required by Gateway
API itself for a cross-namespace backend.

*How you see it.* `make demo-exposure` applies seven deliberately wrong
objects and shows each denied by exactly one rule: a LoadBalancer Service, a
route attaching to the platform Gateway from a team namespace, a foreign
backend, a reserved backend namespace, a missing auth label, a prefix that
belongs to another team, an api-key route on the public edge. Then it
removes the `ReferenceGrant` and shows the route go unresolved, and pushes
the sec-ops repo signed with team-a's key and shows it refused.

### A secured public path needs a Dex token for the public API; an open path needs none

*What enforces it.* One `SecurityPolicy` per auth class, selected by the
route's `auth` label, which admission requires. The JWT policy pins the
audience to `public-api`.

*How you see it.* `make demo-public-auth` curls a `jwt` route with no token
(401), with garbage (401), with a token for the `kubernetes` client (403,
verified signature but wrong audience), and with a token for `public-api`
(200, and the backend received `x-user-email`). The `none` route returns
200 with no token throughout.

### A partner has its own gateway, port, certificate, keys and rate limit

*What enforces it.* A second Envoy proxy with its own Gateway on 9443
admitting routes only from `partner-edge`. Admission requires exactly one
hostname in the partner subzone and `auth: api-key`, and refuses the other
classes there and `api-key` on the public edge.

*How you see it.* `make demo-partner-api` calls two partners with and
without their keys, shows the backend receiving `x-partner-id` and never the
key, shows the two different rate limits, and applies two wrong routes that
each fail exactly one rule.

## People: identity, elevation and the record

### Humans log in with OIDC and get exactly their tier

*What enforces it.* The API server trusts Dex. Groups in the token are
bound to aggregated ClusterRoles per namespace by the fleet template. The
API server's escalation check stops an admin binding a role they do not
hold.

*How you see it.* `make demo-access` runs `kubectl auth can-i` as five real
logins: alice reads team-a and not team-b and cannot `exec` anywhere; bob
can create a RoleBinding in his namespace but cannot bind `cluster-admin`;
carol sees nothing in team-a; the viewer reads everywhere and writes
nowhere; ops is not cluster-admin and cannot read secrets.

### The audit log names the human, the group and the object

*What enforces it.* An API server audit policy records every privileged
subresource, every RBAC and access-request write, and every write in a team
namespace at `RequestResponse` level.

*How you see it.* `make demo-audit` creates and deletes a RoleBinding as bob
and shows two entries naming `bob@team-a.local`, group `team-a:admin`, and
the object body.

### Internal UIs are reached by login, not by port-forward

*What enforces it.* The internal Gateway fronts the Hubble UI with an OIDC
`SecurityPolicy`. Nobody holds `pods/portforward` standing.

*How you see it.* `make demo-internal-oidc` requests the UI, gets a 302 to
Dex, logs in, gets 200.

### `exec` is granted just in time, by someone else, for a bounded window

*What enforces it.* `platform-debug` is never bound standing. An
`AccessRequest` is created by the requester; `access-request-approve`
denies self-approval and approvers whose groups do not cover it; the warden
creates `jit-<request>` with an expiry and deletes it when due;
`jit-binding-lock` lets only the warden create such a binding.

*How you see it.* `make demo-jit` shows alice forbidden, bob denied when he
tries a hand-made binding, carol denied as the wrong team, alice denied
approving herself, bob approving, alice exec-ing, the audit entry with her
email and command, and two minutes later alice forbidden again.

### `cluster-admin` needs two platform engineers and can be revoked early

*What enforces it.* The same mechanism with a one-hour cap enforced twice,
requests allowed only from `platform-access`, and approval allowed only for
`platform:operator` who is not the requester.

*How you see it.* `make demo-breakglass` shows no standing cluster-admin
binding to any human, bob denied as approver, ops denied approving their own,
ops2 approving, ops reading secrets, `make access-revoke` ending it, and
secrets forbidden again.

### Data and platform namespaces are exec-free for everyone

*What enforces it.* `privileged-access-guard` denies `exec`, `attach`,
`port-forward` and ephemeral containers in any namespace labelled
`privileged-access: forbidden`, for every identity, including an approved
grant and a fresh cluster-admin. The label comes from the fleet input.

*How you see it.* `make demo-privileged-guard` gets ops a cluster-admin
grant, then shows `exec` into `team-d-analytics` denied anyway, `kubectl
debug` with an unlisted image denied, and a human minting a service account
token denied.

## What is designed but not yet exercised

Two things are described on these pages and have not been run:

- The keyless CI publisher in `ci/artifact-publish.yml`, because the eight
  repositories are still one tree and the file would publish the wrong
  thing from here.
- The `prod` tier's deny binding for hand-applied objects, which exists in
  `repos/infra/policies/base/prod/` and which no environment selects yet.
  `demo-gitops-only` applies it by hand to show the behaviour.

Everything else above has its expected output recorded in the demo or in
the README next to the mechanism.

## Where the detail lives

- The demos with every assertion: `scripts/demos.mk`
- Walkthroughs with expected output: `demos/*/README.md`
- The admission policies in one table: `repos/infra/policies/base/README.md`
