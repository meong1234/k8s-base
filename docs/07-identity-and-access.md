# Identity and access

> **Who this is for.** Anyone who will run `kubectl` against this cluster,
> and anyone who will approve access for others.
> **Afterwards you can** say who you are to the cluster and how it knows,
> what your group lets you do and why it stops there, and walk through
> getting elevated access for an hour and watching it end.

## Two kinds of identity

Everything that talks to the Kubernetes API is one of two things, and it
helps to keep them apart in your head.

**Humans** are people with an email. You authenticate through Dex, an OIDC
identity provider, and the API server trusts the token Dex issues. Your
email is your username. The groups in the token (`team-a:dev`,
`platform:operator`) are what role bindings name, so what you may do follows
from what the identity provider says about you, not from a file someone
hand-edited.

**Reconcilers** are service accounts. Each team has one, named `flux`, in
its home namespace. Everything Flux applies for that team is applied as
`system:serviceaccount:<team>:flux`. The team's service account is bound as
`admin` only in the team's workload namespaces, which is what turns "a team
cannot write outside its namespaces" from a policy into a property of RBAC.

The distinction matters because the rules treat them differently. The
`gitops-only` admission policy, for example, flags workload objects written
by anything that is *not* a service account or a node: it is literally the
rule that says humans do not deploy by hand.

## How a human logs in

Your kubeconfig does not contain a token. It contains an *exec credential
plugin*: when `kubectl` needs a credential it runs `kubectl oidc-login`,
which opens a browser at Dex the first time, lets you type a password, and
caches the id token locally. Afterwards `kubectl` just works until the
token expires, and then the browser opens again.

```
   kubectl ──needs a credential──▶ kubectl oidc-login ──browser (first time)──▶ Dex  dex.local-dev.test
                                         │ caches the id token                     │ static password here;
                                         ▼                                         │ a company directory for real
   API server ◀──── Bearer id_token ─────┘                                         ▼
       │                                   id_token: email alice@team-a.local, groups [team-a:dev]
       │ authentication: trusts Dex as issuer (k3d/authn.yaml.tmpl)
       │ authorization:  RoleBindings in team-a and team-a-apps name group team-a:dev ──▶ platform-developer
       │ admission:      the ceiling, whatever the answer above
       ▼
```

```sh
make login-help                              # the six users, their groups, their passwords
make login USER=alice@team-a.local           # writes .keys/local/users/alice@team-a.local/kubeconfig
make whoami KUBECONFIG=.keys/local/users/alice@team-a.local/kubeconfig
```

`make whoami` asks the API server who it thinks you are and prints the
username and groups it will use for every decision. That is the first thing
to run when a permission surprises you.

The six users live in `repos/fleet/clusters/local/identity/users.yaml`,
and two generated files come from that one roster: the API server's
authentication config and Dex's user list. A company would delete the
static users, point Dex at its directory, and the groups would arrive from
there with nothing else changing.

The demo users and what they are for:

| User | Groups | Stands in for |
| --- | --- | --- |
| alice@team-a.local | `team-a:dev` | a developer on team-a |
| bob@team-a.local | `team-a:admin` | team-a's lead, who approves access for the team |
| carol@team-b.local | `team-b:dev` | a developer on another team, for every "wrong team" check |
| viewer@company.local | `company:viewer` | an on-call who may read everything and change nothing |
| ops@platform.local | `platform:operator` | a platform engineer |
| ops2@platform.local | `platform:operator` | the second platform engineer every cluster-admin grant needs |

## What your group lets you do

Four roles exist, defined once in `repos/infra/rbac/base/` and bound per
namespace by the fleet template when it stamps a team. They are
*aggregated* ClusterRoles, meaning each is assembled from labelled pieces,
so the developer rules are automatically part of the admin role and the
admin rules part of the operator role.

```
                       where            may                                              may not
   platform:operator   cluster-wide     read cluster objects, manage every Flux object,  read Secrets, exec,
                                        request and approve cluster-admin                be cluster-admin
   <team>:admin        team namespaces  everything below + edit, roles and bindings,     bind a role they do not hold,
                       (dev tier)       netpol, routes, authz policies, approve access   exec, delete the baseline
   <team>:dev          team namespaces  read everything, logs, trigger a reconcile,      write workloads, read Secrets,
                                        file an access request                           exec
   company:viewer      every team ns    read                                             anything else
   ───────────────────────────────────────────────────────────────────────────────────────────────────────
   nobody, standing    platform-debug (exec, port-forward)   cluster-admin      ──▶ AccessRequest only
```

**`platform-developer`**, bound to `<team>:dev` in the team's namespaces.
You can read every object including logs and events, you can patch a Flux
Kustomization or HelmRelease (which is how you trigger a reconcile or
suspend one), and you can file an access request. You cannot create or
edit workloads, read Secrets, or `exec`. The thing to absorb: a developer's
day-to-day write path is git, not `kubectl`.

**`platform-team-admin`**, bound to `<team>:admin` in the team's namespaces,
on the `dev` tier. Everything above plus edit, plus roles and role bindings,
network policies, routes and authorization policies, plus approving the
team's access requests. On a tier other than `dev` this group is bound to
the developer role instead: the closer the cluster is to production, the
less a human may change by hand.

**`view`**, bound to `company:viewer` in every team namespace. Read
everything, write nothing.

