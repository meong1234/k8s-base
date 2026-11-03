# `depends-on-service` — the calling team's half of cross-team access

One file per `(owning team, service)` pair in
`repos/<caller>/apps/<unit>/base/depends-on/<owning-team>-<service>.yaml`, rendered from
`depends-on.yaml.tmpl` and named `depends-on-<owning-team>-<service>`. Like its
counterpart, nothing here is reconciled: the template carries placeholders and
is listed in no `kustomization.yaml`.

See `../allow-team/README.md` for why these are `sed` templates rather than a
kustomize `Component` (a `Component` takes no parameters, and the owning half
has structural variants a patch cannot express).

## The two-party rule

The owning team's half says *who may call us*. This half says *we call out
there*.
Both are in git, both are reviewed in their own repo, and deleting either one
closes the path. The platform never opens a cross-team path on a team's behalf.

The calling team's own baseline allows egress to
the same team, to kube-dns and to `platform-egress` on 15008 — and nothing else.
Without this file the call never leaves the calling pod, however complete the
owning team's half is. That is the point: the calling team's egress surface stays
its own declaration.

## Inputs

| Placeholder | Meaning | Example |
| --- | --- | --- |
| `__CALLER_NAMESPACE__` | namespace the calling pods live in | `team-b-apps` |
| `__OWNING_TEAM__` | owning team, for the object name and labels | `team-a` |
| `__OWNING_NAMESPACE__` | namespace the owning team's service and waypoint live in | `team-a-apps` |
| `__SERVICE__` | the service being called, for the object name and labels | `podinfo` |

## What the object does

**`NetworkPolicy depends-on-<owning-team>-<service>`** — Cilium, egress only. Allows
the calling team namespace out to the owning team namespace **on port 15008**: the
ambient mesh port, not the service port. The same namespaceSelector covers the
owning team's waypoint pods, so a service behind a waypoint needs no extra rule
here.

`podSelector: {}` is deliberate. The egress half is namespace-wide reach; the
identity gate is the owning team's `AuthorizationPolicy`, which names one
ServiceAccount. A pod in the calling team namespace running under a *different*
ServiceAccount therefore gets a connection as far as the owning team's ztunnel and
is refused there on identity — which is the demonstration
(`demos/cross-team-access/README.md`, `caller-other`). Narrow `podSelector` to
the calling workload's labels if a team prefers its egress scoped per workload;
the guarantee does not change either way.
