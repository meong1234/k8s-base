package v1alpha1

import "time"

const (
	// AnnotationPrefix is deliberately the bare domain without a version: the
	// jit-binding-lock admission policy matches on these exact keys.
	AnnotationRequestUID = "access.k8s-base/request-uid"
	AnnotationExpiresAt  = "access.k8s-base/expires-at"
	AnnotationRequester  = "access.k8s-base/requester"
	AnnotationApprovedBy = "access.k8s-base/approved-by"
	AnnotationReason     = "access.k8s-base/reason"

	LabelManagedBy        = "access.k8s-base/managed-by"
	LabelRequest          = "access.k8s-base/request"
	LabelRequestNamespace = "access.k8s-base/request-namespace"
	LabelRole             = "access.k8s-base/role"

	ManagedByValue = "access-warden"

	BindingPrefix = "jit-"

	Finalizer = "access.k8s-base.io/revoke"

	ConditionGranted = "Granted"
)

// RoleGrant is the static mapping from a request role to the one ClusterRole
// the warden holds `bind` on, plus the cap the warden clamps duration to.
type RoleGrant struct {
	ClusterRole  string
	MaxDuration  time.Duration
	ClusterScope bool
}

var RoleCatalog = map[Role]RoleGrant{
	RoleDebug:        {ClusterRole: "platform-debug", MaxDuration: 4 * time.Hour},
	RoleTeamAdmin:    {ClusterRole: "platform-team-admin", MaxDuration: 8 * time.Hour},
	RoleClusterAdmin: {ClusterRole: "cluster-admin", MaxDuration: 1 * time.Hour, ClusterScope: true},
}
