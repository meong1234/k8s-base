package controller

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	accessv1alpha1 "github.com/meong1234/k8s-base/warden/api/v1alpha1"
)

// DefaultSweepInterval is the safety net: the requeue at expiresAt is the
// primary revocation path, this bounds the damage if that requeue is lost
// (manager restart, clock jump, dropped workqueue item).
const DefaultSweepInterval = 30 * time.Second

type AccessRequestReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder

	SweepInterval time.Duration

	// Clock is injected by the unit tests; nil means time.Now.
	Clock func() time.Time
}

// +kubebuilder:rbac:groups=access.k8s-base.io,resources=accessrequests,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=access.k8s-base.io,resources=accessrequests/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=access.k8s-base.io,resources=accessrequests/finalizers,verbs=update
// +kubebuilder:rbac:groups=rbac.authorization.k8s.io,resources=rolebindings;clusterrolebindings,verbs=get;list;watch;create;delete
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

func (r *AccessRequestReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var ar accessv1alpha1.AccessRequest
	if err := r.Get(ctx, req.NamespacedName, &ar); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if !ar.DeletionTimestamp.IsZero() {
		if _, err := r.revoke(ctx, &ar); err != nil {
			return ctrl.Result{}, err
		}
		if controllerutil.RemoveFinalizer(&ar, accessv1alpha1.Finalizer) {
			return ctrl.Result{}, r.Update(ctx, &ar)
		}
		return ctrl.Result{}, nil
	}

	// The finalizer is what keeps a cluster-admin ClusterRoleBinding from
	// outliving its AccessRequest: a cluster-scoped binding cannot carry an
	// owner reference to a namespaced object, so GC would never collect it.
	if controllerutil.AddFinalizer(&ar, accessv1alpha1.Finalizer) {
		if err := r.Update(ctx, &ar); err != nil {
			return ctrl.Result{}, err
		}
	}

	switch ar.Status.Phase {
	case "":
		ar.Status.Phase = accessv1alpha1.PhasePending
		r.event(&ar, corev1.EventTypeNormal, "Requested",
			"%s requested %s on %s for %s: %s",
			ar.Spec.Requester, ar.Spec.Role, ar.Spec.TargetNamespace, ar.Spec.Duration, ar.Spec.Reason)
		r.setCondition(&ar, metav1.ConditionFalse, "Pending", "waiting for approval by another user")
		return ctrl.Result{}, r.Status().Update(ctx, &ar)

	case accessv1alpha1.PhasePending:
		return ctrl.Result{}, nil

	case accessv1alpha1.PhaseApproved:
		return r.activate(ctx, &ar)

	case accessv1alpha1.PhaseActive:
		return r.enforce(ctx, &ar)

	case accessv1alpha1.PhaseDenied, accessv1alpha1.PhaseRevoked, accessv1alpha1.PhaseExpired:
		return ctrl.Result{}, r.terminate(ctx, &ar)
	}

	return ctrl.Result{}, nil
}

// activate turns an approved request into a live binding and moves it to Active.
func (r *AccessRequestReconciler) activate(ctx context.Context, ar *accessv1alpha1.AccessRequest) (ctrl.Result, error) {
	grant, ok := accessv1alpha1.RoleCatalog[ar.Spec.Role]
	if !ok {
		r.event(ar, corev1.EventTypeWarning, "InvalidRole", "unknown role %q, nothing granted", ar.Spec.Role)
		r.setCondition(ar, metav1.ConditionFalse, "InvalidRole", fmt.Sprintf("unknown role %q", ar.Spec.Role))
		return ctrl.Result{}, r.Status().Update(ctx, ar)
	}

	d, err := time.ParseDuration(ar.Spec.Duration)
	if err != nil || d <= 0 {
		r.event(ar, corev1.EventTypeWarning, "InvalidDuration", "cannot parse duration %q, nothing granted", ar.Spec.Duration)
		r.setCondition(ar, metav1.ConditionFalse, "InvalidDuration", fmt.Sprintf("cannot parse duration %q", ar.Spec.Duration))
		return ctrl.Result{}, r.Status().Update(ctx, ar)
	}
	clamped := d
	if clamped > grant.MaxDuration {
		clamped = grant.MaxDuration
	}

	expires := metav1.NewTime(r.now().Add(clamped).UTC().Truncate(time.Second))
	ar.Status.ExpiresAt = &expires
	ar.Status.BindingRef = bindingName(ar)

	if err := r.ensureBinding(ctx, ar, grant); err != nil {
		return ctrl.Result{}, err
	}

	ar.Status.Phase = accessv1alpha1.PhaseActive
	r.setCondition(ar, metav1.ConditionTrue, "Granted",
		fmt.Sprintf("%s bound to %s until %s", ar.Spec.Requester, grant.ClusterRole, expires.UTC().Format(time.RFC3339)))
	r.event(ar, corev1.EventTypeNormal, "Granted",
		"%s granted %s (%s) in %s until %s, approved by %s",
		ar.Spec.Requester, ar.Spec.Role, grant.ClusterRole, bindingScope(ar, grant), expires.UTC().Format(time.RFC3339), ar.Status.ApprovedBy)
	if clamped != d {
		r.event(ar, corev1.EventTypeWarning, "DurationClamped",
			"requested %s exceeds the %s cap for role %s, clamped", ar.Spec.Duration, grant.MaxDuration, ar.Spec.Role)
	}

	if err := r.Status().Update(ctx, ar); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: r.nextCheck(expires.Time)}, nil
}

