# Mobile Phone Proxy

Turn your phone into an HTTP CONNECT proxy that routes traffic out over its
**cellular** interface, while exposing the listener on **WiFi**. Point your
laptop at `http://<phone-wifi-ip>:8888` and every request egresses through
the carrier instead of your home network.

Native apps for **iOS** (Swift / Network.framework) and **Android**
(Kotlin / `java.net.Socket` bound to the cellular `Network`), plus a
**Windows/desktop** build (Go, single static `.exe`) for the "parked node"
case. No third-party dependencies, no servers, no VPN profile.

## Why

- You're on a WiFi that blocks something your phone's data plan doesn't (and
  vice-versa).
- You want a quick way to test how a service behaves from a mobile carrier IP
  (geo, CGNAT, AS-based rate limiting, etc.) without tethering.
- You're traveling and the hotel WiFi is hostile; the phone's LTE/5G isn't.
- You want a small, auditable codebase that does exactly one thing — no
  account, no telemetry, no cloud.

## How it works

```
  ┌──────────┐   WiFi    ┌─────────────┐   Cellular   ┌──────────────┐
  │  laptop  │ ────────▶ │    phone    │ ──────────▶  │   internet   │
  │  curl -x │           │  (listener) │ (forced bind) │              │
  └──────────┘           └─────────────┘              └──────────────┘
```

1. A TCP listener binds to all interfaces on a chosen port (default `8888`).
2. For each accepted client, the proxy reads request headers up to
   `CRLF CRLF` (capped at 64 KiB).
3. `CONNECT host:port` → opens a raw TCP socket **bound to the cellular
   interface**, returns `200`, and full-duplex relays bytes with half-close
   on EOF.
4. Plain `GET/POST/...` with absolute-URI → same outbound binding, hop-by-hop
   headers stripped per RFC 9110 §7.6.1 (including any name the inbound
   `Connection` header lists).
5. DNS is resolved through the cellular network too, so DNS leakage doesn't
   defeat the point.

The trick on both platforms is forcing the outbound socket onto the cellular
interface even when WiFi is the system default route:

- **iOS** — `NWParameters.requiredInterfaceType = .cellular` on outbound
  `NWConnection`s. iOS routes the connection through the cellular PDP context
  even though the listener lives on WiFi. If the system denies the
  cellular-pinned socket (it can, by policy), the handler retries once on the
  default route and logs loudly — egress is then cellular **only if WiFi is
  off**, mirroring the Android fallback below.
- **Android** — query `ConnectivityManager` for a `Network` with
  `TRANSPORT_CELLULAR + NET_CAPABILITY_INTERNET`, then call
  `network.bindSocket(socket)` before `connect()`. Falls back gracefully if
  the device or ROM refuses to bind (rare, but it happens).

## Status

| Platform | State | Verified on |
| --- | --- | --- |
| Android | **Working end-to-end**, hardened over several iterations | Xiaomi 17 Ultra on AS205714 Telemach mobile |
| iOS     | **Working end-to-end** on a physical device | iPhone 15 Pro (iOS 26.4.2) on Telemach mobile, remote over Tailscale |
| Windows | **Working** — protocol smoke-tested, cross-compiles to a static `.exe` | macOS-built `proxy.exe` (PE32+), relay verified on the build host |

The Android side has been iterated on against an actual device and real
mobile traffic — connection lifecycle, hop-by-hop header handling, and the
always-on-VPN `bindSocket` fallback all came out of fixing things that broke
in practice.

The iOS side started as a single-pass translation of the same protocol into
Swift/Network.framework and has now been validated on real hardware: built and
installed on a physical iPhone, reached remotely over Tailscale with the
phone's WiFi off. A direct request from the laptop exited via the home fiber
IP; the same request through the phone exited via a different mobile-carrier IP
in a different city — confirming true cellular egress, the same result the
Android port produces. The remaining real limitation is background execution
(see Caveats): iOS suspends a plain-app `NWListener`, so the phone runs as a
foreground "parked node" rather than a pocketed daemon.

## Repository layout

```
ios/        Swift sources, project.yml for XcodeGen
            – ProxyServer.swift          NWListener + NWConnection wiring
            – HTTPProxyHandler.swift     CONNECT + absolute-URI parser
            – NetworkInterface.swift     WiFi/cellular/Tailscale IP discovery
            – ContentView.swift          SwiftUI control panel

android/    Standard AGP project, Compose UI
            – ProxyService.kt            Foreground service, server socket
            – HttpProxyHandler.kt        Same protocol as the Swift version
            – NetworkInterfaces.kt       WiFi/cellular Network lookup
            – ui/ProxyScreen.kt          Material 3 control panel

windows/    Go source for the desktop build (no cgo, single static .exe)
            – proxy.go                   Same protocol as the mobile handlers
            – build.sh                   Cross-compile from macOS/Linux
            – README.md                  Build + run instructions

macos/      test_proxy.sh — quick smoke test from your laptop
```

