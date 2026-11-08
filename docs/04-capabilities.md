# Capabilities, and why they make a golden path

> **Who this is for.** Engineering leads deciding whether to adopt this
> shape, security reviewers asking what practices it implements, and
> newcomers who want the list of what they get without building it.
> **Afterwards you can** name each capability, the security practice behind
> it, and what a team would otherwise have to decide for itself.

## What a golden path is

A golden path is the paved road: the way of doing something where the easy
choice and the safe choice are the same choice. It is not a rule book that
says "you must"; it is a set of defaults where doing the obvious thing gets
you the reviewed outcome, and doing anything else takes deliberate effort
and shows up in review.

On this platform the paved road is: put your manifests in your repo, push,
and the cluster does the rest. A team that follows it never has to decide
how to isolate its namespace, how to encrypt a secret, how to get its API
behind authentication, how to make its outbound calls auditable, or how to
get a shell without holding admin forever. Those decisions are already made,
enforced by the cluster, and demonstrated by a demo.

The rest of this page is the list of what the road covers. Each entry says
what you get, which security practice it implements, and what you would
otherwise be deciding alone.

## The capability map

```
  DELIVERY            TENANCY             TRAFFIC               PEOPLE
  ─────────           ───────             ───────               ──────
  git → artifact      own namespaces      default deny          OIDC login
  signed, verified    own identity        mTLS everywhere       tiered roles
  promote by retag    own keys            two-party cross-team  just-in-time exec
  per-unit envs       shards as lanes     one egress door       four-eyes admin
  offline checks      locked baselines    reviewed public edge  audit by name
                      restricted pods     isolated partner edge no standing admin
                      admission ceiling
```

## Delivery

**Git to cluster with no hands in between.** You push a repo; a controller
pulls a signed package and applies it as your team's identity.
*Practice:* GitOps, declarative state, reconciliation. The cluster converges
on git and drift is corrected or flagged.
*Without it:* every team writes its own deploy pipeline with its own
credentials to the cluster, and those credentials are the weakest link.

**Signed, immutable artifacts.** Content is published as an OCI artifact
identified by a digest and signed with the owner's key; the cluster verifies
the signature before reading a byte. On the laptop the registry is local and
`make push` is the publisher; a real environment points the same source
names at a real registry fed by CI, or at git repositories where the
platform's trust is branch protection and repository credentials instead.
*Practice:* software supply-chain integrity. Provenance is bound to the
bytes, not to a branch name that can be rewritten.
*Without it:* the cluster trusts whatever is on `main`, and whoever can
push to `main` can deploy anything.

**Promotion by retag.** Moving a release from `dev` to `prod` re-points a
tag at a digest that was already verified. Nothing is rebuilt.
*Practice:* build once, deploy many; what was tested is what ships.
*Without it:* each environment rebuilds, and "it worked in staging" is a
hope rather than a fact.

**Per-unit environments with a checked boundary.** Every deployable unit
has a `base/` that must deploy on its own and an `envs/<env>/` per
environment for what differs; each repo's `clusters/<env>/` is only a
roster of which units run there. Sixteen offline checks run before every
push and refuse a k3d literal in a `base/`, an unresolved variable, a
plaintext secret, a secret outside its `envs/`, a unit without an env, a
repo that reaches into a sibling.
*Practice:* configuration as code with lint-time enforcement; fail early,
on the laptop, not on the cluster.
*Without it:* environments diverge quietly until a prod incident reveals
which value was never promoted.

## Tenancy

**A namespace set per team, stamped from one template.** A team is a
five-line input. Its namespaces, service account, role bindings, Flux
source, baseline policies and variables all come from one reviewed template.
*Practice:* least privilege by construction. The team's reconciler is bound
only in its namespaces, so writing elsewhere is refused by plain RBAC.
*Without it:* each team's access is hand-crafted, and "who can write where"
is whatever accumulated.

**Per-team keys.** Each team signs with its own cosign key and encrypts
secrets to its own age key. The cluster holds only public halves for
verification and the one private half for decryption, injected out of band.
*Practice:* separation of duties, secrets encrypted at rest in git.
*Without it:* one shared key, and a leak anywhere is a leak everywhere.

**Shards as lanes, not walls.** Two sets of Flux controllers serve four
teams. A team moves lanes by changing one word; a team cannot step off its
lane because an admission policy checks the label.
*Practice:* blast-radius control for the control plane; a busy or broken
team cannot stall the others.
*Without it:* one reconciler for everyone, and one bad HelmRelease delays
every team's release.

**Locked baselines.** The default-deny network policy in every workload
namespace is stamped by the platform and cannot be deleted by the team,
even though the team holds `admin` there.
*Practice:* defense in depth. A team can add rules but cannot remove the
floor.
*Without it:* "temporarily" deleting the isolation policy to debug something
is a one-liner nobody notices.

**Restricted pods by default.** Pod Security Admission enforces the
`restricted` profile cluster-wide; a team's namespace gets a different level
only if the fleet input says so.
*Practice:* secure defaults; no root, no privilege escalation, no host
namespaces unless deliberately allowed.
*Without it:* every chart's defaults decide the security posture.

**An admission ceiling.** Thirteen native admission policies say what
nobody may do: images from unknown registries, routes without an owner,
hand-made bindings to privileged roles, `exec` into data namespaces, and
more. They run inside the API server with no webhook to fail open.
*Practice:* policy as code, fail closed, enforced centrally and
independently of role.
*Without it:* the most privileged identity on the cluster can do anything,
and eventually someone has it.

