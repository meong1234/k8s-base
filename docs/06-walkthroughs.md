# Walkthroughs

> **Who this is for.** Someone about to do one of these tasks for the first
> time. **Afterwards you can** do the task end to end, know which files you
> touched and who reviews each, and recognise what the cluster will refuse
> and why.

Each walkthrough is told as a story with the commands in it. It says what
you are doing, what happens behind the command, what you will see, and what
it looks like when something is wrong. All of them assume a running local
cluster; [local setup](12-local-setup.md) gets you one. The examples use
team-b because it has two namespaces and appears in the most demos.
Substitute your own team.

## Ship a change

**The situation.** You own `repos/team-b/`. You want to bump podinfo's
image tag, or add a CronJob, or change a value in a HelmRelease.

**Where to put it.** Open the repo and find the unit: podinfo lives in
`apps/podinfo/`, the CronJob would be a new `batch/<name>/`. Every unit has
two halves. `apps/podinfo/base/` is what is true in every environment: the
reviewed default. `apps/podinfo/envs/local/` is what is only true on this
laptop cluster: a smaller resource request, a newer tag being tried out. If
your change should follow the service to every cluster, edit `base/`. If it
is specific to here, patch it in `envs/local/`. If you are not sure,
`base/` is usually right and the review will say so if not. A new unit also
needs one line in `clusters/local/kustomization.yaml`, the roster of what
runs here.

**Check it offline.** Before anything leaves your laptop:

```sh
make env-check
```

This builds every kustomize root in the tree and runs fifteen more checks.
The ones most likely to catch you: a Secret without `ENC[`, a `${VAR}`
that is not one of the five a team may use, a hostname or port from the
laptop in a `base/`, a unit missing from the roster. Each failure prints
which check and which file.

**Push it.**

```sh
make push REPO=team-b
```

Behind that one command: the directory is packaged as an OCI artifact with
a revision computed from the files, pushed to the local registry as
`team-b:local`, and the digest is signed with team-b's cosign key. Then the
team's Flux source is nudged so it picks the change up now rather than at
the next minute.

**Watch it land.**

```sh
flux -n team-b get source oci team-b-source     # should say SourceVerified
flux -n team-b get kustomization team-b         # should say Ready with your revision
kubectl -n team-b-apps get pods
```

**When it is wrong.** The Kustomization line is where the story is told:

- `forbidden … cannot create resource … in the namespace "team-a-apps"`:
  a manifest named a namespace that is not yours. Nothing reached that
  namespace; fix the manifest.
- `SourceVerified: False` on the source: the signature did not match. You
  signed with the wrong key, or `SIGN=0` was set.
- `image registry not in the platform allow-list`: the image needs a fully
  qualified name from one of the listed registries. A bare `busybox:1.37`
  matches nothing; write `docker.io/library/busybox:1.37`.
- `violates PodSecurity "restricted:latest"`: the pod needs
  `runAsNonRoot`, dropped capabilities, no privilege escalation and a
  seccomp profile. Copy the `securityContext` block from podinfo.

Whatever the error, the previous good revision stays applied. A bad push
never leaves you with half a release.

**On a real platform.** The push is CI on merge to main. What you do by hand
is open a pull request. Everything from the registry onward is identical.

## Add a secret

**The situation.** Your service needs a database password.

**The rule.** Secrets live in the unit's `envs/<env>/`, never in its
`base/`, with a filename ending in `.enc.yaml`. The value differs per
environment and so does the key it is encrypted to, which is why a secret
cannot be a shared default.

**Write it, then encrypt it in place.**

```sh
# write repos/team-b/apps/orders/envs/local/db.enc.yaml as an ordinary Secret manifest, then:
make team-sops-encrypt TEAM=team-b FILE=apps/orders/envs/local/db.enc.yaml
```

Open the file afterwards. `apiVersion`, `kind`, `metadata` are still
readable; every value under `data` or `stringData` is now `ENC[...]`, and a
`sops:` block at the bottom names the recipient. That is what makes the
file safe to commit and still reviewable.

**Reference and ship it.** Add the file to
`apps/orders/envs/local/kustomization.yaml`, reference it from the workload
with `envFrom` or `secretKeyRef`, and `make push REPO=team-b`. Flux decrypts
on apply using the age private key the platform injected into namespace
`team-b`.

