#!/usr/bin/env bash
# Rotate the iPhone's carrier (CGNAT) public IP by cycling airplane mode.
#
# Two triggers for the user-made "Rotate IP" Shortcut
# (Airplane ON → Wait 91 s → Airplane OFF):
#
#   default     GET /__rotate over the tailnet; the app opens Shortcuts by URL.
#               Needs the app in the foreground; blocked by Guided Access and
#               unavailable in Assistive Access (Shortcuts can't be added there).
#   --imessage  Sends a signed "MPP-ROTATE v1 <ts> <nonce> <hmac>" iMessage. A
#               Shortcuts automation (Message contains MPP-ROTATE → Verify
#               Rotate Command → If true → Rotate IP) runs it, also inside
#               Assistive Access. If the phone has not dropped ~60 s after a
#               send, the app's /__log tells why: no "Verify Rotate Command" run
#               → resend with a fresh nonce (up to 3 sends); rejected → stop;
#               accepted → the stall is in the shortcut chain, keep waiting.
#
# Then waits for the proxy to drop and come back, and reports whether the
# public IP actually changed.
#
# Usage:
#   macos/rotate-ip.sh [--phone host:port]                      # URL trigger
#   macos/rotate-ip.sh --imessage <handle> [--phone host:port]  # signed iMessage
#   macos/rotate-ip.sh --pair [--phone host:port]               # fetch HMAC secret
#                                                                 (tap "Pair Mac" first)
#   macos/rotate-ip.sh --sign                                   # print a signed command
# <handle> is the phone's iMessage address (email or +385…); MPP_IMESSAGE_TO also works.
# Exit: 0 new IP · 2 same IP · 3 request refused · 4 phone never dropped/returned
set -uo pipefail

PHONE="100.71.146.11:8888"
MODE=url
TO="${MPP_IMESSAGE_TO:-}"
BACK_TIMEOUT=300          # seconds to wait for the phone after triggering
RESEND_AFTER=60           # --imessage: seconds without a drop before checking /__log
MAX_SENDS=3
KC_SERVICE="mobile-phone-proxy-rotate"

while [ $# -gt 0 ]; do
  case "$1" in
    --phone)    PHONE="$2"; shift 2 ;;
    --imessage) MODE=imessage; TO="${2:-$TO}"; shift 2 ;;
    --pair)     MODE=pair; shift ;;
    --sign)     MODE=sign; shift ;;
    -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
    *)          PHONE="$1"; shift ;;   # backwards compatible positional host:port
  esac
done
PROXY="http://$PHONE"

ip_via_proxy() { curl -s -m 6 -x "$PROXY" https://api.ipify.org || true; }
ts() { date +%H:%M:%S; }

sends=0
sent_at=0
send_imessage() {
  local cmd
  cmd=$(sign_command) || return 1
  osascript - "$TO" "$cmd" <<'EOF' || { echo "$(ts) Messages failed to send" >&2; return 1; }
on run {recipient, body}
  tell application "Messages"
    send body to participant recipient of (1st account whose service type = iMessage)
  end tell
end run
EOF
  sends=$((sends + 1))
  sent_at=$(date +%s)
}

# What the App Intent did with commands since the last send, from the app's
# persistent log: "none", "accepted", or "rejected: <why>". "unknown" if the
# app (build >= 3) can't be asked.
intent_outcome() {
  curl -s -m 6 "$PROXY/__log" | python3 -c '
import json, sys
from datetime import datetime
since = int(sys.argv[1]) - 30   # allow for phone/Mac clock skew
try:
    ev = json.load(sys.stdin)["intentEvents"]
except Exception:
    print("unknown"); sys.exit()
out = "none"
for e in ev:
    at = datetime.fromisoformat(e["at"].replace("Z", "+00:00")).timestamp()
    if at < since or e["event"] == "invoked":
        continue
    out = e["event"]
    if out == "accepted":
        break
print(out)' "$sent_at"
}

secret_b64() { security find-generic-password -s "$KC_SERVICE" -a default -w 2>/dev/null; }

sign_command() {
  local b64 hexkey t nonce sig
  b64=$(secret_b64) || { echo "not paired — run: $0 --pair" >&2; return 1; }
  hexkey=$(printf '%s' "$b64" | base64 -D | xxd -p -c 256)
  t=$(date +%s)
  nonce=$(openssl rand -hex 8)
  sig=$(printf 'MPP-ROTATE|v1|%s|%s' "$t" "$nonce" |
        openssl dgst -sha256 -mac HMAC -macopt "hexkey:$hexkey" | awk '{print $NF}')
  printf 'MPP-ROTATE v1 %s %s %s' "$t" "$nonce" "$sig"
}

case "$MODE" in
  pair)
    resp=$(curl -s -m 10 -w '\n%{http_code}' "$PROXY/__pair")
    code=${resp##*$'\n'}; body=${resp%$'\n'*}
    [ "$code" = "200" ] || { echo "pairing refused (HTTP $code): $body" >&2; exit 3; }
    secret=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])')
    security add-generic-password -U -s "$KC_SERVICE" -a default -w "$secret" \
      -j "HMAC secret for signed MPP-ROTATE iMessages to the iPhone proxy app"
    echo "paired — secret stored in the login keychain (service $KC_SERVICE)"
    exit 0 ;;
  sign)
    sign_command && echo; exit $? ;;
