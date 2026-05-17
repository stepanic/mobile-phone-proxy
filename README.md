# Mobile Phone Proxy

Turn your phone into an HTTP CONNECT proxy that routes traffic out over its
**cellular** interface, while exposing the listener on **WiFi**. Point your
laptop at `http://<phone-wifi-ip>:8888` and every request egresses through
the carrier instead of your home network.

Native apps for **iOS** (Swift / Network.framework) and **Android**
(Kotlin / `java.net.Socket` bound to the cellular `Network`). No third-party
dependencies, no servers, no VPN profile.

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
  even though the listener lives on WiFi.
- **Android** — query `ConnectivityManager` for a `Network` with
  `TRANSPORT_CELLULAR + NET_CAPABILITY_INTERNET`, then call
  `network.bindSocket(socket)` before `connect()`. Falls back gracefully if
  the device or ROM refuses to bind (rare, but it happens).

## Status

| Platform | State | Verified on |
| --- | --- | --- |
| Android | **Working end-to-end**, hardened over several iterations | Xiaomi 17 Ultra on AS205714 Telemach mobile |
| iOS     | First-pass port, never run on a real device | — |

The Android side has been iterated on against an actual device and real
mobile traffic — connection lifecycle, hop-by-hop header handling, and the
always-on-VPN `bindSocket` fallback all came out of fixing things that broke
in practice.

The iOS side is essentially a single-pass translation of the same protocol
into Swift/Network.framework. It builds, but the author has no paid Apple
Developer account and never installed it on a phone. Expect edge cases — at
minimum around `NWListener` background suspension, half-close behaviour, and
the cellular-binding path on simulator vs device — to be wrong until someone
exercises them. PRs from anyone with signing capability are very welcome.

## Repository layout

```
ios/        Swift sources, project.yml for XcodeGen
            – ProxyServer.swift          NWListener + NWConnection wiring
            – HTTPProxyHandler.swift     CONNECT + absolute-URI parser
            – NetworkInterface.swift     WiFi/cellular IP discovery
            – ContentView.swift          SwiftUI control panel

android/    Standard AGP project, Compose UI
            – ProxyService.kt            Foreground service, server socket
            – HttpProxyHandler.kt        Same protocol as the Swift version
            – NetworkInterfaces.kt       WiFi/cellular Network lookup
            – ui/ProxyScreen.kt          Material 3 control panel

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
to sign with your own team.

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

## Caveats

- iOS suspends arbitrary TCP listeners in the background. The app declares
  `UIBackgroundModes: processing` which buys you a grace period, but for
  long-lived sessions keep the screen on.
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