// enforce is the Active-phase loop: expire when due, otherwise re-assert the
// binding so a manually deleted one comes back and a warden restart converges.
func (r *AccessRequestReconciler) enforce(ctx context.Context, ar *accessv1alpha1.AccessRequest) (ctrl.Result, error) {
	grant, ok := accessv1alpha1.RoleCatalog[ar.Spec.Role]
	if !ok {
		return ctrl.Result{}, r.terminate(ctx, ar)
	}

	if ar.Status.ExpiresAt == nil {
		// Active without an expiry can only come from a write we did not make.
		// Treat it as expired rather than as unbounded access.
		r.event(ar, corev1.EventTypeWarning, "MissingExpiry", "Active without expiresAt, revoking")
		return ctrl.Result{}, r.expire(ctx, ar, "MissingExpiry", "Active without expiresAt")
	}

	if !r.now().Before(ar.Status.ExpiresAt.Time) {
		return ctrl.Result{}, r.expire(ctx, ar, "Expired",
			fmt.Sprintf("window closed at %s", ar.Status.ExpiresAt.UTC().Format(time.RFC3339)))
	}

	if ar.Status.BindingRef == "" {
		ar.Status.BindingRef = bindingName(ar)
		if err := r.Status().Update(ctx, ar); err != nil {
			return ctrl.Result{}, err
		}
	}
	if err := r.ensureBinding(ctx, ar, grant); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: r.nextCheck(ar.Status.ExpiresAt.Time)}, nil
}

func (r *AccessRequestReconciler) expire(ctx context.Context, ar *accessv1alpha1.AccessRequest, reason, msg string) error {
	if _, err := r.revoke(ctx, ar); err != nil {
		return err
	}
	ar.Status.Phase = accessv1alpha1.PhaseExpired
	r.setCondition(ar, metav1.ConditionFalse, reason, msg)
	r.event(ar, corev1.EventTypeNormal, "Expired", "%s: binding %s removed, %s is forbidden again",
		msg, ar.Status.BindingRef, ar.Spec.Requester)
	return r.Status().Update(ctx, ar)
}

// terminate is the Denied / Revoked / Expired resting state: make sure no
// binding survives, and say so exactly once.
func (r *AccessRequestReconciler) terminate(ctx context.Context, ar *accessv1alpha1.AccessRequest) error {
	deleted, err := r.revoke(ctx, ar)
	if err != nil {
		return err
	}
	if !deleted {
		return nil
	}
	r.event(ar, corev1.EventTypeNormal, string(ar.Status.Phase),
		"binding %s removed, %s is forbidden again", bindingName(ar), ar.Spec.Requester)
	r.setCondition(ar, metav1.ConditionFalse, string(ar.Status.Phase), "binding removed")
	return r.Status().Update(ctx, ar)
}

