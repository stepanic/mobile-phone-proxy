#!/usr/bin/env bash
# Quick smoke test: confirm traffic goes out via the iPhone's cellular IP.
#
# Usage: ./test_proxy.sh <iphone-wifi-ip> [port]
#
# It hits ifconfig.me/ip directly (your WiFi IP) and then through the proxy
# (should be your cellular carrier's IP).

set -euo pipefail

IPHONE_IP="${1:-}"
PORT="${2:-8888}"

if [[ -z "$IPHONE_IP" ]]; then
  echo "usage: $0 <iphone-wifi-ip> [port]" >&2
  exit 1
fi

PROXY="http://${IPHONE_IP}:${PORT}"

echo "Direct (your WiFi/home IP):"
curl --max-time 10 -s https://ifconfig.me/ip
echo

echo "Through phone (${PROXY}) — should show your carrier IP:"
curl --max-time 30 -sx "$PROXY" https://ifconfig.me/ip
echo

echo "JSON details through phone:"
curl --max-time 30 -sx "$PROXY" https://ifconfig.co/json
echo