**What you cannot do, on purpose.** You cannot decrypt the committed file
from your laptop. The repo is a one-way channel: anyone on the team can add
a secret, only the cluster can read one. If you need to change a value,
write the new plaintext and re-encrypt; if you need to see the live value,
read it from the cluster with the access your role gives you.

`repos/team-c/README.md` is the long form, including rotation.

## Call another team's service

**The situation.** team-b's `orders` workload needs `GET /api/info` from
team-a's `podinfo`.

**The idea.** Nothing flows between teams unless both teams said so, in
their own repos. The owner says who may come in and for what; the caller
says we go out there. Either side deleting its file closes the path. The
platform never opens one on a team's behalf.

```
   repos/team-b  (the caller)                        repos/team-a  (the owner)
   apps/orders/base/depends-on/team-a-podinfo.yaml   apps/podinfo/base/allow/team-b-podinfo.yaml
     NetworkPolicy depends-on-team-a-podinfo           NetworkPolicy allow-team-b-podinfo
       egress ──▶ team-a-apps on 15008                   ingress from team-b-apps ──▶ waypoint pods on 15008
                                                       AuthorizationPolicy allow-team-b-podinfo
                                                         principal …/ns/team-b-apps/sa/orders
                                                         may GET /api/info, nothing else

   caller pod ──ztunnel──15008──▶ team-a's waypoint ──▶ Service podinfo ──▶ pod
       ▲                              ▲                      ▲
       │ needs the caller's           │ needs the owner's    │ needs the Service label
       │ depends-on, or Cilium        │ allow, or Cilium     │ istio.io/use-waypoint, or the
       │ drops it on egress           │ drops it on ingress  │ AuthorizationPolicy is never consulted
```

**Step 1, the owner's half.** team-a renders the allow template into its
own repo:

```sh
# the sed line, with every placeholder, is in repos/platform/components/allow-team/README.md
# output: repos/team-a/apps/podinfo/base/allow/team-b-podinfo.yaml
```

That file holds two objects named `allow-team-b-podinfo`: a `NetworkPolicy`
admitting `team-b-apps` to team-a's waypoint on port 15008, and an
`AuthorizationPolicy` allowing principal
`cluster.local/ns/team-b-apps/sa/orders` to `GET` `/api/info` and nothing
else. Reviewed and pushed by team-a.

**Step 2, the caller's half.** team-b renders the depends-on template:

```sh
# output: repos/team-b/apps/orders/base/depends-on/team-a-podinfo.yaml
```

One `NetworkPolicy` allowing egress from `team-b-apps` to `team-a-apps` on
15008. Reviewed and pushed by team-b.

**Step 3, make the call.** From a pod running as the `orders` service
account:

```sh
kubectl -n team-b-apps exec deploy/caller -- curl -s http://podinfo.team-a-apps:9898/api/info
```

**What refusal looks like, and which it is.** Three different refusals,
each telling you which side to fix:

| You see | Which half | Fix |
| --- | --- | --- |
| curl exits 56, Hubble shows `EGRESS DENIED … :15008` | the caller has no depends-on, or the owner has no allow | ship the missing file |
| `403 RBAC: access denied`, curl exits 0 | the owner's allow exists but names a different service account, method or path | ask the owner to widen it, or use the right identity |
| works, but also works for things it should not | the owner's Service lacks the `istio.io/use-waypoint` label | the `AuthorizationPolicy` is never consulted without it |

The last row is the one to check first when a cross-team call seems too
easy. `demos/cross-team-access/README.md` walks every step with real output.

## Call something on the internet

**The situation.** A job in `team-b-batch` needs `https://api.github.com`.

**Why it does not just work.** Your pod has no route to the world. The
baseline network policy allows your own namespaces, DNS, and the egress
proxy, and nothing else. This is not a firewall to be turned off; it is the
shape of the platform.

