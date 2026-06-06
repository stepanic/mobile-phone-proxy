// Command proxy is the Windows (and any-desktop) port of MobilePhoneProxy.
//
// It mirrors the protocol of android/HttpProxyHandler.kt and
// ios/HTTPProxyHandler.swift:
//   - A TCP listener binds all interfaces on a chosen port (default 8888).
//   - Per client, request headers are read up to CRLF CRLF (capped 64 KiB).
//   - CONNECT host:port  -> raw TLS tunnel, returns 200, full-duplex relay.
//   - Plain GET/POST/... with absolute-URI -> origin-form forward, hop-by-hop
//     headers stripped per RFC 9110 7.6.1 (including any name the inbound
//     Connection header lists).
//   - Full-duplex byte relay with half-close on EOF.
//
// Unlike the phones there is no cellular interface to pin to: a desktop egress
// follows the system default route, which is exactly what the "parked node"
// (reach it over Tailscale, egress through that site's network) use-case wants.
// An optional -bind flag pins the outbound source IP for machines with more
// than one egress (e.g. a USB LTE modem or a second NIC).
//
// Pure standard library, no cgo -> a single static .exe that needs no runtime
// installed on the target. Cross-compile from any OS:
//
//	GOOS=windows GOARCH=amd64 go build -o proxy.exe
package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	headerLimit    = 64 * 1024
	connectTimeout = 15 * time.Second
	relayBufSize   = 32 * 1024
)

// version is stamped at build time via -ldflags "-X main.version=...".
var version = "dev"

var (
	verbose  bool
	dialer   net.Dialer
	connSeq  atomic.Int64
	liveConn atomic.Int64
)

func main() {
	port := flag.Int("port", 8888, "TCP port for the proxy listener")
	host := flag.String("host", "0.0.0.0", "listen address (0.0.0.0 = all interfaces)")
	bind := flag.String("bind", "", "optional outbound source IP to pin egress to a specific interface")
	flag.BoolVar(&verbose, "verbose", false, "log every request line")
	showVer := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVer {
		fmt.Printf("MobilePhoneProxy %s\n", version)
		return
	}

	dialer = net.Dialer{Timeout: connectTimeout}
	if *bind != "" {
		ip := net.ParseIP(*bind)
		if ip == nil {
			log.Fatalf("invalid -bind address: %q", *bind)
		}
		dialer.LocalAddr = &net.TCPAddr{IP: ip}
		log.Printf("pinning outbound egress to source IP %s", ip)
	}

	addr := net.JoinHostPort(*host, strconv.Itoa(*port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	log.Printf("MobilePhoneProxy %s listening on %s", version, addr)
	for _, ip := range listenURLs(*port) {
		log.Printf("  proxy URL: %s", ip)
	}

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept error: %v", err)
			continue
		}
		go handle(c)
	}
}

// listenURLs reports usable http://ip:port strings for every non-loopback
// IPv4 address, so the user can see which one to point a laptop at (including
// a Tailscale 100.x address if present).
func listenURLs(port int) []string {
	var out []string
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return out
	}
	for _, a := range addrs {
		ipn, ok := a.(*net.IPNet)
		if !ok || ipn.IP.IsLoopback() || ipn.IP.IsLinkLocalUnicast() {
			continue
		}
		ip4 := ipn.IP.To4()
		if ip4 == nil {
			continue
		}
		out = append(out, fmt.Sprintf("http://%s:%d", ip4, port))
	}
	return out
}

func handle(client net.Conn) {
	id := connSeq.Add(1)
	live := liveConn.Add(1)
	defer func() {
		client.Close()
		liveConn.Add(-1)
	}()
	if tc, ok := client.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}

	br := bufio.NewReaderSize(client, 8192)
	req, err := parseRequest(br)
	if err != nil {
		sendStatus(client, "400 Bad Request")
		if verbose {
			log.Printf("[%d] bad request: %v", id, err)
		}
		return
	}
	if verbose {
		log.Printf("[%d] (%d live) %s %s:%d", id, live, req.method, req.host, req.port)
	}

	upstream, err := dialer.Dial("tcp", net.JoinHostPort(req.host, strconv.Itoa(req.port)))
	if err != nil {
		sendStatus(client, "502 Bad Gateway")
		if verbose {
			log.Printf("[%d] upstream %s:%d failed: %v", id, req.host, req.port, err)
		}
		return
	}
	defer upstream.Close()
	if tc, ok := upstream.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}

	if req.isConnect {
		io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n"+
			"Proxy-Agent: MobilePhoneProxy\r\n\r\n")
	} else {
		if _, err := upstream.Write(req.rebuild()); err != nil {
			return
		}
		// Any body bytes already buffered after the headers must be forwarded.
		if n := br.Buffered(); n > 0 {
			io.CopyN(upstream, br, int64(n))
		}
	}

	relay(client, upstream, br)
}

// relay runs a full-duplex copy between client and upstream, half-closing each
// direction on EOF so the peer learns the stream ended. The client->upstream
// pump reads through br to drain any bytes already buffered during parsing.
func relay(client, upstream net.Conn, clientBuf io.Reader) {
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		io.Copy(upstream, clientBuf)
		halfClose(upstream)
	}()

	io.Copy(client, upstream)
	halfClose(client)
	wg.Wait()
}

// halfClose shuts down the write side of a TCP connection (sends FIN) without
// tearing down the read side, the desktop equivalent of shutdownOutput().
func halfClose(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		tc.CloseWrite()
	}
}

// -- request parsing --------------------------------------------------------

type request struct {
	method    string
	target    string
	version   string
	headers   []string // sanitized "Name: Value", hop-by-hop removed
	host      string
	port      int
	isConnect bool
}

