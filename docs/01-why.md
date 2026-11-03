# Why this exists

> **Who this is for.** Anyone on their first day, whatever their role, even
> if you have only a passing acquaintance with Kubernetes.
> **Afterwards you can** explain to a colleague what problem this platform
> solves, what it promises, and why it is built the way it is instead of the
> usual way.

## The situation

Imagine a company with four product teams. Each team builds services and
wants to deploy them several times a day. Running four separate Kubernetes
clusters is expensive and lonely: every team would have to operate its own
ingress, its own certificates, its own monitoring. So the company runs one
cluster and all four teams share it.

That immediately raises questions that have nothing to do with the
software the teams write:

- When team-b deploys, how do we know they cannot accidentally overwrite
  something that belongs to team-a?
- When team-b's service wants to call team-a's service, who decides whether
  that is allowed, and where is that decision written down?
- When a service needs to call an outside API, say a payment provider, how
  do we stop every pod on the cluster from reaching the whole internet?
- When team-a wants their API reachable from the public internet, who checks
  that it is rate-limited, that it has authentication, that it does not
  accidentally expose someone else's service?
- When something breaks at 2am and an engineer needs a shell inside a pod,
  how do they get it, and how do we know afterwards who had it?

The usual answer to all of these is "the platform team". A small group holds
the admin credentials, teams open tickets, the platform team does things on
their behalf. It works for a while. Then the platform team becomes a queue,
teams start asking for standing admin access to skip the queue, and a year
later nobody can say who can do what. The admin credentials, meanwhile, are
the one thing on the cluster that can do anything at any time.

This platform is an attempt to answer every one of those questions with a
rule the cluster enforces, rather than with a person who remembers to check.

```
  the usual way                                      this platform
  ─────────────                                      ─────────────
  team-a ──ticket──▶                                 team-a  ──signed push──▶  ┌────────────────┐
  team-b ──ticket──▶   platform team ──admin──▶      team-b  ──signed push──▶  │    cluster     │
  team-c ──ticket──▶   (the queue, and the one       sec-ops ──review, sign──▶ │  enforces the  │
  team-d ──ticket──▶    key that can do anything)    platform ──template────▶  │  rules itself  │
                                                                               └────────────────┘
                                                     nobody holds admin standing; elevation is
                                                     asked for, approved by another, timed, logged
```

## Four ideas everything else follows from

Once you hold these four, almost every file in the repo makes sense as a
consequence of one of them.

```
  4  nobody holds standing privilege   ask ──▶ someone else approves ──▶ timed grant ──▶ gone, logged
  3  admission is the ceiling          what nobody may do, whatever their role
     RBAC is the floor                 what your role lets you do
  2  a signature is an approval        the owner merges and pushes ──▶ signed ──▶ live; nothing else can
  1  git is the only door              repo ──▶ signed artifact ──▶ Flux, as the team ──▶ cluster
```

### 1. Git is the only door

Nothing reaches the cluster because somebody typed `kubectl apply`. A team
writes its manifests in its own repository, the content is published as a
signed package, and a controller running inside the cluster pulls that
package and applies it. The controller runs as the team's own identity, so it
can only touch the team's own namespaces.

Why it matters to you: if you want to change what runs, you change a file
and push. If you try to change the cluster by hand, the cluster notices. On
this laptop cluster it warns you; on a production cluster it refuses. Either
way, what runs is always what git says, which means a reviewer who reads git
knows what is running.

### 2. A signature is an approval

Every repository is published with a cryptographic signature from a key only
that repository's owners hold. The cluster is configured to accept content
for team-a only if it is signed with team-a's key, and content for the public
edge only if it is signed with the security team's key.

Why it matters to you: when you want something that lives in another team's
repository, you open a pull request there. When they merge and publish, their
signature is the approval. There is no separate approval system, no ticket,
no admin who applies it for you. The review and the deployment are the same
act.

### 3. Admission is the ceiling and RBAC is the floor

Kubernetes has a permission system called RBAC: it lists what each identity
may do. This platform uses it, but RBAC alone has a problem: whoever has the
highest permissions can do anything, including things nobody should ever do.

So there is a second layer on top. Admission policies are rules the API
server evaluates on every request, before RBAC's answer is final, and they
say what is forbidden for everyone regardless of role. A team admin cannot
delete the network policy that isolates their namespace, even though RBAC
would let them edit it. A platform engineer holding a fresh cluster-admin
grant cannot open a shell in the analytics namespace. Nobody can hand
themselves the debug role by writing a role binding.

Why it matters to you: the floor is what your role lets you do, and the
ceiling is what the cluster refuses regardless. Being granted more
permissions raises your floor; it never moves the ceiling.

### 4. Nobody holds standing privilege

The dangerous permissions, opening a shell in a pod, forwarding a port,
being cluster-admin, are not assigned to anyone permanently. Not to
developers, not to team leads, not to the platform team. Instead you ask for
one for a bounded time, a second person who is not you approves it, a
controller grants it and takes it away when the time is up, and all three
steps are in the audit log with real names.

Why it matters to you: the first time you need a shell, there is a short
ritual. After that it is a habit, and the company has a record of every
privileged session it has ever had.

## What the cluster refuses to let anyone do

Three refusals are worth memorising, because they shape how you work:

**You cannot write into a namespace you do not own.** Your deployment
controller is bound only in your namespaces. A manifest that names someone
else's namespace fails on your side, with a clear message, and nothing
reaches theirs.

**Your pod cannot reach the internet directly.** Outbound traffic leaves
through one proxy that the platform owns. The proxy only carries hosts the
security team has listed, only for the teams named on each host, and it logs
which workload called. If you need a new host, you ask for it in a pull
request.

**You cannot expose a service to the world by yourself.** A public route
needs four things from four owners: the platform's gateway, a route reviewed
by the security team, a URL prefix allocated in the fleet configuration, and
a consent object in your own namespace. Remove any one and the route stops
working.

Each of these has a demo that attempts the forbidden thing and shows the
refusal. The [guarantees](05-guarantees.md) page lists them.

## What is real and what stands in for something real

This is a design proven on a cluster that runs on one laptop. Some parts are
simulations of things a company would have for real, and the docs say so
where it matters:

- There is one environment, called `local`. The structure for several
  environments exists and is checked, but only one cluster runs.
- Logins go through Dex, an identity provider, with six made-up users and
  passwords. A company would connect Dex to its directory and the same
  groups would arrive from there.
- The external partner that demands a client certificate is an nginx
  container next to the cluster. The cluster-side configuration is exactly
  what a real partner would need.
- Publishing is done from the laptop with `make push`. A company would run
  the same steps in CI on merge, and that workflow file is in the repo.

What is not simulated is every rule. Every refusal above is enforced by the
real API server, the real network layer and the real mesh, and every one has
a demo you can run.

The next page introduces the technologies involved, in plain words, before
the one after it shows how they fit together.
