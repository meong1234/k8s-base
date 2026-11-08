package controller

import (
	"context"
	"strings"
	"testing"
	"time"

	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	accessv1alpha1 "github.com/meong1234/k8s-base/warden/api/v1alpha1"
)

const (
	reqNS     = "team-a"
	targetNS  = "team-a-apps"
	requester = "alice@team-a.local"
	approver  = "bob@team-a.local"
)

func testScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := accessv1alpha1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	return s
}

func newRequest(name string, role accessv1alpha1.Role, duration string) *accessv1alpha1.AccessRequest {
	return &accessv1alpha1.AccessRequest{
		ObjectMeta: metav1.ObjectMeta{
			Name:       name,
			Namespace:  reqNS,
			UID:        types.UID("uid-" + name),
			Finalizers: []string{accessv1alpha1.Finalizer},
		},
		Spec: accessv1alpha1.AccessRequestSpec{
			Requester:       requester,
			Role:            role,
			TargetNamespace: targetNS,
			Reason:          "podinfo 5xx after 14:00",
			Duration:        duration,
		},
	}
}

type harness struct {
	r      *AccessRequestReconciler
	c      client.Client
	events *record.FakeRecorder
	clock  time.Time
	name   string
}

func newHarness(t *testing.T, ar *accessv1alpha1.AccessRequest) *harness {
	t.Helper()
	s := testScheme(t)
	c := fake.NewClientBuilder().
		WithScheme(s).
		WithObjects(ar).
		WithStatusSubresource(&accessv1alpha1.AccessRequest{}).
		Build()
	h := &harness{
		c:      c,
		events: record.NewFakeRecorder(64),
		clock:  time.Date(2026, 11, 2, 14, 0, 0, 0, time.UTC),
		name:   ar.Name,
	}
	h.r = &AccessRequestReconciler{
		Client:        c,
		Scheme:        s,
		Recorder:      h.events,
		SweepInterval: DefaultSweepInterval,
		Clock:         func() time.Time { return h.clock },
	}
	return h
}

func (h *harness) reconcile(t *testing.T) ctrl.Result {
	t.Helper()
	res, err := h.r.Reconcile(context.Background(), ctrl.Request{
		NamespacedName: types.NamespacedName{Namespace: reqNS, Name: h.name},
	})
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	return res
}

func (h *harness) get(t *testing.T) *accessv1alpha1.AccessRequest {
	t.Helper()
	var ar accessv1alpha1.AccessRequest
	if err := h.c.Get(context.Background(), types.NamespacedName{Namespace: reqNS, Name: h.name}, &ar); err != nil {
		t.Fatalf("get: %v", err)
	}
	return &ar
}

func (h *harness) approve(t *testing.T) {
	t.Helper()
	ar := h.get(t)
	ar.Status.Phase = accessv1alpha1.PhaseApproved
	ar.Status.ApprovedBy = approver
	if err := h.c.Status().Update(context.Background(), ar); err != nil {
		t.Fatalf("approve: %v", err)
	}
}

func (h *harness) setPhase(t *testing.T, p accessv1alpha1.Phase) {
	t.Helper()
	ar := h.get(t)
	ar.Status.Phase = p
	if err := h.c.Status().Update(context.Background(), ar); err != nil {
		t.Fatalf("set phase: %v", err)
	}
}

func (h *harness) roleBinding(t *testing.T) (*rbacv1.RoleBinding, bool) {
	t.Helper()
	var rb rbacv1.RoleBinding
	err := h.c.Get(context.Background(), types.NamespacedName{Namespace: targetNS, Name: accessv1alpha1.BindingPrefix + h.name}, &rb)
	if apierrors.IsNotFound(err) {
		return nil, false
	}
	if err != nil {
		t.Fatalf("get rolebinding: %v", err)
	}
	return &rb, true
}

func (h *harness) clusterRoleBinding(t *testing.T) (*rbacv1.ClusterRoleBinding, bool) {
	t.Helper()
	var crb rbacv1.ClusterRoleBinding
	err := h.c.Get(context.Background(), types.NamespacedName{Name: accessv1alpha1.BindingPrefix + h.name}, &crb)
	if apierrors.IsNotFound(err) {
		return nil, false
	}
	if err != nil {
		t.Fatalf("get clusterrolebinding: %v", err)
	}
	return &crb, true
}

