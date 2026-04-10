#!/bin/bash
# Keycloak provisioning script — runs once after Keycloak is healthy.
# Idempotent: skips creation if realm/client/user already exist.
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="myrealm"
CLIENT_ID="myapp"
CLIENT_SECRET="dev-secret-change-me"

KCADM="/opt/keycloak/bin/kcadm.sh"

# ── 1. Authenticate ────────────────────────────────────────────────────────────
echo "==> Authenticating with Keycloak admin API at ${KEYCLOAK_URL}..."
MAX_RETRIES=20
ATTEMPT=0
until $KCADM config credentials \
    --server "${KEYCLOAK_URL}" \
    --realm master \
    --user "${ADMIN_USER}" \
    --password "${ADMIN_PASSWORD}" 2>/dev/null; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "${ATTEMPT}" -ge "${MAX_RETRIES}" ]; then
    echo "ERROR: Failed to authenticate after ${MAX_RETRIES} attempts."
    exit 1
  fi
  echo "    Waiting for admin API... (attempt ${ATTEMPT}/${MAX_RETRIES})"
  sleep 5
done
echo "==> Authenticated."

# ── 2. Realm ───────────────────────────────────────────────────────────────────
if $KCADM get realms/${REALM} &>/dev/null; then
  echo "==> Realm '${REALM}' already exists — skipping."
else
  echo "==> Creating realm '${REALM}'..."
  $KCADM create realms \
    -s realm="${REALM}" \
    -s enabled=true \
    -s displayName="My Company" \
    -s registrationAllowed=false
fi

# ── 3. SMTP (Mailpit) ──────────────────────────────────────────────────────────
echo "==> Configuring SMTP to use Mailpit..."
$KCADM update realms/${REALM} \
  -s smtpServer.host=mailpit \
  -s smtpServer.port=1025 \
  -s 'smtpServer.from=keycloak@example.local' \
  -s 'smtpServer.fromDisplayName=Keycloak' \
  -s smtpServer.auth=false \
  -s smtpServer.ssl=false \
  -s smtpServer.starttls=false

# ── 4. Client ──────────────────────────────────────────────────────────────────
EXISTING_CLIENT=$($KCADM get clients -r "${REALM}" -q "clientId=${CLIENT_ID}" --fields id 2>/dev/null || true)
if echo "${EXISTING_CLIENT}" | grep -q '"id"'; then
  echo "==> Client '${CLIENT_ID}' already exists — skipping."
else
  echo "==> Creating client '${CLIENT_ID}'..."
  $KCADM create clients -r "${REALM}" \
    -s "clientId=${CLIENT_ID}" \
    -s enabled=true \
    -s publicClient=false \
    -s "secret=${CLIENT_SECRET}" \
    -s 'redirectUris=["http://localhost:3000/*"]' \
    -s 'webOrigins=["http://localhost:3000"]' \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false
fi

# ── 5. Test user ───────────────────────────────────────────────────────────────
EXISTING_USER=$($KCADM get users -r "${REALM}" -q "username=testuser@example.local" --fields id 2>/dev/null || true)
if echo "${EXISTING_USER}" | grep -q '"id"'; then
  echo "==> User 'testuser@example.local' already exists — skipping."
else
  echo "==> Creating test user 'testuser@example.local'..."
  $KCADM create users -r "${REALM}" \
    -s 'username=testuser@example.local' \
    -s 'email=testuser@example.local' \
    -s 'firstName=Test' \
    -s 'lastName=User' \
    -s enabled=true \
    -s emailVerified=true \
    -s 'requiredActions=["UPDATE_PASSWORD"]'

  echo "==> Setting temporary password..."
  $KCADM set-password -r "${REALM}" \
    --username 'testuser@example.local' \
    --new-password 'Test1234!' \
    --temporary
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Keycloak provisioning complete!                     ║"
echo "║  Realm:  myrealm                                     ║"
echo "║  Client: myapp                                       ║"
echo "║  User:   testuser@example.local / Test1234!          ║"
echo "╚══════════════════════════════════════════════════════╝"
