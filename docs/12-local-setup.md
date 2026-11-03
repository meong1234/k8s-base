# Local setup

> **Who this is for.** Anyone who wants the whole platform running on their
> laptop. **Afterwards you can** bring it up, understand what each stage of
> `make up` did, log in as a demo user, run a demo and read its result, and
> tear it all down.

## What you get

A three-node k3d cluster (one server, two agents) running inside Docker,
with Cilium as the network layer, Istio in ambient mode, three Envoy
gateways, Dex, cert-manager, Flux with two shards, four tenant teams, the
security team's three edge namespaces, the access warden, and beside the
cluster an nginx container playing a partner that demands a client
certificate. Everything pulls from a local registry that `make up` preloads,
so once the images are cached the cluster can be rebuilt without internet.

```
   your laptop
   ├── Docker network k3d-local-dev (172.28.0.0/16)
   │   ├── k3d-local-dev-server-0        API server, Cilium, ztunnel, the platform's controllers
   │   ├── k3d-local-dev-agent-0, -1     workloads
   │   ├── k3d-local-dev-serverlb        :8080 ──▶ 80   :8443 ──▶ 443   :9443 ──▶ 9443   (the gateways)
   │   ├── k3d-local-dev-registry        localhost:5050 outside, :5000 inside   artifacts + mirrored images
   │   └── k3d-local-dev-partner-bank    172.28.0.250   nginx that demands a client certificate
   ├── .keys/                            CA, age and cosign keys, user kubeconfigs   (git-ignored)
   ├── tmp/demos/                        demo transcripts
   └── /etc/hosts  or  make dex-proxy    api. dex. hubble.internal.local-dev.test ──▶ 127.0.0.1
```

It needs Docker Desktop with a generous memory allowance, and the tools
below. The first `make up` takes a while, mostly preloading images; later
ones are faster.

## Tools

```sh
make brew-setup-all   # installs and updates everything through Homebrew
make tools-check      # prints each required CLI and its version, or MISSING
```

The list, and what each is for: `k3d` (the cluster), `kubectl`,
`kustomize` (rendering manifests), `flux` (pushing artifacts and inspecting
Flux), `helm`, `cosign` (signing), `sops` and `age` (secrets), `cilium` and
`hubble` (network observability), `jq` and `yq` (the scripts), `kubeconform`
(schema checks), `kubelogin` (OIDC login), plus `htpasswd` and `openssl`
which macOS ships. Go is needed only if you rebuild the warden or the tiny
login proxy.

## Up, status, down

```sh
make up        # everything below, in order
make status    # cluster, Flux and artifact state
make down      # deletes the cluster and the partner container; keeps the registry cache and .keys/
```

`make up` is a chain of steps and each one checks for what already exists,
so if it stops partway, read the last lines and run it again. What the
chain does, so you recognise the stages scrolling past:

1. **Certificates and identity files.** Generates the platform CA, renders
   the API server's authentication config and Dex's user list from
   `identity/users.yaml`, writes the OIDC client secrets.
2. **Cluster and registry.** Creates the local registry if needed, creates
   the k3d cluster from `k3d/cluster.yaml` with Cilium as CNI, PodSecurity
   restricted, the audit policy and the OIDC config mounted in, and waits
   for Cilium.
3. **The partner simulation.** Starts the nginx container on the k3d Docker
   network at a fixed address.
4. **Images.** Pulls every image the platform needs and pushes it into the
   local registry, which the nodes use as a mirror.
5. **Keys.** Generates an age pair and a cosign pair for the platform and for
   every team, renders each team's `.sops.yaml`.
6. **Flux.** Installs the Flux operator, pushes and signs the three platform
   artifacts, applies the FluxInstance and the cluster variables, applies
   the bootstrap sync, and waits for it to fan out through `infra`,
   `platform` and the teams ResourceSet.