## Build

### iOS

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd ios
xcodegen generate         # produces MobilePhoneProxy.xcodeproj
open MobilePhoneProxy.xcodeproj
```

Fill in `DEVELOPMENT_TEAM` in `project.yml` before regenerating if you want
to sign with your own team — or pass it on the command line. To build, install
and launch on a connected device straight from the CLI:

```bash
DEV_UDID=$(xcrun xctrace list devices 2>&1 | awk '/\(/{print $NF}' | tr -d '()' | head -1)
xcodebuild -project MobilePhoneProxy.xcodeproj -scheme MobilePhoneProxy \
  -destination "id=$DEV_UDID" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_STYLE=Automatic build
APP=$(xcodebuild -project MobilePhoneProxy.xcodeproj -scheme MobilePhoneProxy -showBuildSettings 2>/dev/null | awk -F' = ' '/ CODESIGNING_FOLDER_PATH/{print $2}')
xcrun devicectl device install app --device "$DEV_UDID" "$APP"
xcrun devicectl device process launch --device "$DEV_UDID" com.stepanic.mobilephoneproxy
```

A new device must be registered in your team once (Xcode → Signing &
Capabilities → select the device → *Register Device*); the CLI won't auto-add
it. On hardware the proxy does **not** auto-start — tap **Start proxy** and
grant the local-network permission prompt.

### Android

Requires Android Studio Ladybug (AGP 8.7+) or newer, JDK 17.

```bash
cd android
cp local.properties.example local.properties      # then point sdk.dir at your SDK
./gradlew :app:assembleDebug
./gradlew :app:installDebug        # if a device is connected via adb
```

The app then needs WiFi (for the listener) **and** mobile data (for egress)
active simultaneously. On modern Android you also need to grant the
notification permission so the foreground service can stay alive.

### Windows / desktop

Requires Go 1.21+ **only on the build host** — the produced `.exe` needs
nothing on the target machine. No Windows build machine is needed; Go
cross-compiles a fully static native binary:

```bash
cd windows
./build.sh                 # -> dist/proxy.exe (windows/amd64)
# == GOOS=windows GOARCH=amd64 go build -o dist/proxy.exe ./
```

Copy `proxy.exe` to the Windows box and double-click it (or `.\proxy.exe -port
9000 -verbose`). Unlike the phones there's no cellular interface to pin to, so
egress follows the system default route — ideal as a Tailscale-reachable
"parked node". See [`windows/README.md`](windows/README.md) for flags and the
optional `-bind <source-ip>` for multi-interface machines.

## Use

1. Launch the app, hit **Start proxy**.
2. The screen shows the listener URL — e.g. `http://192.168.1.42:8888`.
3. On your laptop:

```bash
export https_proxy=http://192.168.1.42:8888
export http_proxy=http://192.168.1.42:8888
curl https://ifconfig.me/ip      # should print your carrier IP, not your home IP
```

Or run the included smoke test:

```bash
./macos/test_proxy.sh 192.168.1.42 8888
```

### Remote (phone not on your WiFi)

Put both devices on a [Tailscale](https://tailscale.com) tailnet — no code
change, the listener already binds all interfaces (including `utun*`). Then:

1. Keep Tailscale on the phone, and **turn the phone's WiFi off** so cellular
   becomes its default route (otherwise iOS/Android egress over WiFi even with
   the cellular binding requested).
2. Point the laptop at the phone's **tailnet** IP — the app shows it as the
   *Tailscale IP* (iOS) — e.g. `curl -x http://100.x.y.z:8888 https://ifconfig.me/ip`.

The phone egresses over cellular; the Mac reaches it over the tailnet. Note
that with WiFi off Tailscale falls back to a DERP relay (CGNAT blocks direct
hole-punching), so throughput is fine for scraping but not low-latency work.

## Caveats

- iOS suspends arbitrary TCP listeners in the background (~15 min observed),
  and there is no foreground-service equivalent like Android's. The app
  declares `UIBackgroundModes: processing` and keeps the screen awake
  (`isIdleTimerDisabled`), but the supported model is a **foreground "parked
  node"**: app open, screen on, on a charger. A pocketed/locked phone will
  stop serving. (A Tailscale exit node would be the no-app alternative, but
  iOS cannot *advertise* as an exit node — it can only use one.)
- Android's foreground-service rules around `dataSync` are strict — the
  service is fine as long as the user-initiated start path is followed.
- On always-on VPNs (Tailscale, Mullvad, etc.) `bindSocket` may be refused
  by the kernel. The Android handler falls back to an unbound socket so the
  proxy keeps working; the egress interface then follows the system default
  route (usually the VPN). Decide accordingly.
- TLS payloads are tunneled raw via CONNECT — the proxy does not terminate
  TLS, does not see plaintext, and does not snoop. There's nothing to log.

## License

[MIT](./LICENSE).
