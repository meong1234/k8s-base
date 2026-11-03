// Package v1alpha1 contains the AccessRequest API for the just-in-time
// privileged-access warden.
//
// +kubebuilder:object:generate=true
// +groupName=access.k8s-base.io
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	GroupVersion = schema.GroupVersion{Group: "access.k8s-base.io", Version: "v1alpha1"}

	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	AddToScheme = SchemeBuilder.AddToScheme
)
