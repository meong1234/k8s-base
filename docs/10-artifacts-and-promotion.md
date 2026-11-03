# Artifacts and promotion

> **Who this is for.** Anyone who pushes content, and anyone who moves it
> between environments. **Afterwards you can** explain what `make push`
> produces and why the cluster trusts it, say what changes and what stays the
> same when the laptop registry is replaced by a real one or by git, and move
> a release from one environment to the next without rebuilding it.

## Where the cluster reads from

Flux can reconcile from several kinds of source. The one thing the fleet
repo insists on is that a Kustomization refers to its source by *name*
(`infra-source`, `platform-source`, `team-b-source`) and never by shape. What
stands behind each name is an environment's decision, declared in
`repos/fleet/clusters/<env>/sources.yaml` and the `SOURCE_KIND` variable.

On this laptop there is no git server and no registry other than the one
k3d runs, so every source is an `OCIRepository` pulling from
`k3d-local-dev-registry:5000`, and `make push` is the publisher. That is the
local stand-in. A real environment would make one of two choices:

- **A real registry, fed by CI.** Every repository publishes an OCI artifact
  on merge, signed keylessly by the CI identity, and the cluster verifies the
  signature against that identity. The sources keep their kind and change
  their URL and their `verify` block. `ci/artifact-publish.yml` is that
  publisher, ready to copy into each repository once it is split out.
- **Real git repositories.** Set `SOURCE_KIND: GitRepository` in that
  environment's cluster variables and give the platform source names
  `GitRepository` objects in its `sources.yaml`. Trust then rests on
  repository credentials and branch protection rather than on a signature.
  The team sources are stamped as `OCIRepository` by the fleet template
  today, so a git-only platform would adjust that template too.

Everything below the source, the Kustomizations, the identities they apply
as, the admission rules, the promotion flow, is the same in all three cases.
What changes is only who publishes and what the source verifies.

The rest of this page describes the OCI route, because it is what runs here
and what the CI publisher produces.

## What `make push` does

```sh
make push REPO=team-b
```

Five things happen, in order, and each is a place where the push can stop:

1. **`env-check` runs.** Sixteen offline checks over the whole tree. A root
   that does not build, a Secret in plaintext, a variable with no value, a
   laptop hostname in a `base/`: any of them and nothing leaves the laptop.
2. **A revision is computed** from the file contents. Flux will report that
   revision as what it applied, so a reviewer can match the cluster to a
   tree.
3. **`flux push artifact`** packages `repos/team-b/` and uploads it as
   `oci://localhost:5050/team-b:local`. The registry returns a digest, a
   hash of the uploaded bytes. The whole tree goes in, every unit's
   `base/` and every one of its `envs/<env>/`; the cluster picks what it
   applies by rendering its own `./clusters/<env>` roster. One artifact
   therefore carries every environment's content, and the promotion model
   below is unchanged by that: the tag says which cluster may pull it, the
   path says which slice it renders.
4. **`cosign sign`** signs that digest with the owner's private key: the
   team's own for a team repo, the platform's for `fleet`, `infra` and
   `platform`. The signature is stored in the registry beside the artifact.
5. **The matching Flux source is nudged** so the change is picked up now
   instead of at the next polling interval.

The signature is on the *digest*, not on the tag. Hold on to that; it is
what makes promotion possible without re-signing.

Two flags exist so the demos can show refusal: `SIGN=0` skips the
signature, and `SIGN_AS=<other>` signs with a different owner's key. Both
produce an artifact the cluster rejects.

## What the cluster checks

Every `OCIRepository` carries a `verify` block naming a Secret that holds
exactly one cosign public key. For a team that Secret is `cosign-pub` in the
team's home namespace, injected by the platform at onboarding. For the
platform repos it is `cosign-pub-platform` in `flux-system`.

The order matters: the source verifies the signature *before* it extracts
any content. A badly signed artifact never reaches a render, let alone a
dry run. The source's status says `SourceVerified: True` or `False`, and a
`False` keeps the last good revision applied.