func parseRequest(br *bufio.Reader) (*request, error) {
	var head bytes.Buffer
	for {
		b, err := br.ReadByte()
		if err != nil {
			return nil, err
		}
		head.WriteByte(b)
		if head.Len() > headerLimit {
			return nil, fmt.Errorf("headers exceed %d bytes", headerLimit)
		}
		if hb := head.Bytes(); len(hb) >= 4 &&
			hb[len(hb)-4] == '\r' && hb[len(hb)-3] == '\n' &&
			hb[len(hb)-2] == '\r' && hb[len(hb)-1] == '\n' {
			break
		}
	}
	// Drop the trailing CRLF CRLF before splitting into lines.
	text := head.String()
	text = strings.TrimSuffix(text, "\r\n\r\n")
	return parseHeaders(text)
}

func parseHeaders(text string) (*request, error) {
	lines := strings.Split(text, "\r\n")
	if len(lines) == 0 {
		return nil, fmt.Errorf("empty request")
	}
	parts := strings.SplitN(lines[0], " ", 3)
	if len(parts) != 3 {
		return nil, fmt.Errorf("malformed request line: %q", lines[0])
	}
	method, target, version := parts[0], parts[1], parts[2]

	hopByHop := map[string]bool{
		"proxy-connection": true, "proxy-authorization": true, "connection": true,
		"keep-alive": true, "transfer-encoding": true, "te": true,
		"trailer": true, "upgrade": true,
	}
	type kv struct{ name, value string }
	var raw []kv
	for _, line := range lines[1:] {
		if line == "" {
			continue
		}
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			continue
		}
		name := strings.TrimSpace(line[:colon])
		value := strings.TrimSpace(line[colon+1:])
		raw = append(raw, kv{name, value})
		if strings.EqualFold(name, "connection") {
			for _, t := range strings.Split(value, ",") {
				hopByHop[strings.ToLower(strings.TrimSpace(t))] = true
			}
		}
	}

	host, port := "", 80
	var sanitized []string
	for _, h := range raw {
		lower := strings.ToLower(h.name)
		if hopByHop[lower] {
			continue
		}
		if lower == "host" {
			host, port = splitHostPort(h.value, port)
		}
		sanitized = append(sanitized, h.name+": "+h.value)
	}

	isConnect := strings.EqualFold(method, "CONNECT")
	if isConnect {
		host, port = splitHostPort(target, 443)
	} else if uHost, uPort, ok := hostPortFromAbsoluteURI(target); ok {
		if host == "" {
			host = uHost
		}
		if uPort > 0 {
			port = uPort
		}
	}
	if host == "" {
		return nil, fmt.Errorf("no host in request")
	}
	return &request{method, target, version, sanitized, host, port, isConnect}, nil
}

func splitHostPort(s string, defaultPort int) (string, int) {
	if strings.HasPrefix(s, "[") { // bracketed IPv6 literal
		if end := strings.IndexByte(s, ']'); end > 0 {
			h := s[1:end]
			rest := s[end+1:]
			if strings.HasPrefix(rest, ":") {
				if p, err := strconv.Atoi(rest[1:]); err == nil {
					return h, p
				}
			}
			return h, defaultPort
		}
	}
	if colon := strings.LastIndexByte(s, ':'); colon >= 0 {
		if p, err := strconv.Atoi(s[colon+1:]); err == nil {
			return s[:colon], p
		}
	}
	return s, defaultPort
}

func hostPortFromAbsoluteURI(target string) (string, int, bool) {
	var scheme string
	switch {
	case strings.HasPrefix(strings.ToLower(target), "http://"):
		scheme = "http"
	case strings.HasPrefix(strings.ToLower(target), "https://"):
		scheme = "https"
	default:
		return "", 0, false
	}
	rest := target[len(scheme)+3:] // skip "://"
	slash := strings.IndexByte(rest, '/')
	if slash < 0 {
		slash = len(rest)
	}
	defPort := 80
	if scheme == "https" {
		defPort = 443
	}
	h, p := splitHostPort(rest[:slash], defPort)
	return h, p, true
}

// rebuild produces the origin-form request to send upstream: absolute-URI
// rewritten to its path, hop-by-hop headers already removed, a Host header
// synthesized if missing, and Connection: close appended.
func (r *request) rebuild() []byte {
	path := r.target
	if l := strings.ToLower(path); strings.HasPrefix(l, "http://") || strings.HasPrefix(l, "https://") {
		rest := path[strings.Index(path, "://")+3:]
		if slash := strings.IndexByte(rest, '/'); slash < 0 {
			path = "/"
		} else {
			path = rest[slash:]
		}
	}
	var sb strings.Builder
	sb.WriteString(r.method + " " + path + " " + r.version + "\r\n")
	hasHost := false
	for _, h := range r.headers {
		if strings.HasPrefix(strings.ToLower(h), "host:") {
			hasHost = true
		}
		sb.WriteString(h + "\r\n")
	}
	if !hasHost {
		hostHeader := r.host
		if r.port != 80 {
			hostHeader = fmt.Sprintf("%s:%d", r.host, r.port)
		}
		sb.WriteString("Host: " + hostHeader + "\r\n")
	}
	sb.WriteString("Connection: close\r\n\r\n")
	return []byte(sb.String())
}

func sendStatus(c net.Conn, status string) {
	io.WriteString(c, "HTTP/1.1 "+status+"\r\n"+
		"Proxy-Agent: MobilePhoneProxy\r\n"+
		"Connection: close\r\n"+
		"Content-Length: 0\r\n\r\n")
}
