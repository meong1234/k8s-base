package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Role is the privilege tier a request asks for. Each value maps to exactly one
// ClusterRole the warden is allowed to bind (see RoleCatalog).
// +kubebuilder:validation:Enum=debug;team-admin;cluster-admin
type Role string

const (
	RoleDebug        Role = "debug"
	RoleTeamAdmin    Role = "team-admin"
	RoleClusterAdmin Role = "cluster-admin"
)

// Phase is the request's position in the state machine
// Pending -> Approved -> Active -> Expired | Denied | Revoked.
// +kubebuilder:validation:Enum=Pending;Approved;Active;Expired;Denied;Revoked
type Phase string

const (
	PhasePending  Phase = "Pending"
	PhaseApproved Phase = "Approved"
	PhaseActive   Phase = "Active"
	PhaseExpired  Phase = "Expired"
	PhaseDenied   Phase = "Denied"
	PhaseRevoked  Phase = "Revoked"
)

type AccessRequestSpec struct {
	// Requester is the OIDC username the grant is issued to. The
	// access-request-create admission policy pins it to the creating user.
	// +kubebuilder:validation:MinLength=1
	Requester string `json:"requester"`

	// +kubebuilder:validation:Required
	Role Role `json:"role"`

	// TargetNamespace is where the RoleBinding lands. Ignored for
	// role cluster-admin, whose grant is cluster-scoped.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	TargetNamespace string `json:"targetNamespace"`

	// +kubebuilder:validation:MinLength=10
	// +kubebuilder:validation:MaxLength=512
	Reason string `json:"reason"`

	// Duration is a Go duration string such as 30m or 2h. The per-role cap is
	// enforced by admission at request time and clamped again by the warden.
	// +kubebuilder:validation:Pattern=`^([0-9]+(s|m|h))+$`
	Duration string `json:"duration"`
}

type AccessRequestStatus struct {
	// +optional
	Phase Phase `json:"phase,omitempty"`

	// ApprovedBy is the OIDC username of the approver. The
	// access-request-approve admission policy pins it to the patching user and
	// forbids self-approval.
	// +optional
	ApprovedBy string `json:"approvedBy,omitempty"`

	// +optional
	ExpiresAt *metav1.Time `json:"expiresAt,omitempty"`

	// BindingRef is the name of the RoleBinding or ClusterRoleBinding the
	// warden created; it is the only handle the sweep needs.
	// +optional
	BindingRef string `json:"bindingRef,omitempty"`

	// +optional
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=ar;areq,categories=access
// +kubebuilder:printcolumn:name="Role",type=string,JSONPath=`.spec.role`
// +kubebuilder:printcolumn:name="Target",type=string,JSONPath=`.spec.targetNamespace`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="ApprovedBy",type=string,JSONPath=`.status.approvedBy`
// +kubebuilder:printcolumn:name="ExpiresAt",type=string,JSONPath=`.status.expiresAt`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
type AccessRequest struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   AccessRequestSpec   `json:"spec"`
	Status AccessRequestStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type AccessRequestList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []AccessRequest `json:"items"`
}

func init() {
	SchemeBuilder.Register(&AccessRequest{}, &AccessRequestList{})
}
