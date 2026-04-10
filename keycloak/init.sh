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
  echo "==> Creating realm '${REALM}' from realm.json..."
  # realm.json includes the custom browser auth flow and all its sub-flows,
  # so they are created atomically here rather than one-by-one via the API.
  $KCADM create realms -f /keycloak/realm.json
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

# ── 4. Audit events ────────────────────────────────────────────────────────────
echo "==> Enabling audit events..."
cat > /tmp/events-config.json << 'EVENTS_EOF'
{
  "eventsEnabled": true,
  "eventsExpiration": 604800,
  "adminEventsEnabled": true,
  "adminEventsDetailsEnabled": true,
  "enabledEventTypes": [
    "AUTHREQID_TO_TOKEN", "AUTHREQID_TO_TOKEN_ERROR",
    "CLIENT_DELETE", "CLIENT_DELETE_ERROR",
    "CLIENT_INITIATED_ACCOUNT_LINKING", "CLIENT_INITIATED_ACCOUNT_LINKING_ERROR",
    "CLIENT_LOGIN", "CLIENT_LOGIN_ERROR",
    "CLIENT_REGISTER", "CLIENT_REGISTER_ERROR",
    "CLIENT_UPDATE", "CLIENT_UPDATE_ERROR",
    "CODE_TO_TOKEN", "CODE_TO_TOKEN_ERROR",
    "CUSTOM_REQUIRED_ACTION", "CUSTOM_REQUIRED_ACTION_ERROR",
    "DELETE_ACCOUNT", "DELETE_ACCOUNT_ERROR",
    "EXECUTE_ACTION_TOKEN", "EXECUTE_ACTION_TOKEN_ERROR",
    "EXECUTE_ACTIONS", "EXECUTE_ACTIONS_ERROR",
    "FEDERATED_IDENTITY_LINK", "FEDERATED_IDENTITY_LINK_ERROR",
    "FEDERATED_IDENTITY_OVERRIDE_LINK", "FEDERATED_IDENTITY_OVERRIDE_LINK_ERROR",
    "GRANT_CONSENT", "GRANT_CONSENT_ERROR",
    "IDENTITY_PROVIDER_FIRST_LOGIN", "IDENTITY_PROVIDER_FIRST_LOGIN_ERROR",
    "IDENTITY_PROVIDER_LINK_ACCOUNT", "IDENTITY_PROVIDER_LINK_ACCOUNT_ERROR",
    "IDENTITY_PROVIDER_LOGIN", "IDENTITY_PROVIDER_LOGIN_ERROR",
    "IDENTITY_PROVIDER_POST_LOGIN", "IDENTITY_PROVIDER_POST_LOGIN_ERROR",
    "IMPERSONATE", "IMPERSONATE_ERROR",
    "INVITE_ORG", "INVITE_ORG_ERROR",
    "JWT_AUTHORIZATION_GRANT", "JWT_AUTHORIZATION_GRANT_ERROR",
    "LOGIN", "LOGIN_ERROR",
    "LOGOUT", "LOGOUT_ERROR",
    "OAUTH2_DEVICE_AUTH", "OAUTH2_DEVICE_AUTH_ERROR",
    "OAUTH2_DEVICE_CODE_TO_TOKEN", "OAUTH2_DEVICE_CODE_TO_TOKEN_ERROR",
    "OAUTH2_DEVICE_VERIFY_USER_CODE", "OAUTH2_DEVICE_VERIFY_USER_CODE_ERROR",
    "OAUTH2_EXTENSION_GRANT", "OAUTH2_EXTENSION_GRANT_ERROR",
    "PERMISSION_TOKEN",
    "REGISTER", "REGISTER_ERROR",
    "REMOVE_CREDENTIAL", "REMOVE_CREDENTIAL_ERROR",
    "REMOVE_FEDERATED_IDENTITY", "REMOVE_FEDERATED_IDENTITY_ERROR",
    "REMOVE_TOTP", "REMOVE_TOTP_ERROR",
    "RESET_PASSWORD", "RESET_PASSWORD_ERROR",
    "RESTART_AUTHENTICATION", "RESTART_AUTHENTICATION_ERROR",
    "REVOKE_GRANT", "REVOKE_GRANT_ERROR",
    "SEND_IDENTITY_PROVIDER_LINK", "SEND_IDENTITY_PROVIDER_LINK_ERROR",
    "SEND_RESET_PASSWORD", "SEND_RESET_PASSWORD_ERROR",
    "SEND_VERIFY_EMAIL", "SEND_VERIFY_EMAIL_ERROR",
    "TOKEN_EXCHANGE", "TOKEN_EXCHANGE_ERROR",
    "UPDATE_CONSENT", "UPDATE_CONSENT_ERROR",
    "UPDATE_CREDENTIAL", "UPDATE_CREDENTIAL_ERROR",
    "UPDATE_EMAIL", "UPDATE_EMAIL_ERROR",
    "UPDATE_PASSWORD", "UPDATE_PASSWORD_ERROR",
    "UPDATE_PROFILE", "UPDATE_PROFILE_ERROR",
    "UPDATE_TOTP", "UPDATE_TOTP_ERROR",
    "USER_DISABLED_BY_PERMANENT_LOCKOUT",
    "USER_DISABLED_BY_TEMPORARY_LOCKOUT",
    "VERIFIABLE_CREDENTIAL_CREATE_OFFER", "VERIFIABLE_CREDENTIAL_CREATE_OFFER_ERROR",
    "VERIFIABLE_CREDENTIAL_OFFER_REQUEST", "VERIFIABLE_CREDENTIAL_OFFER_REQUEST_ERROR",
    "VERIFIABLE_CREDENTIAL_PRE_AUTHORIZED_GRANT", "VERIFIABLE_CREDENTIAL_PRE_AUTHORIZED_GRANT_ERROR",
    "VERIFIABLE_CREDENTIAL_REQUEST", "VERIFIABLE_CREDENTIAL_REQUEST_ERROR",
    "VERIFY_EMAIL", "VERIFY_EMAIL_ERROR",
    "VERIFY_PROFILE", "VERIFY_PROFILE_ERROR"
  ]
}
EVENTS_EOF
$KCADM update realms/${REALM} -f /tmp/events-config.json
$KCADM update realms/${REALM} -s 'attributes.adminEventsExpiration=604800'

