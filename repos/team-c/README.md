# team-c — secrets workflow

This repo is pushed as the OCI artifact `team-c:local`, signed with team-c's
cosign key, and reconciled by the Flux shard `shard-2`. Anything under here is
applied into `team-c-apps` by the `flux` ServiceAccount.

Everything matching `*.enc.yaml` is **SOPS/age encrypted at rest**. The Flux
`Kustomization team-c` has `decryption.provider: sops` with `secretRef:
sops-age`, so the cluster decrypts on apply — nothing in this repo is ever
plaintext in git.

## Layout

```
kustomization.yaml            resources: [clusters/local]
clusters/local/               the roster: one line per unit, nothing else
apps/podinfo/base/            namespace team-c-apps: the podinfo HelmRelease
apps/podinfo/envs/local/      podinfo-config.enc.yaml — the Secret it consumes
```

`base/` is the contract: it must `kustomize build` on its own and every object
in it must be admissible in a `restricted` namespace on any tier. It builds
without the Secret — a `valuesFrom` that names a Secret only has to resolve at
apply time — which is what lets the ciphertext live in the unit's
`envs/<env>/`. An env only ever **adds** to a base that already deploys. There
is one environment and so one `envs/local/`, and `team-c`'s holds the one
thing that is genuinely per-environment here: the ciphertext.
`repos/team-a/README.md` is the long form of the pattern.

## Current state

`apps/podinfo/envs/local/podinfo-config.enc.yaml` is encrypted with team-c's age
key: its `stringData` values are `ENC[...]` and the file carries a `sops:`
block. The cluster decrypts it on apply; `demo-sops` asserts that.

To re-encrypt it after a decrypt, or to encrypt a newly added file:

```sh
make team-sops-encrypt TEAM=team-c FILE=apps/podinfo/envs/local/podinfo-config.enc.yaml
```

## Where a secret file lives

`apps/podinfo/envs/local/podinfo-config.enc.yaml` sits under the unit's
`envs/local/` because that is the only place a `*.enc.yaml` may live:
`make env-check` check 9 refuses any `*.enc.yaml` outside `envs/<env>/`.

The rule in full:

| The value is | Where the file goes |
| --- | --- |
| not secret, the same in every environment | the unit's `base/` |
| secret (`*.enc.yaml`), same or different per environment | `envs/<env>/` and **only** there, one copy per environment, each encrypted to that environment's key |

Never a `*.enc.yaml` in `base/` that an env patches: a strategic-merge patch
cannot merge into an encrypted value, so the env would have to replace the
whole Secret, and then the base file is one the env forgot. The `path_regex`
in `.sops.yaml` selects files by their `envs/<env>/` segment, so a file under
`envs/<env>/` is encrypted to *that environment's* recipient
(`.keys/<env>/team-c/age.pub`), which is what makes a `prod` secret
undecryptable on `dev`, and `make env-check` check 8 asserts the recipient.
`repos/team-sec-ops` keeps its partner keys the same way, in
`edges/partner-api/envs/local/`.

## Who holds which key

| Key | Where it lives | Who can read it |
| --- | --- | --- |
| age **public** key | `.sops.yaml` in this repo (rendered by `teams.mk`, do not hand-edit) | everyone |
| age **private** key | Secret `sops-age` in namespace `team-c`, injected out-of-band by the platform (`make team-inject-age`) | the cluster only |

Consequence: a team engineer can **encrypt** and add new secrets without any
private key, but cannot decrypt what is already in the repo from a laptop. That
is intentional — the repo is a write-only secret channel into the cluster.

## Adding a new secret

1. Write the Secret as normal YAML, with a filename ending in `.enc.yaml`
   (the `path_regex` in `.sops.yaml` is what selects it).
2. Encrypt it in place:
   ```sh
   sops --encrypt --in-place apps/<unit>/envs/local/<name>.enc.yaml
   ```
   `encrypted_regex: ^(data|stringData)$` means only the values are encrypted —
   `apiVersion`, `kind` and `metadata` stay readable, so `kustomize build` and
   code review still work.
3. Reference it from a workload (`valuesFrom`, `envFrom`, `secretKeyRef`, ...)
   and add it to that unit's `envs/local/kustomization.yaml`.
4. `make push REPO=team-c`.

## Editing an existing secret

```sh
sops apps/podinfo/envs/local/podinfo-config.enc.yaml
```

This opens `$EDITOR` on the decrypted content and re-encrypts on save. It needs
the age private key, so in this setup it only works for whoever generated the
key (`.keys/<env>/team-c/age.agekey`), not for a plain team engineer.

## Rules

- **Never commit plaintext.** If a `*.enc.yaml` file has a readable `data:` or
  `stringData:` block, it is not encrypted. `grep -q ENC` on the file is the
  check used by the E5 acceptance criteria.
- Never add the private key to this repo — platform injects it.
- Never edit `.sops.yaml` by hand; `scripts/teams.mk` renders it from
  `.keys/<env>/team-c/age.pub`, one creation rule per environment.
- Rotating the age key means re-encrypting every `*.enc.yaml` with the new
  public key and re-running `make team-inject-age`.
