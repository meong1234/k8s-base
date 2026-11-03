# `allow-team` — the owning team's half of cross-team access

The **owning** team ships one file per `(calling team, service)` pair into
`repos/<owner>/apps/<unit>/base/allow/<caller-team>-<service>.yaml`. That file is rendered
from the single template in this directory. Nothing here is reconciled: the
`*.yaml.tmpl` file is not listed in any `kustomization.yaml` and carries
placeholders, so Flux never sees it.

One file, two objects, one name: `allow-<caller-team>-<service>`.

## Why a template and not a kustomize `Component`

The design called this a "platform kustomize component".
A kustomize `Component` (`kustomize.config.k8s.io/v1alpha1`) **cannot take
parameters from its caller** — there is no argument mechanism, and the
documented workarounds are `patches` and `replacements` applied by the caller.
Three properties defeat all of them:

1. **Structural variants.** `callerServiceAccount` set renders
   `from.source.principals`; unset renders `from.source.namespaces`. A service
   behind a waypoint is named by `spec.targetRefs`; one without a waypoint by
   `spec.selector`. kustomize has no conditional: a patch can change a value, it
   cannot swap one field for another and delete the first without a second,
   hand-written patch per variant.
2. **Field-name placeholders.** The pod selector is a *label key*, not a value.
   `replacements` rewrites values at a `fieldPath`; it cannot write a map key.
3. **Caller cost.** A ConfigMap-driven `replacements` component would need one
   `replacements` entry per parameter, each with a `fieldPaths` list per object,
   and the caller would still write a ConfigMap whose keys it has to get exactly
   right — more YAML than the rendered file itself, and the error mode is a
   silent no-op instead of a diff.

So it is a **template filled by `sed`**, which is the pattern the repo already
uses for `demos/_attach.yaml` (`__NAME__` / `__TEAM__` / `__SHARD__`). The
output is plain YAML committed to the owning team's repo, reviewable as a diff,
with no indirection between what is in git and what lands in the cluster.

The `.yaml.tmpl` extension is load-bearing: it keeps the placeholder file out of
`kubeconform $(find repos k3d -name '*.yaml')`.

## The two-party rule

Cross-team access is **two halves, in two repos, both required**:

| Half | Repo | Object | Without it |
| --- | --- | --- | --- |
| owning team | `repos/<owner>/<ns>/allow/` | ingress `NetworkPolicy` + `AuthorizationPolicy` (this directory) | the owner's baseline drops the call and the mesh refuses it |
| calling team | `repos/<caller>/<ns>/depends-on/` | egress `NetworkPolicy` (`../depends-on-service`) | the caller's own baseline (§2.3) blocks the call before it leaves |

Either side deletes its file and the path closes. Neither side can open it
alone, and neither side can be opened *for* it by the platform.

## The template and its parameters

`allow.yaml.tmpl` has three line placeholders and three block placeholders. The
block ones are what keep it a single template across the variants:

| Placeholder | Meaning |
| --- | --- |
| `__CALLER_TEAM__`, `__CALLER_NAMESPACE__` | the calling team and the namespace its pods run in |
| `__OWNING_NAMESPACE__`, `__SERVICE__` | where this file lands, and the Service being opened |
| `__POD_SELECTOR_KEY__` / `__POD_SELECTOR_VALUE__` | which pods the `NetworkPolicy` admits traffic to — the **waypoint** pods when the owning namespace has a waypoint, the service's own pods when it does not |
| `__TARGET__` | `targetRefs:` naming the Service (waypoint in path) **or** `selector:` matching the service's pods (no waypoint) |
| `__CALLER_SOURCE__` | `principals: [...]` for one named ServiceAccount, or `namespaces: [...]` for any identity in the calling namespace |
| `__OPERATION__` | `methods:` + `paths:` when the owning namespace has a waypoint, `ports:` when it does not |

**Both halves are written against port 15008, never the service port.** In
ambient, ztunnel rewrites the destination before Cilium sees the packet, so a
`NetworkPolicy` naming 9898 matches nothing. The service port — or the method
and path — is enforced by the `AuthorizationPolicy`.

### Rendering team-a's file

`repos/team-a/apps/podinfo/base/allow/team-b-podinfo.yaml`, the live example: team-a owns
`podinfo`, has a waypoint, and allows team-b's `orders` identity `GET
/api/info` and nothing else.

```sh
T=repos/platform/components/allow-team

sed -e 's/__CALLER_TEAM__/team-b/g' \
    -e 's/__CALLER_NAMESPACE__/team-b-apps/g' \
    -e 's/__OWNING_NAMESPACE__/team-a-apps/g' \
    -e 's/__SERVICE__/podinfo/g' \
    -e 's#__POD_SELECTOR_KEY__#gateway.networking.k8s.io/gateway-name#g' \
    -e 's/__POD_SELECTOR_VALUE__/waypoint/g' \
    -e 's#__TARGET__#targetRefs:\
    - group: ""\
      kind: Service\
      name: podinfo#' \
    -e 's#__CALLER_SOURCE__#principals: ["cluster.local/ns/team-b-apps/sa/orders"]#' \
    -e 's#__OPERATION__#methods: ["GET"]\
            paths: ["/api/info"]#' \
    $T/allow.yaml.tmpl > repos/team-a/apps/podinfo/base/allow/team-b-podinfo.yaml
```

### Rendering it for a namespace with no waypoint

Same template, three different blocks: the `NetworkPolicy` admits traffic to the
service's own pods, the `AuthorizationPolicy` selects them, and the operation is
a port rather than a method and a path.

```sh
    -e 's#__POD_SELECTOR_KEY__#app.kubernetes.io/name#g' \
    -e 's/__POD_SELECTOR_VALUE__/podinfo/g' \
    -e 's#__TARGET__#selector:\
    matchLabels:\
      app.kubernetes.io/name: podinfo#' \
    -e 's#__OPERATION__#ports: ["9898"]#' \
```

And for "any identity in the calling namespace" rather than one ServiceAccount:

```sh
    -e 's#__CALLER_SOURCE__#namespaces: ["team-b-apps"]#' \
```

## What the waypoint changes about enforcement

With the owning Service labelled `istio.io/use-waypoint`, the call terminates at
the waypoint and the waypoint's `targetRefs` rule is what answers. Measured on
this cluster: a caller with the wrong ServiceAccount, or the right one on an
undeclared method or path, gets an HTTP **403** with body `RBAC: access denied`
and `curl` exits **0**. It is not a TCP reset, and ztunnel does not make the
decision — it logs `handling RBAC delete <ns>/<name>` for a `targetRefs` policy,
because that policy belongs to the waypoint.

The `NetworkPolicy` half is still load-bearing: it is what admits the calling
namespace to the waypoint pods on 15008 at all, it is the fence if the
`istio.io/use-waypoint` label is ever dropped from the Service, and it is what
Hubble shows. **If the label is missing the `AuthorizationPolicy` is accepted by
the API server and simply never consulted, and every path returns 200** — the
single most important thing to check when this appears to be working too well.

## Multi-label pod selectors

The template takes exactly one `__POD_SELECTOR_KEY__` / `__POD_SELECTOR_VALUE__`
pair. podinfo is fine with `app.kubernetes.io/name: podinfo`, but a chart that
reuses that label across releases in one namespace would need
`app.kubernetes.io/instance` too. The answer is "render, then add the second
label by hand"; if more than one service needs it, the template grows a second
optional pair rather than a renderer.
