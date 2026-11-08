What: the identity half of the demo set — `demo-access`, `demo-audit` and
`demo-internal-oidc`. Unlike the other demo directories this one ships no
manifests: everything is driven through per-user kubeconfigs written by
`make login USER=<email>` and through `kubectl auth can-i`, so the only
artifacts are the kubeconfigs under `.keys/local/users/<email>/`.
Attached to: nothing. The recipes live in `scripts/demos.mk`.

## Why there is nothing to apply

A demo that proves "alice may read team-a and may not read team-b" must not
create any object: the whole point is that the API server refuses. The inputs
are identities, and identities come from `repos/fleet/clusters/local/identity/users.yaml`
through two generated artifacts (`.keys/local/platform/authn.yaml` for the API server,
`repos/platform/identity/envs/local/dex-users-configmap.yaml` for Dex).

## Logging in

```sh
make login-help                                  # the six users, their groups, their passwords
make login USER=alice@team-a.local               # writes .keys/local/users/alice@team-a.local/kubeconfig
make whoami KUBECONFIG=.keys/local/users/alice@team-a.local/kubeconfig
```

The kubeconfig holds no token. It holds an exec credential plugin:

```
kubectl oidc-login get-token
  --oidc-issuer-url=https://dex.local-dev.test:8443
  --oidc-client-id=kubernetes
  --oidc-client-secret=<.keys/local/platform/dex-client-secret>
  --oidc-extra-scope=email --oidc-extra-scope=groups
  --certificate-authority=<abs>/.keys/local/platform/ca.crt
```

First use opens a browser at Dex, the user types the password from
`make login-help`, and kubelogin caches the id_token under `~/.kube/cache/oidc-login`.
`make login` is idempotent: re-running it rewrites the kubeconfig, not the cache.

## The non-interactive flow the demos use

A browser login cannot be scripted, so the demos do not try. kubelogin supports
the resource owner password credentials grant, and Dex supports it for the local
password database when `oauth2.passwordConnector: local` is set and `password` is
in `oauth2.grantTypes` — both are set in `repos/platform/identity/base/helmrelease.yaml`.
The demos therefore append two flags to the same plugin invocation:

```
--grant-type=password --username=<email> --password=<password>
```

The browser flow stays the default for humans; the password grant exists only so
`make demo-access` can run unattended. It is the one piece of this epic that must
never reach a real cluster, and the Dex config says so in the integration notes.

## Name resolution without root

kubelogin resolves `dex.local-dev.test` itself and has no `--resolve`, so the
`/etc/hosts` line `make hosts-print` asks for is load-bearing — and editing
`/etc/hosts` needs `sudo`. On a laptop where that is not available,
`make dex-proxy` starts a loopback CONNECT proxy
(`tools/warden/cmd/dexproxy`, 127.0.0.1:18443) that dials the k3d loadbalancer for
every CONNECT, which is exactly the decision the hosts entry would have made.
The three identity demos and the four access demos export

```
HTTPS_PROXY=http://127.0.0.1:18443
NO_PROXY=127.0.0.1,0.0.0.0,localhost,::1,.svc,.cluster.local
```

around the kubelogin invocation (`$(OIDC_PROXY_ENV)` in `scripts/identity.mk`);
`NO_PROXY` keeps every `kubectl` call to the API server off the proxy. With the
hosts entry in place the proxy is unnecessary but harmless — the destination
socket is the same either way. The **API server** half never needs it: it
resolves Dex through `make dex-hosts-fix`, which appends the
`host.k3d.internal` address inside the server node.

## What each demo proves

| Demo | Shape | Signal |
| --- | --- | --- |
| `demo-access` | a `kubectl auth can-i` matrix through five real logins | alice reads `team-a-apps` and not `team-b-apps`; alice cannot `create pods/exec` anywhere; bob can create a `RoleBinding` in `team-a-apps` but cannot bind `cluster-admin`; carol sees nothing in team-a; viewer gets everywhere and writes nowhere; ops is not `cluster-admin` and cannot read `secrets` |
| `demo-audit` | bob creates and deletes a RoleBinding in `team-a-apps` | `make audit-tail` shows a `RequestResponse` entry naming `bob@team-a.local` and group `team-a:admin`, with the object body |
| `demo-internal-oidc` | the Hubble UI through the `internal` Gateway | an unauthenticated request is redirected to Dex (`302` to `/auth`); after the password grant the UI returns `200`; no `pods/portforward` right was involved anywhere |

## Escalation prevention is the interesting half of `demo-access`

`platform-team-admin` grants `rolebindings` full, which sounds like a hole. It is
not: the API server's escalation check refuses a `RoleBinding` whose `roleRef`
grants more than the creating user already holds, unless the user holds `bind` on
that role. bob therefore can hand `platform-developer` to a colleague in his own
namespace and cannot hand out `cluster-admin`, `platform-debug` or
`platform-operator`. The demo asserts both directions, because a one-sided
assertion would pass on a cluster where bob simply has no rights at all.
