#!/usr/bin/env bash
#
# Provision Inditalk's TURN relay: one coturn host on GCP Compute Engine.
#
# Idempotent — every step is "create, or accept that it already exists" — so it is safe
# to re-run after a partial failure.
#
# Why a relay at all: STUN only tells each peer its own public address. When BOTH peers
# sit behind symmetric NAT (most cellular carriers, plenty of corporate Wi-Fi) neither
# can reach the other directly and the call never connects. TURN relays the media
# instead. That is the difference between "calls work on my Wi-Fi" and "calls work".
#
# Hostname: no domain is registered for this project, so we use sslip.io, which resolves
# <dashed-ip>.sslip.io -> <ip>. That gives Let's Encrypt a real name to issue a cert for,
# which `turns:` on 5349 requires — and `turns:` is what gets through networks that only
# permit HTTPS-looking traffic, i.e. exactly the networks that need a relay.
#
# Usage:
#   TURN_SECRET_FILE=/path/to/secret ./scripts/provision-turn.sh
#
# The secret file must contain the shared secret with NO trailing newline: coturn's
# static-auth-secret is compared byte-for-byte against what the Cloud Function HMACs with.

set -euo pipefail

PROJECT="${PROJECT:-cove-7f31f}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
VM="${VM:-cove-turn}"
ADDR="${ADDR:-cove-turn-ip}"
TAG="cove-turn"
# e2-small rather than e2-micro: a relayed video call is a steady bidirectional stream and
# e2-micro's shared core is throttled hard enough to show up as jitter.
MACHINE="${MACHINE:-e2-small}"

if [[ -z "${TURN_SECRET_FILE:-}" || ! -f "${TURN_SECRET_FILE}" ]]; then
  echo "TURN_SECRET_FILE must point at a file containing the shared secret" >&2
  exit 2
fi
# $(...) strips trailing newlines, so this is empty exactly when the last byte is one.
if [[ -z "$(tail -c 1 "${TURN_SECRET_FILE}")" ]]; then
  echo "refusing: ${TURN_SECRET_FILE} ends with a newline." >&2
  echo "coturn would use the secret WITHOUT it and every credential would fail." >&2
  echo "fix with:  printf %s \"\$(cat file)\" > file" >&2
  exit 2
fi

echo "==> enabling APIs"
gcloud services enable compute.googleapis.com secretmanager.googleapis.com --project "$PROJECT"

echo "==> reserving static IP ${ADDR}"
gcloud compute addresses create "$ADDR" --region "$REGION" --project "$PROJECT" 2>/dev/null \
  || echo "    (already exists)"
IP="$(gcloud compute addresses describe "$ADDR" --region "$REGION" --project "$PROJECT" \
       --format='value(address)')"
HOST="${IP//./-}.sslip.io"
echo "    IP=${IP}  HOST=${HOST}"

echo "==> firewall rules"
# 3478 is TURN itself, 5349 is TURN over TLS, 80 is only for the Let's Encrypt HTTP-01
# challenge, and 49152-65535/udp is the relay range coturn allocates media ports from.
gcloud compute firewall-rules create cove-turn-allow \
  --project "$PROJECT" --network default --direction INGRESS --action ALLOW \
  --target-tags "$TAG" --source-ranges 0.0.0.0/0 \
  --rules tcp:80,tcp:3478,udp:3478,tcp:5349,udp:5349 2>/dev/null || echo "    (already exists)"

gcloud compute firewall-rules create cove-turn-allow-relay \
  --project "$PROJECT" --network default --direction INGRESS --action ALLOW \
  --target-tags "$TAG" --source-ranges 0.0.0.0/0 \
  --rules udp:49152-65535 2>/dev/null || echo "    (already exists)"

echo "==> writing startup script"
STARTUP="$(mktemp)"
trap 'rm -f "$STARTUP"' EXIT
cat >"$STARTUP" <<'STARTUP_EOF'
#!/usr/bin/env bash
set -euxo pipefail
exec >>/var/log/cove-turn-setup.log 2>&1

HOST="$(curl -s -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/turn-host)"
PUBLIC_IP="$(curl -s -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)"
PRIVATE_IP="$(curl -s -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y coturn certbot

# The secret is pulled from Secret Manager at boot using the VM's own service account.
# It is deliberately NOT passed through instance metadata: metadata is readable by anyone
# with compute.instances.get on the project, which is a much wider audience than the
# secretAccessor role.
TOKEN="$(curl -s -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')"
SECRET="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "https://secretmanager.googleapis.com/v1/projects/cove-7f31f/secrets/TURN_SECRET/versions/latest:access" \
  | python3 -c 'import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)["payload"]["data"]).decode(), end="")')"

# Let's Encrypt needs port 80 free; coturn is not listening yet on first boot, but on a
# re-run it might be, so stop it first.
systemctl stop coturn || true
certbot certonly --standalone --non-interactive --agree-tos \
  --register-unsafely-without-email -d "${HOST}" || true

