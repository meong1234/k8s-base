// Command dexproxy is a loopback CONNECT proxy that stands in for an
// /etc/hosts entry.
//
// kubelogin resolves the Dex issuer hostname itself and has no --resolve
// equivalent, so on a laptop where /etc/hosts cannot be edited (that needs
// root) the login flow has nowhere to send the browser. Go's HTTP client does
// honour HTTPS_PROXY, so pointing it here supplies the one missing thing: a
// name-to-address decision. Every CONNECT is answered by dialling the k3d
// loadbalancer on loopback, which is exactly what `127.0.0.1 dex.local-dev.test`
// would have produced.
//
// With the /etc/hosts entry in place this proxy is unnecessary but harmless:
// the destination socket is the same either way.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"time"
)

const target = "127.0.0.1"

func main() {
	port := flag.Int("port", 18443, "loopback port to listen on")
	flag.Parse()
	// Positional form, so the make recipe can stay `dexproxy 18443`.
	if args := flag.Args(); len(args) == 1 {
		if _, err := fmt.Sscanf(args[0], "%d", port); err != nil {
			log.Fatalf("dexproxy: bad port %q: %v", args[0], err)
		}
	}

	addr := fmt.Sprintf("%s:%d", target, *port)
	srv := &http.Server{
		Addr:        addr,
		Handler:     http.HandlerFunc(handle),
		ReadTimeout: 0,
	}
	log.SetOutput(os.Stdout)
	log.Printf("dexproxy listening on %s, every CONNECT -> %s", addr, target)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("dexproxy: %v", err)
	}
}

func handle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodConnect {
		http.Error(w, "only CONNECT is proxied", http.StatusMethodNotAllowed)
		return
	}

	_, port, err := net.SplitHostPort(r.Host)
	if err != nil {
		port = "443"
	}
	upstream, err := net.DialTimeout("tcp", net.JoinHostPort(target, port), 10*time.Second)
	if err != nil {
		log.Printf("CONNECT %s -> %s:%s failed: %v", r.Host, target, port, err)
		http.Error(w, "bad gateway", http.StatusBadGateway)
		return
	}
	defer upstream.Close()

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "connection cannot be hijacked", http.StatusInternalServerError)
		return
	}
	client, buf, err := hijacker.Hijack()
	if err != nil {
		log.Printf("CONNECT %s: hijack failed: %v", r.Host, err)
		return
	}
	defer client.Close()

	if _, err := client.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n")); err != nil {
		return
	}
	// Anything the client pipelined behind the CONNECT is already buffered.
	if n := buf.Reader.Buffered(); n > 0 {
		if _, err := io.CopyN(upstream, buf, int64(n)); err != nil {
			return
		}
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = io.Copy(upstream, client)
		closeWrite(upstream)
	}()
	_, _ = io.Copy(client, upstream)
	closeWrite(client)
	<-done
}

func closeWrite(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.CloseWrite()
	}
}
