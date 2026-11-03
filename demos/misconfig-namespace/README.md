What: a ConfigMap `stray` whose manifest names `team-a-apps`, i.e. team-b shipping an object outside its own namespaces by mistake.
Attached to: team `team-b` (artifact `team-b-misconfig:demo`, signed with team-b's cosign key, demo-misconfig-namespace).
Expected: Kustomization `team-b-misconfig` goes Ready=False with `configmaps "stray" is forbidden: User "system:serviceaccount:team-b:flux" cannot create resource "configmaps" in API group "" in the namespace "team-a-apps"`, so the blast radius of the mistake is the team's own reconcile.