# ── 5. Required actions ────────────────────────────────────────────────────────
# Verify Email (priority 10) and Update Password (priority 20) are the top two
# default actions — applied automatically to every new user.
echo "==> Configuring required actions..."
$KCADM update "authentication/required-actions/VERIFY_EMAIL" -r "${REALM}" \
  -s enabled=true -s defaultAction=true -s priority=10
$KCADM update "authentication/required-actions/UPDATE_PASSWORD" -r "${REALM}" \
  -s enabled=true -s defaultAction=true -s priority=20

# ── 6. Client ──────────────────────────────────────────────────────────────────
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

# ── 8. Users ───────────────────────────────────────────────────────────────────
create_user() {
  local username="$1" email="$2" first="$3" last="$4" required_actions="$5" temporary="$6"

  EXISTING=$($KCADM get users -r "${REALM}" -q "username=${username}" --fields id 2>/dev/null || true)
  if echo "${EXISTING}" | grep -q '"id"'; then
    echo "==> User '${username}' already exists — skipping."
    return
  fi

  echo "==> Creating user '${username}'..."
  $KCADM create users -r "${REALM}" \
    -s "username=${username}" \
    -s "email=${email}" \
    -s "firstName=${first}" \
    -s "lastName=${last}" \
    -s enabled=true \
    -s emailVerified=true \
    -s "requiredActions=${required_actions}"

  if [ "${temporary}" = "true" ]; then
    $KCADM set-password -r "${REALM}" --username "${username}" --new-password 'Test1234!' --temporary
  else
    $KCADM set-password -r "${REALM}" --username "${username}" --new-password 'Test1234!'
  fi
}

# Primary test user — prompted to change password on first login
create_user 'testuser@example.local' 'testuser@example.local' 'Test' 'User' '["UPDATE_PASSWORD"]' 'true'

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Keycloak provisioning complete!                     ║"
echo "║  Realm:  myrealm                                     ║"
echo "║  Client: myapp                                       ║"
echo "║  Users:  testuser@example.local                      ║"
echo "╚══════════════════════════════════════════════════════╝"