## Traffic

**Default deny between teams.** Every workload namespace starts closed in
both directions. Undeclared cross-team traffic is dropped on the caller's
side, visible in Hubble, before the mesh is involved.
*Practice:* zero trust at the network layer; reachability is declared, not
assumed.
*Without it:* every service can reach every other, and a compromised pod is
a foothold into everything.

**mTLS with workload identity everywhere.** Istio ambient wraps every
pod-to-pod connection in mutual TLS with a SPIFFE identity on both ends,
with no change to any pod.
*Practice:* encryption in transit and strong identity, as a property of the
platform rather than of each application.
*Without it:* each service implements its own TLS, or none.

**Two-party cross-team access.** A call between teams needs the owner's
allow (naming one service account, one method, one path) and the caller's
depends-on. Both are files in git, both are reviewed in their own repo,
either side can close the path.
*Practice:* mutual consent, least privilege at L7, auditable dependencies.
*Without it:* either every service is open or the platform team brokers
every pair by hand.

**One egress door.** No pod has a route to the internet. The only exit is
a platform-owned proxy carrying hosts the security team listed, for the
teams named on each, with an access log that names the caller.
*Practice:* egress allow-listing, attributable outbound traffic, credentials
held at the edge rather than in workloads.
*Without it:* outbound traffic is a NAT address, and a leaked token can be
exfiltrated to anywhere.

**A reviewed public edge.** One public hostname; each team's API is a
prefix the platform allocated. A route needs an owner label, an auth class,
a backend in the owner's namespaces and the owner's consent object. The
rate limit is Gateway-wide and the JWT policy is fail-closed, so a route is
covered the moment it is merged; CORS is a route filter admission requires.
Secured routes validate a JWT for a pinned audience at the edge and hand the
backend a verified email header.
*Practice:* centralised ingress security, authentication at the edge,
four-party control over exposure.
*Without it:* every team runs its own ingress with its own auth, and the
public surface is unknown.

**An isolated partner edge.** Business partners get their own gateway,
port, certificate, API keys and rate limit, on their own hostname. A
partner's flood or misconfiguration cannot shadow the public host.
*Practice:* segmentation of external parties; per-partner credentials and
limits; key rotation without downtime.
*Without it:* partners share the public edge and one partner's key is as
good as another's.

## People

**Login through an identity provider.** Humans authenticate with OIDC;
groups arrive in the token; role bindings name groups.
*Practice:* centralised identity, no shared kubeconfigs, no long-lived
tokens on laptops.
*Without it:* kubeconfigs with static credentials are copied around.

**Tiered roles.** Developer, team admin, company viewer, platform operator,
as aggregated roles bound per namespace by the template. A team admin can
delegate only what they hold. On a production tier, admins drop to the
developer role.
*Practice:* least privilege, escalation prevention, stricter the closer to
production.
*Without it:* "admin in my namespace" quietly becomes "admin".

**Just-in-time privileged access.** No one holds `exec`, `port-forward` or
`cluster-admin` standing. A request names a role, namespace, duration and
reason; a second person approves; a controller grants a binding that
expires. Caps are enforced at admission and again by the controller.
*Practice:* zero standing privilege, time-bound elevation, four-eyes.
*Without it:* the people who can fix things at 2am hold admin at 2pm too.

**Namespaces where no grant reaches.** Data and platform namespaces are
labelled so that `exec` is refused for everyone, including a fresh
cluster-admin. Read the logs instead.
*Practice:* the ceiling applies to the most privileged, not just the least.
*Without it:* "break glass" means "everything".

**Audit by name.** The API server records every privileged session, every
RBAC change, every access request and every write in a team namespace, with
the human's email and groups and the object body.
*Practice:* accountability, forensics, compliance evidence.
*Without it:* the log says a service account did it.

## Verification

**Every rule has a demo.** Twenty-two demos each attempt the forbidden
thing and assert the refusal, printing PASS or FAIL. A real environment
runs a three-assertion smoke test instead.
*Practice:* continuous verification of controls; the security posture is
tested, not asserted.
*Without it:* the policy exists in a file and nobody knows whether it still
fires.

**The whole platform on a laptop.** `make up` brings all of it up on k3d,
and everything that is only true on a laptop lives in a unit's
`envs/local/` the checks fence off.
*Practice:* reproducibility; the production shape is what engineers develop
against.
*Without it:* the platform is only understood by whoever built it, in
production, once.

## What the road does not cover

Being honest about the edges of the paved road is part of the road:

- There is one environment today. The multi-environment structure is
  checked offline but a second cluster has never been attached.
- The CI publisher exists as a file and has not run, because the eight repos
  are still one tree.
- Container images are not signed or verified; the signing here is on
  manifests. Image verification is a separate policy a real platform would
  add.
- Rate limits are per gateway replica, not global, and are raw Envoy
  configuration in an `EnvoyFilter`: Istio has no rate-limit API of its own.
- The identity provider is a stand-in with static users.

Each is named where it comes up on the other pages, and none changes the
shape of what a team does day to day.

## Where to go next

- The same list as promises with the demo that proves each:
  [guarantees](05-guarantees.md)
- What following the road looks like for one task:
  [walkthroughs](06-walkthroughs.md)