7. **Out-of-band secrets.** Injects the platform CA, the partner client
   certificate, the Dex client secrets, and each team's age and cosign keys
   into their namespaces. These are the only things on the cluster that did
   not arrive through an artifact, and they are the things an artifact must
   never contain.
8. **Team artifacts.** Pushes and signs every team repo.

It ends with "Environment is now ready". `make status` then shows the
cluster, every Flux object and the registry's tags.

## Names your laptop needs to resolve

The gateways listen on `127.0.0.1`, but the demos and your browser use
hostnames: `api.local-dev.test`, `dex.local-dev.test`,
`hubble.internal.local-dev.test`.

```sh
make hosts-print      # the one /etc/hosts line, and whether each name is present
```

If you cannot edit `/etc/hosts`, `make dex-proxy` starts a small loopback
proxy that makes the same name-to-address decision for the OIDC login, and
the demos use it automatically. The API server inside the cluster resolves
Dex on its own; `make up` arranges that.

## Logging in

```sh
make login-help                              # the six users, their groups, their passwords
make login USER=alice@team-a.local           # writes .keys/local/users/alice@team-a.local/kubeconfig
make whoami KUBECONFIG=.keys/local/users/alice@team-a.local/kubeconfig
```

The first `kubectl` with that kubeconfig opens a browser at Dex; after that
the token is cached. The admin kubeconfig k3d wrote is still your default,
and it is the bootstrap identity the platform knows about. The per-user
kubeconfigs are for acting as a specific person, which is what the
[identity page](07-identity-and-access.md) and the access demos are about.

## Running the demos

```sh
make demo-all                  # every demo in order, with cleanups, then a PASS/FAIL table
make demo-jit                  # one demo
make demo-jit-cleanup          # its cleanup, where one exists
```

Each demo prints a one-line claim, every command it runs with the output
indented under it, then an `EXPECTED` line and one `[ok]` or `[FAIL]` per
assertion. The full transcript is in `tmp/demos/<name>.log`. The
[guarantees page](05-guarantees.md) says what each demo is showing and what
the key lines look like.

The demos are local-only and a guard refuses them on any other
`CLUSTER_ENV`. They edit the fleet input, push scratch artifacts, apply
deliberately broken objects and suspend reconciliation, all of which is fine
on a laptop and nowhere else. `demo-netpol` and `demo-cross-team-access`
wait for Cilium to settle and are slower than the rest. If a demo is
interrupted, run its cleanup target; a suspended Kustomization is the one
state that does not heal itself.

## Things that are only true on a laptop

Each of these lives under a unit's `envs/local/` or a `clusters/local/` directory,
and `make env-check` refuses its literal anywhere else:

- Dex uses static passwords and allows the password grant so the demos can
  log in without a browser. A real environment removes both.
- The certificates come from a local CA in `.keys/local/platform/`. Pass
  `--cacert` to curl, or trust the CA in your browser.
- The registry is plain HTTP and the sources say `insecure: true`.
- The partner bank is an nginx container at a fixed address.
- Two cluster-wide Cilium rules exist only because of how kubelet probes
  arrive on Docker Desktop.
- Resource requests are small, and the Flux instance is patched smaller.

## Useful targets

```sh
make help                      # every target, grouped by area
make team-status TEAM=team-b   # one team: namespaces, Flux objects, injected secrets, pods, effective RBAC
make flux-status               # FluxInstance, ResourceSet, every Flux object
make access-list               # every access request and every live grant
make audit-tail                # the last human actions in the audit log
make istio-status              # mesh enrollment and mTLS mode
make hubble-ui                 # port-forward the Hubble UI (the gateway route is the login-based way)
```

## Where the detail lives

- The `up` chain and every per-area target: `Makefile`, `scripts/*.mk`
- The cluster definition, the admission defaults and the audit policy: `k3d/`
- Logging in without root, and the proxy that stands in for the hosts line: `demos/access/README.md`