```
   team-b-batch pod
     │ curl https://api.github.com/zen
     │   DNS ──▶ a virtual address for the ServiceEntry
     ├── ztunnel ══ HBONE 15008 ══▶ egress-waypoint (platform-egress)
     │                                 │ AuthorizationPolicy api-github-com: is team-b-batch named?  yes
     │                                 └─▶ TLS passed through by server name ──▶ api.github.com:443   200
     │                                     access log: caller=spiffe://…/ns/team-b-batch/sa/default sni=api.github.com
     │
     │ curl https://example.com        no ServiceEntry ──▶ real address ──▶ own baseline NetworkPolicy ──✗ DROPPED, timeout
     │
   team-a-apps pod
     │ curl https://api.github.com     ServiceEntry exists ──▶ waypoint ──▶ policy names team-b-batch, not team-a-apps
     │                                 ──▶ connection accepted and closed ──✗ TLS error, tcp.rbac.denied +1
```

**Step 1, ask sec-ops.** Open a pull request against `repos/team-sec-ops/`
adding one file under `edges/egress-allowlist/`, named after the host with
dots as dashes: `api-github-com.yaml`. It holds a `ServiceEntry` for the host
with the two labels that attach it to the platform's waypoint, and an
`AuthorizationPolicy` naming your namespace, or better, your service
account. Put it in `edges/egress-allowlist/base/` if the host and the
callers are the same in every environment, in
`edges/egress-allowlist/envs/local/` if not. The review checklist is in
`repos/team-sec-ops/README.md`.

**Step 2, sec-ops reviews and pushes.** Their signature on the artifact is
the approval. There is no other step.

**Step 3, call it as normal.**

```sh
kubectl -n team-b-batch logs job/egress-probe
# probe github=200
```

Behind the call: DNS resolved the host to a virtual address, ztunnel sent
the connection over the mesh to the egress waypoint, the waypoint checked
the `AuthorizationPolicy`, and passed the TLS through by its server name.
Your pod never touched the internet; the waypoint did, and its log says
`caller=spiffe://cluster.local/ns/team-b-batch/sa/default sni=api.github.com`.

**Which side refused you.** Two failures look different on purpose:

- A **timeout** (curl exit 28) and a Hubble `EGRESS DENIED`: the host is not
  on the list at all, so there was no waypoint on the path and your own
  baseline dropped it. Ask for the host.
- A **TLS error** (`unexpected eof`, curl exit 35): the host is on the list
  but your namespace is not granted. The waypoint accepted the connection and
  closed it. Ask to be added to the grant.

**When the partner needs a client certificate.** Ask sec-ops for the
`HTTP`-port shape with a `DestinationRule`: your pod speaks plaintext to the
waypoint, the waypoint presents the certificate from a Secret only it holds,
and the grant can be as narrow as `POST /transfers`. That is what
`team-b-batch`'s partner job uses and `demo-partner-egress` shows.

## Expose an API to the public

**The situation.** team-b's `podinfo` should be reachable at
`https://api.<domain>/orders/`.

**The idea.** One public hostname, and every team's API is a path prefix
on it. Four owners have to agree, and the route only works when all four
objects exist. You are the owning team; here is your part and everyone
else's.

```
   owner      object                                   says
   ─────      ──────                                   ────
   platform   Gateway public (platform-ingress)        routes may attach only from namespaces labelled public-edge
   platform   apiPaths: [orders]  in teams-inputs      /orders belongs to team-b   (ConfigMap api-paths-team-b)
   sec-ops    HTTPRoute team-b-orders (public-api)     api.<zone>/orders ──▶ podinfo in team-b-apps, auth: jwt
   team-b     ReferenceGrant allow-public-api          routes from public-api may target my Service podinfo

                 all four present ──▶ https://api.<zone>/orders/ answers
                 any one missing  ──▶ no route, or ResolvedRefs=False, or denied at admission
```

**Step 1, your consent.** In your workload namespace, a `ReferenceGrant`
that says routes from `public-api` may target your Service. The example is
`repos/team-b/apps/podinfo/base/public-consent.yaml`. Push it. Without this file,
even a perfect route serves an error, and that is your veto.

**Step 2, your prefix.** The platform has allocated `/orders` to team-b in
`repos/fleet/clusters/local/teams-inputs.yaml` under `apiPaths`. If you need
a prefix that is not allocated, that is a pull request to the fleet repo,
reviewed by the platform team. Check what is allocated with:

```sh
kubectl -n flux-system get cm -l platform.k8s-base/registry=api-paths -o yaml
```

