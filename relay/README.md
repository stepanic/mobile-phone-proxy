# mpp-relay

Cloudflare Worker + Durable Object that lets any job, from anywhere, ask the
iPhone app to rotate its carrier IP. The app keeps a WebSocket to its Durable
Object and the relay hands it signed commands. The phone verifies the HMAC, so
the relay can't forge a rotation.

Deployed: `https://mpp-relay.d-o-m.workers.dev`. Background, measurements and a
sequence diagram (in Croatian): `../docs/2026-10-01-ios-ip-rotation.md`.

## API

| Method | Path | |
|---|---|---|
| `POST` | `/v1/phones/<id>/rotate` | body `{"command": "MPP-ROTATE v1 <ts> <nonce> <hmac>"}` → `202 {jobId, status, phoneConnected}`, `409` if a job is in flight, `400` malformed/expired |
| `GET` | `/v1/phones/<id>/jobs/<jobId>` | `queued → sent → accepted\|rejected → rotating → done\|failed`, with `oldIP`, `newIP`, `detail` |
| `GET` | `/v1/phones/<id>` | `connected`, `lastSeen`, `publicIP`, `lastJob` |
| `GET` (WS) | `/v1/phones/<id>/connect` | phone only, `Authorization: Bearer <token>` |

Commands are signed exactly like the iMessage path:
`hex(HMAC-SHA256(secret, "MPP-ROTATE|v1|<ts>|<nonce>"))`. See
`macos/rotate-ip.sh --sign` and `--relay`.

## Setup

```bash
npm install
npx wrangler deploy
# Phone token = HMAC(secret, "MPP-RELAY|v1|<phoneId>"); the app derives the same.
printf '{"iphone":"%s"}' "$(../macos/rotate-ip.sh --relay-token --phone-id iphone)" |
  npx wrangler secret put PHONE_TOKENS
```

The app reads the relay URL and phone ID from `MPPRelayURL` and
`MPP_RELAY_PHONE_ID` in `ios/project.yml`.

## Test

```bash
echo 'PHONE_TOKENS={"smoke":"test-token"}' > .dev.vars
npx wrangler dev --port 8787 &
npm test        # plays both the phone (WebSocket) and the caller
```
