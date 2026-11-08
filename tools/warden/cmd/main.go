// Command access-warden reconciles AccessRequest objects into time-bound
// RoleBindings and ClusterRoleBindings.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	accessv1alpha1 "github.com/meong1234/k8s-base/warden/api/v1alpha1"
	"github.com/meong1234/k8s-base/warden/internal/controller"
)

var scheme = runtime.NewScheme()

func init() {
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		panic(err)
	}
	if err := accessv1alpha1.AddToScheme(scheme); err != nil {
		panic(err)
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "access-warden: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		metricsAddr   string
		probeAddr     string
		sweepInterval time.Duration
	)
	fs := flag.NewFlagSet("access-warden", flag.ExitOnError)
	fs.StringVar(&metricsAddr, "metrics-bind-address", "0", "metrics endpoint address, 0 disables it")
	fs.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "health and readiness endpoint address")
	fs.DurationVar(&sweepInterval, "sweep-interval", controller.DefaultSweepInterval,
		"how often an Active request is re-checked for expiry")
	zapOpts := zap.Options{Development: false}
	zapOpts.BindFlags(fs)
	if err := fs.Parse(os.Args[1:]); err != nil {
		return err
	}

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&zapOpts)))

	cfg, err := ctrl.GetConfig()
	if err != nil {
		return fmt.Errorf("no kubernetes API reachable (expected an in-cluster ServiceAccount or a KUBECONFIG): %w", err)
	}

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		// One replica by design: leader election would only add
		// a lease to maintain and a second identity to audit.
		LeaderElection: false,
	})
	if err != nil {
		return fmt.Errorf("manager: %w", err)
	}

	reconciler := &controller.AccessRequestReconciler{
		Client:        mgr.GetClient(),
		Scheme:        mgr.GetScheme(),
		Recorder:      mgr.GetEventRecorderFor("access-warden"),
		SweepInterval: sweepInterval,
	}
	if err := reconciler.SetupWithManager(mgr); err != nil {
		return fmt.Errorf("controller: %w", err)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		return fmt.Errorf("healthz: %w", err)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		return fmt.Errorf("readyz: %w", err)
	}

	ctrl.Log.Info("starting access-warden", "sweepInterval", sweepInterval)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil && !errors.Is(err, os.ErrClosed) {
		return fmt.Errorf("manager exited: %w", err)
	}
	return nil
}
