#!/usr/bin/env bash
# Rotate the iPhone's carrier (CGNAT) public IP by cycling airplane mode.
#
# Asks the iOS app (GET /__rotate) to run the "Rotate IP" Shortcut
# (Airplane ON → Wait 61 s → Airplane OFF), then waits for the proxy to come
# back and reports whether the public IP actually changed.
#
# Usage: macos/rotate-ip.sh [phone-host[:port]]     (default 100.71.146.11:8888)
# Exit:  0 new IP · 2 same IP · 3 request refused · 4 phone never came back
set -uo pipefail

PHONE="${1:-100.71.146.11:8888}"
PROXY="http://$PHONE"
BACK_TIMEOUT=300   # seconds to wait for the phone after the rotate request

ip_via_proxy() { curl -s -m 6 -x "$PROXY" https://api.ipify.org || true; }
ts() { date +%H:%M:%S; }

old=$(ip_via_proxy)
[ -n "$old" ] || { echo "$(ts) phone/proxy not reachable at $PROXY" >&2; exit 4; }
echo "$(ts) current public IP: $old"

resp=$(curl -s -m 10 -w '\n%{http_code}' "$PROXY/__rotate")
code=${resp##*$'\n'}
body=${resp%$'\n'*}
if [ "$code" != "202" ]; then
  echo "$(ts) rotate refused (HTTP $code): $body" >&2
  exit 3
fi
echo "$(ts) rotate started — waiting for the phone to drop and come back"

start=$SECONDS
dropped=0
while [ $((SECONDS - start)) -lt $BACK_TIMEOUT ]; do
  sleep 3
  ip=$(ip_via_proxy)
  if [ -z "$ip" ]; then
    [ $dropped -eq 0 ] && echo "$(ts) phone offline (airplane mode)"
    dropped=1
  elif [ $dropped -eq 1 ]; then
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
