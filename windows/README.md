# Windows (desktop) proxy

The same HTTP CONNECT proxy as the iOS/Android apps, as a single self-contained
`.exe`. Pure Go standard library, no cgo, no dependencies — **the target Windows
machine needs nothing installed** (no Go, no runtime, no DLLs). It's native
machine code, not a script.

Protocol is a 1:1 port of [`android/.../HttpProxyHandler.kt`](../android/app/src/main/java/com/stepanic/mobilephoneproxy/HttpProxyHandler.kt):
read headers to `CRLF CRLF` (cap 64 KiB), `CONNECT` raw TLS tunnel, absolute-URI
forwarding with hop-by-hop stripping (RFC 9110 §7.6.1), full-duplex relay with
half-close.

## How it differs from the phones

A desktop has no cellular interface to pin to, so egress follows the system
default route. That is exactly what the **"parked node"** use-case wants: reach
the machine over Tailscale and egress through *that site's* network — the same
remote pattern as the parked iPhone, no app needed beyond this binary. For a
machine with more than one egress (a USB LTE modem, a second NIC) the optional
`-bind <source-ip>` flag pins the outbound source IP.

## Build (on macOS/Linux — no Windows machine required)

```bash
cd windows
./build.sh            # -> dist/proxy.exe   (windows/amd64, most PCs)
./build.sh arm64      # -> dist/proxy-arm64.exe (Windows on ARM)
```

`build.sh` is just `GOOS=windows GOARCH=amd64 go build`. Copy the resulting
`.exe` to the Windows box (USB, scp, Tailscale `taildrop`, whatever).

## Run (on Windows)

Double-click `proxy.exe`, or from `cmd` / PowerShell:

```powershell
.\proxy.exe                       # listens on 0.0.0.0:8888
.\proxy.exe -port 9000 -verbose   # custom port, log each request
.\proxy.exe -bind 10.20.0.5       # pin egress to a specific interface's IP
```

On first run Windows Defender Firewall will prompt to allow inbound
connections — allow it on the networks you need (Private, and/or the Tailscale
network). The console prints the URLs to point a client at, e.g.:

```
MobilePhoneProxy listening on 0.0.0.0:8888
  proxy URL: http://192.168.1.50:8888
  proxy URL: http://100.x.y.z:8888      <- Tailscale, for remote use
```

## Use (from the laptop)

```bash
curl -x http://<windows-ip>:8888 https://ifconfig.me/ip
# or the repo smoke test:
../macos/test_proxy.sh <windows-ip> 8888
```

## Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `-port` | `8888` | listener port |
| `-host` | `0.0.0.0` | listen address (all interfaces) |
| `-bind` | _(none)_ | pin outbound source IP to a specific interface |
| `-verbose` | `false` | log every request line + live connection count |

## Run from source instead of a binary

If you'd rather not ship a binary, on a Windows box with Go installed:

```powershell
cd windows
go run . -port 8888
```