**Step 3, the route.** Open a pull request against
`repos/team-sec-ops/edges/public-api/base/routes/` with one `HTTPRoute`. Copy
`team-b-orders.yaml`. The things the review and the admission policies will
check:

- hostname `api.${CLUSTER_DOMAIN}`, nothing else
- every rule a `PathPrefix` starting with your prefix, plus a `URLRewrite`
  so your backend serves `/` and does not need to know its public prefix
- label `platform.k8s-base/owner-team: team-b`
- label `platform.k8s-base/auth: none` for an open API or `jwt` for one
  behind a login
- every backend in a namespace that is yours
- the CORS filter and the security response-header filter copied in
  (admission refuses a route without the CORS one)

**Step 4, sec-ops reviews and pushes.** The moment the route is merged it
is rate-limited, because the rate limit is on the Gateway, and it is
*closed*: the edge's `AuthorizationPolicy` denies any prefix on the public
host without a token. A `jwt` route needs nothing more. An `auth: none`
route is opened by adding its prefix to that policy's `notPaths`, in the
same review. There is no "forgot the policy" state, only "not yet opened".

**Calling a secured route.** A `jwt` route wants a token minted by Dex for
the `public-api` client. With no token the edge answers 403, `RBAC: access
denied`. Your own `kubectl` login token will not do either; it is for a
different audience and the edge answers 403 with `www-authenticate: …
error="invalid_token"` to make that visible.

```sh
TOKEN=$(make -s api-token USER=carol@team-b.local PASS=carol-local-dev)
curl --cacert .keys/local/platform/ca.crt --resolve api.local-dev.test:8443:127.0.0.1 \
  -H "Authorization: Bearer $TOKEN" https://api.local-dev.test:8443/orders/
```

Your backend receives `x-user-email: carol@team-b.local` and never sees the
token. It authorises on a header the edge verified, and never parses a JWT.

**What refusal looks like.** Admission messages on the route are written to
tell you the fix: `must carry the label platform.k8s-base/auth`, `claims a
path outside the prefixes allocated to that team`, `a backendRef points
elsewhere`. A route that is accepted but reports `ResolvedRefs: False` is
missing step 1.

## Get a shell in a pod

**The situation.** podinfo is returning errors and you need to look inside
the container.

**Why you cannot just `exec`.** Nobody can. The role that allows `exec`,
`platform-debug`, is never bound to anyone permanently. You ask for it, for
a bounded time, with a reason, and someone else approves.

```
   time      who / what                                                        request phase
   ────      ──────────                                                        ─────────────
   t+0       alice:  make access-request ROLE=debug NS=team-a-apps DURATION=1h   Pending
             admission checks: her own team's namespace, under the 4h cap, a reason
   t+10s     carol:  make access-approve …      ──▶ denied, wrong team
             alice:  make access-approve …      ──▶ denied, may not approve her own
             bob:    make access-approve …      ──▶ accepted                       Approved
   t+11s     warden: creates RoleBinding jit-alice-debug-… ──▶ platform-debug     Active
                     annotations: expires-at t+1h, approved-by bob, reason
   t+5m      alice:  kubectl exec … ls /tmp     ──▶ works; audit log: alice, exec, the command
   t+1h      warden: deletes the binding                                           Expired
             alice:  kubectl exec …             ──▶ forbidden again
```

**Step 1, be yourself.** Once per laptop:

```sh
make login USER=alice@team-a.local
export KUBECONFIG=.keys/local/users/alice@team-a.local/kubeconfig
kubectl auth whoami          # alice@team-a.local, groups team-a:dev
```

The kubeconfig has no token in it; the first command opens a browser at Dex.

**Step 2, ask.**

```sh
make access-request ROLE=debug NS=team-a-apps DURATION=1h \
  REASON='podinfo 5xx after 14:00, need to inspect /tmp'
```

This creates an `AccessRequest` in your team's home namespace and prints its
name. Admission has already checked that you asked for a namespace your team
owns, that the duration is under the four-hour cap for `debug`, and that the
reason is at least ten characters.

**Step 3, someone else approves.** A member of `team-a:admin` who is not
you:

```sh
make access-approve NAME=<request> NS=team-a
```

If you try to approve your own, the message is `may not approve their own
request … four eyes are required`. If someone from another team tries,
`may not approve debug on team-a-apps`.