install -d -m 0755 /etc/coturn
cat >/etc/turnserver.conf <<EOF
listening-port=3478
tls-listening-port=5349
realm=${HOST}

# The REST scheme the Cloud Function mints against: coturn recomputes
# base64(HMAC-SHA1(static-auth-secret, "<expiry>:<uid>")) and compares. No user database.
use-auth-secret
static-auth-secret=${SECRET}

# GCE gives the VM a private address and NATs it; coturn must advertise the PUBLIC one or
# it hands out candidates no peer on the internet can reach.
listening-ip=${PRIVATE_IP}
external-ip=${PUBLIC_IP}/${PRIVATE_IP}

cert=/etc/letsencrypt/live/${HOST}/fullchain.pem
pkey=/etc/letsencrypt/live/${HOST}/privkey.pem

fingerprint
no-multicast-peers
# Relay only the port range the firewall opens.
min-port=49152
max-port=65535

# Refuse to relay to loopback/link-local/RFC1918: without this the relay can be used to
# probe the internal network it sits in.
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff

no-cli
syslog
EOF
# The config holds static-auth-secret, so it must not be world-readable — but coturn
# drops to the `turnserver` user, and a root-only 0600 file is one it cannot read. coturn
# then falls back to package defaults WITHOUT any error: it auto-discovers listeners,
# starts no TLS listener, and ignores the shared secret entirely. 0640 root:turnserver is
# the only combination that is both private and actually loaded.
chown root:turnserver /etc/turnserver.conf
chmod 0640 /etc/turnserver.conf

# Ubuntu ships coturn disabled behind this flag.
sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn || \
  echo 'TURNSERVER_ENABLED=1' >>/etc/default/coturn

# coturn runs as the unprivileged `turnserver` user, but certbot creates
# /etc/letsencrypt/{live,archive} as root-only (0700). Without this, coturn cannot read
# the key and SILENTLY starts with no TLS listener at all: 3478 works, 5349 is simply
# absent, and the only symptom is that calls fail on the restrictive networks that need
# turns: most. Grant group access rather than loosening to world-readable.
getent group ssl-cert >/dev/null || groupadd --system ssl-cert
usermod -aG ssl-cert turnserver
chgrp -R ssl-cert /etc/letsencrypt/live /etc/letsencrypt/archive
chmod 0750 /etc/letsencrypt/live /etc/letsencrypt/archive
find /etc/letsencrypt/archive -name 'privkey*.pem' -exec chmod 0640 {} +

# Renewal must BOTH re-apply those permissions (certbot writes each new privkeyN.pem as
# root-only again) and reload coturn — otherwise TLS dies silently 90 days from now.
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/reload-coturn.sh <<'HOOK'
#!/bin/sh
set -e
chgrp -R ssl-cert /etc/letsencrypt/live /etc/letsencrypt/archive
chmod 0750 /etc/letsencrypt/live /etc/letsencrypt/archive
find /etc/letsencrypt/archive -name 'privkey*.pem' -exec chmod 0640 {} +
systemctl restart coturn
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-coturn.sh

systemctl enable coturn
systemctl restart coturn
echo "cove-turn setup complete for ${HOST}"
STARTUP_EOF

echo "==> creating VM ${VM}"
gcloud compute instances create "$VM" \
  --project "$PROJECT" --zone "$ZONE" --machine-type "$MACHINE" \
  --image-family ubuntu-2204-lts --image-project ubuntu-os-cloud \
  --boot-disk-size 20GB --tags "$TAG" \
  --address "$IP" \
  --scopes https://www.googleapis.com/auth/cloud-platform \
  --metadata turn-host="$HOST" \
  --metadata-from-file startup-script="$STARTUP" 2>/dev/null \
  || echo "    (already exists — delete it to re-provision)"

SA="$(gcloud compute instances describe "$VM" --zone "$ZONE" --project "$PROJECT" \
      --format='value(serviceAccounts[0].email)')"
echo "==> granting ${SA} read access to TURN_SECRET"
gcloud secrets add-iam-policy-binding TURN_SECRET --project "$PROJECT" \
  --member "serviceAccount:${SA}" --role roles/secretmanager.secretAccessor >/dev/null

cat <<EOF

Provisioned. coturn installs on first boot; give it ~3 minutes, then:

  gcloud compute ssh ${VM} --zone ${ZONE} --project ${PROJECT} \\
    --command 'sudo tail -40 /var/log/cove-turn-setup.log; systemctl is-active coturn'

Then set this in functions/.env and redeploy:

TURN_URLS=turn:${HOST}:3478?transport=udp,turn:${HOST}:3478?transport=tcp,turns:${HOST}:5349?transport=tcp

  firebase deploy --project ${PROJECT} --only functions:getTurnCredentials

Verify the relay actually allocates (see scripts/verify-turn-relay.sh).
EOF