**`platform-operator`**, bound cluster-wide to `platform:operator`. Read
cluster-scoped objects, manage every Flux object, file and approve
cluster-admin requests. An operator is *not* cluster-admin and cannot read
Secrets or `exec`. That is the point: the platform team runs the platform
without holding the keys to everything in it.

Two consequences worth seeing with your own eyes, because they are where
people expect a hole and find none:

- A team admin can create role bindings. Can they make themselves
  cluster-admin? No. The API server's escalation check refuses any binding
  whose role grants more than the creating user already holds, unless they
  hold the special `bind` verb on it. bob can hand a colleague
  `platform-developer` and cannot hand anyone `cluster-admin`,
  `platform-debug` or `platform-operator`. `demo-access` asserts both
  directions.
- An operator can manage every Flux Kustomization. Can they use that to
  deploy into a team namespace? The Kustomization applies as the team's
  service account, so what lands is still bounded by that account.

## Getting more, for a while

Three roles are never bound to anyone standing:

| Role | Grants | Cap |
| --- | --- | --- |
| `platform-debug` | `exec`, `attach`, `port-forward`, ephemeral containers | 4 hours |
| `platform-team-admin` | the admin role, on tiers where it is not standing | 8 hours |
| `cluster-admin` | everything | 1 hour |

You obtain one through an `AccessRequest`, a custom object the access warden
watches. The life of a request:

```
  you                    a second person              the warden                time
  ─────────────────      ────────────────             ──────────────────        ────────────
  create AccessRequest   patch status.phase=Approved  create RoleBinding        delete it,
  role, namespace,       (admission refuses the       jit-<request> with        phase=Expired
  duration, reason       requester and the wrong      expiresAt = now +
  phase: Pending         group)                       min(duration, cap)
                                                      phase: Active
```

The four make targets wrap the two objects: `access-request`,
`access-approve`, `access-deny`, `access-revoke`. Each prints what it did
and what to run next. The [walkthrough](06-walkthroughs.md#get-a-shell-in-a-pod)
shows the whole thing as a session.

What the admission policies check, so you know what will be refused before
you try:

- *On create:* you asked for yourself, for a namespace one of your teams
  owns, from your team's home namespace, under the cap, with a reason of at
  least ten characters.
- *On approve:* you are not the requester, your groups cover the request
  (`<team>:admin` for a team request, `platform:operator` for
  cluster-admin), and you are not trying to set the phase to `Active` or
  `Expired`, which only the warden may do.

The cap is applied twice on purpose. Admission rejects a request whose
duration exceeds it, and the warden clamps the expiry again when it creates
the binding, so if a policy were ever missing the window still could not
widen.

`make access-list` shows every request in every namespace, every live
binding with its expiry and approver, and at the end any cluster-admin
binding that the warden did not create. On a healthy cluster that last list
is only the bootstrap identities, and anything else in it is the first
thing to investigate.

If the warden is down, nothing is granted and nothing is revoked. No new
access appears, existing windows close on their own when the binding's
expiry is reached by a restarted warden, and `make access-list` still tells
you what is live. That is the safe direction to fail.

## Where even a grant does not reach

A grant raises the floor. The ceiling stays where it is. Namespaces
labelled `platform.k8s-base/privileged-access: forbidden` refuse `exec`,
`attach`, `port-forward` and ephemeral containers for *every* identity,
including someone holding a fresh cluster-admin grant. The label comes from
the fleet input: team-d's analytics namespace carries it because it holds
data, and every `platform-*` namespace carries it because nothing there
should ever need a shell.

The same policy keeps `kubectl debug` to a short list of curated images,
and refuses a human minting a service account token in a team namespace,
because a token is a standing credential that outlives any window.

The practical effect: when something is wrong in one of those namespaces,
you read logs and events, you look at Hubble and the mesh, you do not go
inside. `demo-privileged-guard` gets ops a cluster-admin grant and then
shows exec into the analytics namespace denied anyway.

## What is recorded

The API server writes an audit log, and the policy in `k3d/audit-policy.yaml`
records at the fullest level (`RequestResponse`, including the object body):

- every `exec`, `attach`, `port-forward`, ephemeral container and token request
- every write to a role, role binding, cluster role or cluster role binding
- every access request and every approval
- every create, update or delete in a team namespace

Routine reads by controllers are dropped so the log stays readable.

```sh
make audit-tail     # the last human actions: who, which group, which verb, which object
make audit-exec     # only privileged sessions, with the command that was run
```

So when alice `exec`s during her window, the log has her email, her group,
the pod, and the command. When bob approves, the log has his name on the
status patch. The whole chain from request to session is attributable to
people, which is the property the platform exists to give.

## Internal tools without port-forward

Most clusters hand out `port-forward` so engineers can reach dashboards.
Here `port-forward` is part of the debug role and is just-in-time like
`exec`. Internal UIs are instead behind the internal gateway with an OIDC
policy: the Hubble UI is at `hubble.internal.local-dev.test`, an
unauthenticated request is redirected to Dex, and after login it loads.
`demo-internal-oidc` shows the 302 and then the 200, with no port-forward
involved.

## Where the detail lives

- The warden: its state machine, why a component that can bind cluster-admin is safe here, and how to replace it with a commercial product: `warden/README.md`
- The five access policies, one sentence each, and the integration results: `repos/infra/policies/base/README.md`
- The identity demos, and logging in without root on a laptop: `demos/access/README.md`
- The four just-in-time demos as copy-paste sessions: `demos/access/README-jit.md`