`make artifacts-verify` runs the same check from the laptop, with `cosign
verify` against each owner's public key, so you can confirm what the
registry holds without asking the cluster.

## Tags are environments

Each environment's cluster pulls exactly one tag, named in its cluster
variables: `local` pulls `:local`, a `dev` cluster would pull `:dev`, and so
on through `uat` and `prod`. A tag is therefore not a version label; it is
the answer to "what is running in that environment right now".

`make push` writes the working tree to the tag of the current `CLUSTER_ENV`,
and a guard refuses to run it for any value but `local`. That one guard is
what keeps an uncommitted laptop tree from ever landing on `:prod`. Content
reaches a non-local tag only by promotion.

## Promotion

```sh
make promote REPO=team-b FROM=local TO=dev
```

Promotion moves a release between environments without rebuilding or
re-signing anything. Step by step:

```
   registry: team-b                      after  make promote REPO=team-b FROM=local TO=dev
   ─────────────────                     ──────────────────────────────────────────────────
   :local     ──▶ sha256:aaaa  (signed)  :local     ──▶ sha256:aaaa
   :dev       ──▶ sha256:9999  (signed)  :dev       ──▶ sha256:aaaa   ◀── the same signed bytes
                                         :dev-prev  ──▶ sha256:9999   ◀── parked, for rollback
   :prod      ──▶ sha256:7777  (signed)  :prod      ──▶ sha256:7777   untouched

   the signature is on the digest, so it is valid under every tag; each cluster pulls one tag and verifies again
```

1. Resolve the source tag to its digest.
2. Verify that digest's signature against the owner's public key. An
   unsigned or wrongly signed artifact cannot be promoted.
3. Park the destination's current digest as `:dev-prev`, unless the
   destination does not exist yet, already points at the same digest, or
   this is itself a rollback from `-prev`.
4. Retag the digest as `:dev`.
5. Read back the destination and confirm it resolves to the source digest.

Because the signature is on the digest, it stays valid under every tag the
digest wears. What was verified in `local` is byte-for-byte what `dev` now
runs, and the Flux source in `dev` verifies it again on pull.

A rollback is a promotion from the parked tag:

```sh
make promote REPO=team-b FROM=dev-prev TO=dev
```

`make artifacts-promotions` prints, for every repo, which digest and which
revision each environment tag resolves to, including the parked ones. That
single screen is the promotion history.

## The CI publisher

`ci/artifact-publish.yml` is a GitHub Actions workflow that does what
`make push` does, for one repository, on merge to `main`:

- pushes the repository root as an artifact tagged for the least
  privileged environment, with the commit as the revision
- signs the digest keylessly: the signature is bound to the workflow's own
  OIDC identity, so no private key exists to leak or rotate
- verifies what it just published before finishing

The cluster side of keyless signing is a `verify` block that names the
expected issuer and workflow subject instead of a static key. That is why
the sources are per-environment files and not part of the fleet base: the
shape of the trust is an environment's decision.

The file deliberately does not live under `.github/workflows/`. This tree is
the stand-in for eight repositories, and a workflow here would publish the
wrong thing. It is meant to be copied into each repository once it is split
out. It has not been exercised yet; everything else on this page has.

## Useful commands

```sh
make artifacts-list              # which tags exist for each repo
make artifacts-verify            # every :local artifact against its owner's key
make artifacts-verify TAG=dev    # the same for :dev
make artifacts-promotions        # digest and revision per environment tag, per repo
flux -n team-b get source oci    # what the cluster resolved, and whether it verified
```

## Where the detail lives

- Every push, verify and promote target, with the cosign flags and the reason for each: `scripts/artifacts.mk`
- The publisher and the verify block that pairs with it: `ci/artifact-publish.yml`
- What a source must look like for an environment, and why the kind is a variable: `repos/fleet/clusters/local/sources.yaml`, `repos/fleet/clusters/local/cluster-vars.yaml`