func (r *AccessRequestReconciler) ensureBinding(ctx context.Context, ar *accessv1alpha1.AccessRequest, grant accessv1alpha1.RoleGrant) error {
	meta := metav1.ObjectMeta{
		Name: bindingName(ar),
		Labels: map[string]string{
			accessv1alpha1.LabelManagedBy:        accessv1alpha1.ManagedByValue,
			accessv1alpha1.LabelRequest:          ar.Name,
			accessv1alpha1.LabelRequestNamespace: ar.Namespace,
			accessv1alpha1.LabelRole:             string(ar.Spec.Role),
		},
		Annotations: map[string]string{
			accessv1alpha1.AnnotationRequestUID: string(ar.UID),
			accessv1alpha1.AnnotationRequester:  ar.Spec.Requester,
			accessv1alpha1.AnnotationApprovedBy: ar.Status.ApprovedBy,
			accessv1alpha1.AnnotationReason:     ar.Spec.Reason,
		},
	}
	if ar.Status.ExpiresAt != nil {
		meta.Annotations[accessv1alpha1.AnnotationExpiresAt] = ar.Status.ExpiresAt.UTC().Format(time.RFC3339)
	}

	subjects := []rbacv1.Subject{{
		Kind:     rbacv1.UserKind,
		APIGroup: rbacv1.GroupName,
		Name:     ar.Spec.Requester,
	}}
	roleRef := rbacv1.RoleRef{
		APIGroup: rbacv1.GroupName,
		Kind:     "ClusterRole",
		Name:     grant.ClusterRole,
	}

	var obj client.Object
	if grant.ClusterScope {
		obj = &rbacv1.ClusterRoleBinding{ObjectMeta: meta, Subjects: subjects, RoleRef: roleRef}
	} else {
		meta.Namespace = ar.Spec.TargetNamespace
		rb := &rbacv1.RoleBinding{ObjectMeta: meta, Subjects: subjects, RoleRef: roleRef}
		// Owner references are namespace-local, so only a same-namespace
		// request gets GC for free; everything else relies on the finalizer.
		if ar.Namespace == ar.Spec.TargetNamespace {
			if err := controllerutil.SetControllerReference(ar, rb, r.Scheme); err != nil {
				return err
			}
		}
		obj = rb
	}

	err := r.Create(ctx, obj)
	if apierrors.IsAlreadyExists(err) {
		return nil
	}
	return err
}

func (r *AccessRequestReconciler) revoke(ctx context.Context, ar *accessv1alpha1.AccessRequest) (bool, error) {
	name := ar.Status.BindingRef
	if name == "" {
		// A crash between Create and the status write would otherwise orphan
		// the binding: the name is deterministic, so look it up anyway.
		name = bindingName(ar)
	}

	grant, ok := accessv1alpha1.RoleCatalog[ar.Spec.Role]
	if !ok {
		return false, nil
	}

	var obj client.Object
	key := types.NamespacedName{Name: name}
	if grant.ClusterScope {
		obj = &rbacv1.ClusterRoleBinding{}
	} else {
		obj = &rbacv1.RoleBinding{}
		key.Namespace = ar.Spec.TargetNamespace
	}

	if err := r.Get(ctx, key, obj); err != nil {
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return false, err
	}
	if err := r.Delete(ctx, obj); err != nil && !apierrors.IsNotFound(err) {
		return false, err
	}
	log.FromContext(ctx).Info("revoked jit binding", "binding", name, "role", ar.Spec.Role)
	return true, nil
}

func (r *AccessRequestReconciler) setCondition(ar *accessv1alpha1.AccessRequest, status metav1.ConditionStatus, reason, msg string) {
	for i := range ar.Status.Conditions {
		c := &ar.Status.Conditions[i]
		if c.Type != accessv1alpha1.ConditionGranted {
			continue
		}
		if c.Status != status {
			c.LastTransitionTime = metav1.NewTime(r.now())
		}
		c.Status, c.Reason, c.Message, c.ObservedGeneration = status, reason, msg, ar.Generation
		return
	}
	ar.Status.Conditions = append(ar.Status.Conditions, metav1.Condition{
		Type:               accessv1alpha1.ConditionGranted,
		Status:             status,
		Reason:             reason,
		Message:            msg,
		ObservedGeneration: ar.Generation,
		LastTransitionTime: metav1.NewTime(r.now()),
	})
}

func (r *AccessRequestReconciler) event(ar *accessv1alpha1.AccessRequest, kind, reason, format string, args ...any) {
	if r.Recorder == nil {
		return
	}
	r.Recorder.Eventf(ar, kind, reason, format, args...)
}

func (r *AccessRequestReconciler) now() time.Time {
	if r.Clock != nil {
		return r.Clock()
	}
	return time.Now()
}

func (r *AccessRequestReconciler) sweepInterval() time.Duration {
	if r.SweepInterval > 0 {
		return r.SweepInterval
	}
	return DefaultSweepInterval
}

func (r *AccessRequestReconciler) nextCheck(expires time.Time) time.Duration {
	sweep := r.sweepInterval()
	until := expires.Sub(r.now())
	if until <= 0 {
		return time.Second
	}
	if until < sweep {
		return until
	}
	return sweep
}

func bindingName(ar *accessv1alpha1.AccessRequest) string {
	return accessv1alpha1.BindingPrefix + ar.Name
}

func bindingScope(ar *accessv1alpha1.AccessRequest, grant accessv1alpha1.RoleGrant) string {
	if grant.ClusterScope {
		return "the whole cluster"
	}
	return "namespace " + ar.Spec.TargetNamespace
}

func (r *AccessRequestReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&accessv1alpha1.AccessRequest{}).
		Owns(&rbacv1.RoleBinding{}).
		Named("accessrequest").
		Complete(r)
}
