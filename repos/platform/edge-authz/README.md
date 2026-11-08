# edge-authz (platform half)

The Deployment, Service and ServiceAccount of the partner API-key authorizer,
in `platform-ingress`. The code, the contract with Envoy and the reasons it
watches Secrets rather than mounting them are in
[`tools/edge-authz/README.md`](../../../tools/edge-authz/README.md).

Two things are deliberately **not** here:

- **The Secret-read grant.** It lives in `partner-api`, which the teams
  `ResourceSet` creates after this stage is Ready, so shipping it from here
  would deadlock `make up`. The fleet template stamps it into every
  `partner-edge` namespace (`repos/fleet/base/teams.yaml`).
- **The policy that calls it.** `AuthorizationPolicy partner-edge-api-key` is
  an Istio custom resource and therefore a second-stage object, in
  `repos/platform/edge-policies/base/`.

The pod carries `istio.io/dataplane-mode: ambient` itself. The namespace does
not: its other pods are the ingress gateways, which must not be captured.
