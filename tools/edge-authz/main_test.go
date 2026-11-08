package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	corev1 "k8s.io/api/core/v1"
)

func testAuthorizer() *authorizer {
	secrets := map[string]*corev1.Secret{
		"partner-a-keys": {Data: map[string][]byte{
			"partner-a-prod":    []byte("aaaa-prod"),
			"partner-a-staging": []byte("aaaa-staging"),
		}},
		"partner-b-keys": {Data: map[string][]byte{
			"partner-b-prod": []byte("bbbb-prod"),
		}},
	}
	return &authorizer{
		cfg: config{secretSuffix: "-keys", keyHeader: "x-api-key", partnerIDHeader: "x-partner-id"},
		log: slog.New(slog.DiscardHandler),
		secret: func(name string) (*corev1.Secret, error) {
			if s, ok := secrets[name]; ok {
				return s, nil
			}
			return nil, fmt.Errorf("secret %q not found", name)
		},
	}
}

func TestDecide(t *testing.T) {
	a := testAuthorizer()
	cases := []struct {
		name, host, key, wantID, wantReason string
	}{
		{"right key", "partner-a.partners.local-dev.test:9443", "aaaa-prod", "partner-a-prod", ""},
		{"second client id", "partner-a.partners.local-dev.test", "aaaa-staging", "partner-a-staging", ""},
		{"missing header", "partner-a.partners.local-dev.test:9443", "", "", "no key presented"},
		{"wrong key", "partner-a.partners.local-dev.test:9443", "0000", "", "key not issued to this partner"},
		{"other partner's key", "partner-b.partners.local-dev.test:9443", "aaaa-prod", "", "key not issued to this partner"},
		{"unknown partner", "partner-z.partners.local-dev.test:9443", "aaaa-prod", "", "no key secret for partner"},
		{"wildcard host", "*.partners.local-dev.test", "aaaa-prod", "", "no partner label in host"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			id, reason := a.decide(c.host, c.key)
			if id != c.wantID || reason != c.wantReason {
				t.Fatalf("decide(%q, %q) = (%q, %q), want (%q, %q)", c.host, c.key, id, reason, c.wantID, c.wantReason)
			}
		})
	}
}

func TestServeHTTP(t *testing.T) {
	a := testAuthorizer()

	req := httptest.NewRequest(http.MethodGet, "/v1/orders/api/info", nil)
	req.Host = "partner-a.partners.local-dev.test:9443"
	req.Header.Set("x-api-key", "aaaa-prod")
	rec := httptest.NewRecorder()
	a.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Header().Get("x-partner-id") != "partner-a-prod" {
		t.Fatalf("allow: got %d %q", rec.Code, rec.Header().Get("x-partner-id"))
	}

	req = httptest.NewRequest(http.MethodGet, "/v1/orders/api/info", nil)
	req.Host = "partner-a.partners.local-dev.test:9443"
	rec = httptest.NewRecorder()
	a.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized || rec.Header().Get("WWW-Authenticate") == "" || rec.Header().Get("x-partner-id") != "" {
		t.Fatalf("deny: got %d, www-authenticate=%q, x-partner-id=%q", rec.Code, rec.Header().Get("WWW-Authenticate"), rec.Header().Get("x-partner-id"))
	}
}