**Step 4, use it.** Within a second the warden creates a `RoleBinding`
named `jit-<request>` in `team-a-apps`, bound to `platform-debug`, annotated
with the expiry and the approver's name.

```sh
kubectl -n team-a-apps exec deploy/podinfo -- ls /tmp
make access-list        # the request, Active, with expiresAt and approvedBy
make audit-exec         # your session, with your email and the command
```

**Step 5, it ends by itself.** At the expiry the binding is deleted and
`exec` is forbidden again. `make access-revoke NAME=<request>` ends it
early, and the approver or the requester can do that.

**The ceiling still applies.** A grant raises what RBAC lets you do. It does
not touch the admission ceiling: in a namespace labelled
`privileged-access: forbidden` (team-d's analytics, every platform
namespace) `exec` is refused even with the grant, even as cluster-admin.
Read the logs and events instead.

**cluster-admin.** Same ritual, `ROLE=cluster-admin`, no `NS=`. Only
`platform:operator` may ask, only from the `platform-access` namespace, only
for an hour, and only a second operator may approve. `make access-list` ends
by listing any cluster-admin binding the warden did not create, which should
only ever be the bootstrap identities.

## Onboard a team

**The situation.** A fifth team, team-e, is joining.

**Step 1, declare it.** Add a block to
`repos/fleet/clusters/local/teams-inputs.yaml`:

```yaml
- team: team-e
  shard: shard-2
  namespaces: [apps]
```

Add `waypoint: true` if the team will serve other teams with per-path rules,
`apiPaths: [...]` if it will publish on the public host, and
`privilegedAccess: forbidden` if its namespaces hold data nobody should
shell into.

**Step 2, keys.** Add `team-e` to `TEAMS` in `scripts/k8s.mk`, then:

```sh
make team-keys             # age pair under .keys/local/team-e, cosign pair under .keys/cosign/team-e
make team-render-pubkeys   # writes repos/team-e/.sops.yaml from the age public key
```

**Step 3, the repo.** Create `repos/team-e/` with one unit,
`apps/<unit>/base/` and `apps/<unit>/envs/local/`, a roster
`clusters/local/kustomization.yaml` that lists the unit's `envs/local`, and
a root `kustomization.yaml` that lists `clusters/local`. Copy
`repos/team-d/` for the smallest working shape. The team's Kustomization
always renders `./clusters/local`, so there is no path to declare in the
input; `make env-check` will insist on the roster and on every unit having
an `envs/local/`.

**Step 4, push, in order.**

```sh
make push REPO=fleet       # the ResourceSet stamps namespaces, SA, bindings, source, Kustomization
make team-inject-age       # waits for namespace team-e, injects sops-age and cosign-pub
make push REPO=team-e      # the team's first artifact
make team-status TEAM=team-e
```

That last command shows the namespaces with their labels, the Flux objects,
the injected secrets, the pods, and what the team's reconciler is allowed
to do in its first workload namespace. On a real platform the two injections
are the one thing the platform team does by hand at onboarding; everything
else is the template.

## Onboard a partner

**The situation.** A business partner needs to call team-b's orders API
with an API key, on its own hostname.

The partner edge is a second gateway on port 9443 with its own certificate,
so partner traffic never shares a proxy with the public host. A partner is
three things: a directory under `edges/partner-api/base/partners/<name>/`
with its route and its rate limit (its contract, the same everywhere; the
key check is one platform policy on the Gateway that reads the partner's
Secret by name); a line in the environment's roster,
`edges/partner-api/envs/<env>/kustomization.yaml` (whether it exists here);
and an encrypted key file beside the roster. The
owning team adds `partner-api` as a second `from` in its `ReferenceGrant`.

Rotation is two merges: add the new key alongside the old, the partner
switches, remove the old. The backend sees `x-partner-id` naming which key
was used and never the key itself.

The full onboarding checklist, including the admission rules that will check
your route, is `repos/team-sec-ops/edges/partner-api/README.md`.

## Add an environment

Covered on its own page, [environments](11-environments.md). The short
version: a new directory under `repos/fleet/clusters/`, an `envs/<env>/`
per unit that starts by inheriting its base, a `clusters/<env>/` roster per
repo, a key set per team, the same `env-check` that runs before
every push, and content that arrives by promotion rather than by push.