esac

old=$(ip_via_proxy)
[ -n "$old" ] || { echo "$(ts) phone/proxy not reachable at $PROXY" >&2; exit 4; }
echo "$(ts) current public IP: $old"

if [ "$MODE" = imessage ]; then
  [ -n "$TO" ] || { echo "--imessage needs the phone's iMessage handle (or MPP_IMESSAGE_TO)" >&2; exit 3; }
  send_imessage || exit 3
  echo "$(ts) signed rotate command sent via iMessage — waiting for the phone to drop and come back"
else
  resp=$(curl -s -m 10 -w '\n%{http_code}' "$PROXY/__rotate")
  code=${resp##*$'\n'}; body=${resp%$'\n'*}
  if [ "$code" != "202" ]; then
    echo "$(ts) rotate refused (HTTP $code): $body" >&2
    exit 3
  fi
  echo "$(ts) rotate started — waiting for the phone to drop and come back"
fi

start=$SECONDS
dropped=0
misses=0
while [ $((SECONDS - start)) -lt $BACK_TIMEOUT ]; do
  sleep 3
  ip=$(ip_via_proxy)
  if [ -z "$ip" ]; then
    # One failed probe can be a transient DERP hiccup; require two in a row.
    misses=$((misses + 1))
    if [ $dropped -eq 0 ] && [ $misses -ge 2 ]; then
      echo "$(ts) phone offline (airplane mode)"
      dropped=1
    fi
  elif [ $dropped -eq 0 ]; then
    misses=0
    if [ "$MODE" = imessage ] && [ $(( $(date +%s) - sent_at )) -ge $RESEND_AFTER ]; then
      outcome=$(intent_outcome)
      case "$outcome" in
        accepted)
          echo "$(ts) phone accepted the command but has not dropped — the shortcut chain stalled (a prompt on screen?)" >&2
          RESEND_AFTER=$BACK_TIMEOUT ;;   # don't ask again; just wait it out
        rejected*)
          echo "$(ts) phone $outcome" >&2; exit 3 ;;
        *)
          if [ $sends -lt $MAX_SENDS ]; then
            echo "$(ts) no Verify Rotate Command run on the phone ($outcome) — resending ($((sends + 1))/$MAX_SENDS)"
            send_imessage || exit 3
          else
            RESEND_AFTER=$BACK_TIMEOUT
          fi ;;
      esac
    fi
    # Still online. With the URL trigger, a cleared "rotating" flag means iOS
    # refused to open Shortcuts (e.g. Guided Access) — no point waiting.
    if [ "$MODE" = url ] && [ $((SECONDS - start)) -ge 10 ] &&
       curl -s -m 6 "$PROXY/__status" | grep -q '"rotating":false'; then
      echo "$(ts) rotation aborted on the phone (Shortcuts did not open — Guided Access on?)" >&2
      exit 3
    fi
  else
    echo "$(ts) back after $((SECONDS - start)) s: $old → $ip"
    if [ "$ip" != "$old" ]; then echo "NEW IP ✅"; exit 0; fi
    echo "SAME IP ❌"; exit 2
  fi
done
if [ $dropped -eq 0 ]; then
  echo "$(ts) phone never went offline — did the shortcut run? Check the app log." >&2
else
  echo "$(ts) phone did not come back within $BACK_TIMEOUT s — airplane mode may still be ON." >&2
fi
exit 4
