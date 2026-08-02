#!/usr/bin/env bash
#
# Prove the TURN relay actually allocates, before trusting it with a call.
#
# This matters because every failure mode downstream is silent: the client is designed to
# fall back to STUN when TURN is unavailable, so a broken relay looks exactly like a
# working one until two peers behind symmetric NAT try to talk and simply never connect.
#
# Mints a credential the same way functions/turn.js does, then asks the relay for an
# allocation over UDP, TCP and TLS.
#
# Usage:
#   TURN_SECRET_FILE=/path/to/secret TURN_HOST=1-2-3-4.sslip.io ./scripts/verify-turn-relay.sh

set -euo pipefail

: "${TURN_HOST:?set TURN_HOST to the relay hostname}"
: "${TURN_SECRET_FILE:?set TURN_SECRET_FILE to the file holding the shared secret}"

if ! command -v turnutils_uclient >/dev/null; then
  echo "turnutils_uclient not found. Install coturn's client tools:" >&2
  echo "  macOS:  brew install coturn" >&2
  echo "  Debian: apt-get install coturn" >&2
  exit 2
fi

SECRET="$(cat "${TURN_SECRET_FILE}")"
EXPIRY=$(( $(date +%s) + 600 ))
USERNAME="${EXPIRY}:smoketest"
# Identical construction to mintCredentials() in functions/turn.js.
CREDENTIAL="$(printf '%s' "$USERNAME" \
  | openssl dgst -sha1 -hmac "$SECRET" -binary | base64)"

echo "host=${TURN_HOST}  username=${USERNAME}"
echo

# macOS has no `timeout`; coreutils installs it as `gtimeout`. Fall back to running
# without one rather than reporting a false failure.
if command -v gtimeout >/dev/null; then TIMEOUT=(gtimeout 25)
elif command -v timeout >/dev/null; then TIMEOUT=(timeout 25)
else TIMEOUT=(); fi

fail=0
probe() {
  local label="$1"; shift
  echo "--- ${label} ---"
  local out
  # -y makes the two test clients relay to EACH OTHER, which is exactly the peer-to-peer
  # shape an Inditalk call uses; without it (or an -e peer) turnutils_uclient refuses to run.
  # ${a[@]+"${a[@]}"} — bash 3.2 (macOS) treats an empty array as unbound under `set -u`.
  out="$(${TIMEOUT[@]+"${TIMEOUT[@]}"} turnutils_uclient -u "$USERNAME" -w "$CREDENTIAL" \
         -y -n 2 "$@" "$TURN_HOST" 2>&1)" || true
  echo "$out" | tail -12
  # turnutils_uclient reports each completed round trip; "success" appears only after the
  # relay has allocated and echoed traffic back.
  if echo "$out" | grep -qiE 'success|total transmit time'; then
    echo "    OK"
  else
    echo "    FAILED"
    fail=1
  fi
  echo
}

probe "UDP  3478"        -p 3478
probe "TCP  3478"    -t  -p 3478
probe "TLS  5349"    -T  -p 5349

if [[ $fail -eq 0 ]]; then
  echo "All three transports allocated. The relay is operational."
else
  echo "At least one transport failed — check the firewall rules, the certificate," >&2
  echo "and that coturn's static-auth-secret matches TURN_SECRET byte-for-byte." >&2
  exit 1
fi