func (h *harness) sawEvent(reason string) bool {
	for {
		select {
		case e := <-h.events.Events:
			if strings.Contains(e, reason) {
				return true
			}
		default:
			return false
		}
	}
}

func TestEmptyPhaseBecomesPending(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-1", accessv1alpha1.RoleDebug, "1h"))
	h.reconcile(t)

	if got := h.get(t).Status.Phase; got != accessv1alpha1.PhasePending {
		t.Fatalf("phase = %q, want Pending", got)
	}
	if _, ok := h.roleBinding(t); ok {
		t.Fatal("a Pending request must not have a binding")
	}
	if !h.sawEvent("Requested") {
		t.Fatal("no Requested event")
	}
}

func TestPendingGrantsNothing(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-2", accessv1alpha1.RoleDebug, "1h"))
	h.reconcile(t)
	h.reconcile(t)

	if _, ok := h.roleBinding(t); ok {
		t.Fatal("binding created without an approval")
	}
}

func TestApprovedCreatesAnnotatedRoleBinding(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-3", accessv1alpha1.RoleDebug, "2m"))
	h.reconcile(t)
	h.approve(t)
	res := h.reconcile(t)

	ar := h.get(t)
	if ar.Status.Phase != accessv1alpha1.PhaseActive {
		t.Fatalf("phase = %q, want Active", ar.Status.Phase)
	}
	want := accessv1alpha1.BindingPrefix + "alice-debug-3"
	if ar.Status.BindingRef != want {
		t.Fatalf("bindingRef = %q, want %q", ar.Status.BindingRef, want)
	}
	if ar.Status.ExpiresAt == nil || !ar.Status.ExpiresAt.Time.Equal(h.clock.Add(2*time.Minute)) {
		t.Fatalf("expiresAt = %v, want %v", ar.Status.ExpiresAt, h.clock.Add(2*time.Minute))
	}
	if res.RequeueAfter <= 0 || res.RequeueAfter > DefaultSweepInterval {
		t.Fatalf("requeueAfter = %v, want (0, %v]", res.RequeueAfter, DefaultSweepInterval)
	}

	rb, ok := h.roleBinding(t)
	if !ok {
		t.Fatal("no RoleBinding created")
	}
	if rb.RoleRef.Name != "platform-debug" || rb.RoleRef.Kind != "ClusterRole" {
		t.Fatalf("roleRef = %+v", rb.RoleRef)
	}
	if len(rb.Subjects) != 1 || rb.Subjects[0].Kind != rbacv1.UserKind || rb.Subjects[0].Name != requester {
		t.Fatalf("subjects = %+v", rb.Subjects)
	}
	for k, want := range map[string]string{
		accessv1alpha1.AnnotationRequestUID: "uid-alice-debug-3",
		accessv1alpha1.AnnotationRequester:  requester,
		accessv1alpha1.AnnotationApprovedBy: approver,
		accessv1alpha1.AnnotationReason:     "podinfo 5xx after 14:00",
		accessv1alpha1.AnnotationExpiresAt:  "2026-11-02T14:02:00Z",
	} {
		if got := rb.Annotations[k]; got != want {
			t.Errorf("annotation %s = %q, want %q", k, got, want)
		}
	}
	if rb.Labels[accessv1alpha1.LabelManagedBy] != accessv1alpha1.ManagedByValue ||
		rb.Labels[accessv1alpha1.LabelRequest] != "alice-debug-3" ||
		rb.Labels[accessv1alpha1.LabelRequestNamespace] != reqNS ||
		rb.Labels[accessv1alpha1.LabelRole] != "debug" {
		t.Fatalf("labels = %+v", rb.Labels)
	}
	// Different namespaces, so no owner reference is possible.
	if len(rb.OwnerReferences) != 0 {
		t.Fatalf("ownerReferences = %+v, want none across namespaces", rb.OwnerReferences)
	}
	if !h.sawEvent("Granted") {
		t.Fatal("no Granted event")
	}
}

