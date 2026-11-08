// edge-authz answers Envoy's HTTP ext_authz check for the partner door.
//
// Envoy forwards the original method, path and Host plus the headers the mesh
// config lists; this service maps the Host's first label to a Secret named
// <partner><suffix>, compares the presented key against every entry of that
// Secret and, on a match, answers 200 with the entry's name in the partner-id
// header. Everything else is the same 401. A 5xx would be read by Envoy as
// "authorizer down", never as "no", so this code never answers one on purpose.
package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

type config struct {
	listen          string
	probeListen     string
	secretsNS       string
	secretSuffix    string
	keyHeader       string
	partnerIDHeader string
	kubeconfig      string
}

// lookup returns the key Secret for a partner, or an error when there is none.
type lookup func(partner string) (*corev1.Secret, error)

type authorizer struct {
	cfg    config
	secret lookup
	log    *slog.Logger
}

// partnerFromHost takes the first DNS label of an :authority, port stripped.
func partnerFromHost(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	label, _, _ := strings.Cut(host, ".")
	return strings.ToLower(label)
}

// decide returns the client id whose key matched, or "" and the deny reason.
func (a *authorizer) decide(host, presented string) (clientID, reason string) {
	partner := partnerFromHost(host)
	if partner == "" || partner == "*" {
		return "", "no partner label in host"
	}
	if presented == "" {
		return "", "no key presented"
	}
	secret, err := a.secret(partner + a.cfg.secretSuffix)
	if err != nil {
		return "", "no key secret for partner"
	}
	// Sorted so a Secret with two entries holding the same key is deterministic.
	ids := make([]string, 0, len(secret.Data))
	for id := range secret.Data {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if subtle.ConstantTimeCompare(secret.Data[id], []byte(presented)) == 1 {
			return id, ""
		}
	}
	return "", "key not issued to this partner"
}

func (a *authorizer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	clientID, reason := a.decide(r.Host, r.Header.Get(a.cfg.keyHeader))
	if clientID == "" {
		a.log.Info("deny", "host", r.Host, "partner", partnerFromHost(r.Host), "path", r.URL.Path, "reason", reason)
		w.Header().Set("WWW-Authenticate", `ApiKey realm="partner-api"`)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		fmt.Fprint(w, `{"error":"unauthorized"}`)
		return
	}
	a.log.Info("allow", "host", r.Host, "partner", partnerFromHost(r.Host), "path", r.URL.Path, "client", clientID)
	w.Header().Set(a.cfg.partnerIDHeader, clientID)
	w.WriteHeader(http.StatusOK)
}

func kubeClient(kubeconfig string) (kubernetes.Interface, error) {
	restCfg, err := rest.InClusterConfig()
	if errors.Is(err, rest.ErrNotInCluster) {
		restCfg, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
	}
	if err != nil {
		return nil, err
	}
	return kubernetes.NewForConfig(restCfg)
}

func main() {
	var cfg config
	flag.StringVar(&cfg.listen, "listen", ":8080", "address for the ext_authz check endpoint")
	flag.StringVar(&cfg.probeListen, "probe-listen", ":8081", "address for /healthz and /readyz (both mean: serving)")
	flag.StringVar(&cfg.secretsNS, "secrets-namespace", "partner-api", "namespace holding the partner key Secrets")
	flag.StringVar(&cfg.secretSuffix, "secret-suffix", "-keys", "Secret name is <partner><suffix>")
	flag.StringVar(&cfg.keyHeader, "key-header", "x-api-key", "request header carrying the key")
	flag.StringVar(&cfg.partnerIDHeader, "partner-id-header", "x-partner-id", "response header naming the matched client id")
	flag.StringVar(&cfg.kubeconfig, "kubeconfig", os.Getenv("KUBECONFIG"), "kubeconfig when not running in-cluster")
	flag.Parse()

	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	client, err := kubeClient(cfg.kubeconfig)
	if err != nil {
		log.Error("kubernetes client", "err", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// A watch rather than a volume mount: the Secrets live in another namespace,
	// and a rotation must take effect without a restart.
	factory := informers.NewSharedInformerFactoryWithOptions(client, 0, informers.WithNamespace(cfg.secretsNS))
	secrets := factory.Core().V1().Secrets()
	informer := secrets.Informer()
	factory.Start(ctx.Done())
	lister := secrets.Lister().Secrets(cfg.secretsNS)

	authz := &authorizer{cfg: cfg, log: log, secret: func(name string) (*corev1.Secret, error) {
		return lister.Get(name)
	}}

	probes := http.NewServeMux()
	probes.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	// Readiness does not wait for the Secret watch. The grant to read the
	// partner Secrets is stamped by the teams ResourceSet, which itself waits
	// for this Deployment to be Ready; until the watch syncs every key is a
	// 401 and the reflector logs the forbidden list on each retry.
	probes.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	checkSrv := &http.Server{Addr: cfg.listen, Handler: authz, ReadHeaderTimeout: 5 * time.Second}
	probeSrv := &http.Server{Addr: cfg.probeListen, Handler: probes, ReadHeaderTimeout: 5 * time.Second}

	go func() {
		if err := probeSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("probe server", "err", err)
			os.Exit(1)
		}
	}()
	go func() {
		if err := checkSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("check server", "err", err)
			os.Exit(1)
		}
	}()

	log.Info("serving", "listen", cfg.listen, "secrets", cfg.secretsNS, "suffix", cfg.secretSuffix)
	go func() {
		if cache.WaitForCacheSync(ctx.Done(), informer.HasSynced) {
			log.Info("secret watch synced", "namespace", cfg.secretsNS)
		}
	}()

	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = checkSrv.Shutdown(shutdown)
	_ = probeSrv.Shutdown(shutdown)
}