func TestSameNamespaceRequestGetsOwnerReference(t *testing.T) {
	ar := newRequest("alice-debug-4", accessv1alpha1.RoleDebug, "1h")
	ar.Spec.TargetNamespace = reqNS
	h := newHarness(t, ar)
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)

	var rb rbacv1.RoleBinding
	if err := h.c.Get(context.Background(), types.NamespacedName{Namespace: reqNS, Name: accessv1alpha1.BindingPrefix + "alice-debug-4"}, &rb); err != nil {
		t.Fatalf("get: %v", err)
	}
	if len(rb.OwnerReferences) != 1 || rb.OwnerReferences[0].Name != "alice-debug-4" {
		t.Fatalf("ownerReferences = %+v", rb.OwnerReferences)
	}
}

func TestClusterAdminCreatesClusterRoleBindingWithoutOwner(t *testing.T) {
	h := newHarness(t, newRequest("ops-ca-1", accessv1alpha1.RoleClusterAdmin, "1h"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)

	if _, ok := h.roleBinding(t); ok {
		t.Fatal("cluster-admin must not produce a RoleBinding")
	}
	crb, ok := h.clusterRoleBinding(t)
	if !ok {
		t.Fatal("no ClusterRoleBinding created")
	}
	if crb.RoleRef.Name != "cluster-admin" {
		t.Fatalf("roleRef = %+v", crb.RoleRef)
	}
	if len(crb.OwnerReferences) != 0 {
		t.Fatalf("a cluster-scoped binding must carry no owner reference, got %+v", crb.OwnerReferences)
	}
}

func TestDurationIsClampedToTheRoleCap(t *testing.T) {
	h := newHarness(t, newRequest("ops-ca-2", accessv1alpha1.RoleClusterAdmin, "8h"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)

	ar := h.get(t)
	if want := h.clock.Add(time.Hour); !ar.Status.ExpiresAt.Time.Equal(want) {
		t.Fatalf("expiresAt = %v, want %v (1h cap)", ar.Status.ExpiresAt, want)
	}
	if !h.sawEvent("DurationClamped") {
		t.Fatal("no DurationClamped event")
	}
}

func TestExpiryDeletesTheBinding(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-5", accessv1alpha1.RoleDebug, "2m"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)
	if _, ok := h.roleBinding(t); !ok {
		t.Fatal("binding missing while Active")
	}

	h.clock = h.clock.Add(3 * time.Minute)
	h.reconcile(t)

	if got := h.get(t).Status.Phase; got != accessv1alpha1.PhaseExpired {
		t.Fatalf("phase = %q, want Expired", got)
	}
	if _, ok := h.roleBinding(t); ok {
		t.Fatal("binding survived expiry")
	}
	if !h.sawEvent("Expired") {
		t.Fatal("no Expired event")
	}
}

func TestActiveRecreatesADeletedBinding(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-6", accessv1alpha1.RoleDebug, "1h"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)

	rb, _ := h.roleBinding(t)
	if err := h.c.Delete(context.Background(), rb); err != nil {
		t.Fatalf("delete: %v", err)
	}
	h.reconcile(t)

	if _, ok := h.roleBinding(t); !ok {
		t.Fatal("binding not restored inside an Active window")
	}
}

func TestReconcileIsIdempotent(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-7", accessv1alpha1.RoleDebug, "1h"))
	h.reconcile(t)
	h.approve(t)
	first := h.reconcile(t)
	expires := h.get(t).Status.ExpiresAt.DeepCopy()

	h.clock = h.clock.Add(5 * time.Second)
	second := h.reconcile(t)

	if !h.get(t).Status.ExpiresAt.Time.Equal(expires.Time) {
		t.Fatal("expiresAt moved on a second reconcile: the window must not slide")
	}
	if first.RequeueAfter <= 0 || second.RequeueAfter <= 0 {
		t.Fatalf("requeue lost: %v then %v", first, second)
	}
}

func TestRevokedDeletesTheBinding(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-8", accessv1alpha1.RoleDebug, "1h"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)

	h.setPhase(t, accessv1alpha1.PhaseRevoked)
	h.reconcile(t)

	if _, ok := h.roleBinding(t); ok {
		t.Fatal("binding survived revocation")
	}
	if !h.sawEvent("Revoked") {
		t.Fatal("no Revoked event")
	}
}

func TestDeniedNeverGrants(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-9", accessv1alpha1.RoleDebug, "1h"))
	h.reconcile(t)
	h.setPhase(t, accessv1alpha1.PhaseDenied)
	h.reconcile(t)

	if _, ok := h.roleBinding(t); ok {
		t.Fatal("a Denied request produced a binding")
	}
}

func TestDeletionRevokesAClusterRoleBinding(t *testing.T) {
	h := newHarness(t, newRequest("ops-ca-3", accessv1alpha1.RoleClusterAdmin, "1h"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)
	if _, ok := h.clusterRoleBinding(t); !ok {
		t.Fatal("no ClusterRoleBinding to start from")
	}

	if err := h.c.Delete(context.Background(), h.get(t)); err != nil {
		t.Fatalf("delete: %v", err)
	}
	h.reconcile(t)

	if _, ok := h.clusterRoleBinding(t); ok {
		t.Fatal("ClusterRoleBinding outlived its AccessRequest")
	}
	var ar accessv1alpha1.AccessRequest
	if err := h.c.Get(context.Background(), types.NamespacedName{Namespace: reqNS, Name: "ops-ca-3"}, &ar); !apierrors.IsNotFound(err) {
		t.Fatalf("finalizer not removed: %v", err)
	}
}

func TestActiveWithoutExpiryIsRevoked(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-10", accessv1alpha1.RoleDebug, "1h"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)

	ar := h.get(t)
	ar.Status.ExpiresAt = nil
	if err := h.c.Status().Update(context.Background(), ar); err != nil {
		t.Fatalf("tamper: %v", err)
	}
	h.reconcile(t)

	if got := h.get(t).Status.Phase; got != accessv1alpha1.PhaseExpired {
		t.Fatalf("phase = %q, want Expired", got)
	}
	if _, ok := h.roleBinding(t); ok {
		t.Fatal("unbounded binding left in place")
	}
}

func TestInvalidDurationGrantsNothing(t *testing.T) {
	h := newHarness(t, newRequest("alice-debug-11", accessv1alpha1.RoleDebug, "banana"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)

	if _, ok := h.roleBinding(t); ok {
		t.Fatal("unparsable duration produced a binding")
	}
	if got := h.get(t).Status.Phase; got != accessv1alpha1.PhaseApproved {
		t.Fatalf("phase = %q, want it parked at Approved", got)
	}
	if !h.sawEvent("InvalidDuration") {
		t.Fatal("no InvalidDuration event")
	}
}

func TestRestartRebuildsFromStatusAndLabels(t *testing.T) {
	// Simulates a warden restart: the AccessRequest is already Active with a
	// live binding, and a fresh reconciler must neither duplicate nor drop it.
	h := newHarness(t, newRequest("alice-debug-12", accessv1alpha1.RoleDebug, "1h"))
	h.reconcile(t)
	h.approve(t)
	h.reconcile(t)

	fresh := &AccessRequestReconciler{
		Client:   h.c,
		Scheme:   h.r.Scheme,
		Recorder: record.NewFakeRecorder(16),
		Clock:    func() time.Time { return h.clock },
	}
	if _, err := fresh.Reconcile(context.Background(), ctrl.Request{
		NamespacedName: types.NamespacedName{Namespace: reqNS, Name: "alice-debug-12"},
	}); err != nil {
		t.Fatalf("reconcile after restart: %v", err)
	}

	rb, ok := h.roleBinding(t)
	if !ok {
		t.Fatal("binding lost across a restart")
	}
	var list rbacv1.RoleBindingList
	if err := h.c.List(context.Background(), &list, client.InNamespace(targetNS),
		client.MatchingLabels{accessv1alpha1.LabelManagedBy: accessv1alpha1.ManagedByValue}); err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(list.Items) != 1 {
		t.Fatalf("listed %d warden bindings, want 1", len(list.Items))
	}
	if list.Items[0].Name != rb.Name {
		t.Fatalf("listed %q, want %q", list.Items[0].Name, rb.Name)
	}
}
