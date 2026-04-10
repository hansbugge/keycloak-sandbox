# Keycloak OIDC Dev Setup

A zero-config Docker Compose environment with:
- **Keycloak** — identity provider (admin console on port 8080)
- **Mailpit** — fake SMTP server for catching emails (web UI on port 8025)
- **Demo app** — minimal Node.js OIDC client app (port 3000)

Everything is provisioned automatically. No manual Keycloak configuration needed.

## Quick start

```bash
docker compose up
```

Wait ~60–90 seconds for Keycloak to initialise (it logs a lot). Once you see:

```
keycloak-provisioner-1  | ╔══════════════════════════════════════════════════════╗
keycloak-provisioner-1  | ║  Keycloak provisioning complete!                     ║
```

…all services are ready.

## URLs

| Service            | URL                                  | Notes                        |
|--------------------|--------------------------------------|------------------------------|
| Demo app           | http://localhost:3000                | Login / profile / logout     |
| Keycloak console   | http://localhost:8080                | Admin UI                     |
| Mailpit web UI     | http://localhost:8025                | Catches all outbound email   |

## Credentials

| What                  | Value                      |
|-----------------------|----------------------------|
| Keycloak admin user   | `admin` / `admin`          |
| Test user (OIDC)      | `testuser@myrealm.local`     |
| Test user password    | `Test1234!` *(temporary)*  |

The test user has **UPDATE_PASSWORD** set as a required action, so Keycloak will prompt for a new password on the very first login.

## Provisioned Keycloak configuration

| Setting           | Value                                |
|-------------------|--------------------------------------|
| Realm             | `myrealm`                              |
| Client ID         | `myrealm-app`                          |
| Client secret     | `dev-secret-change-me`               |
| Redirect URI      | `http://localhost:3000/callback`     |
| SMTP host/port    | `mailpit:1025`                       |
| SMTP from         | `keycloak@myrealm.local`               |

All password-reset and verification emails sent by Keycloak are caught by Mailpit and visible at http://localhost:8025.

## Demo app endpoints

| Route       | Description                                         |
|-------------|-----------------------------------------------------|
| `/`         | Home page — login button or logged-in status        |
| `/login`    | Starts OIDC authorization code flow                 |
| `/callback` | Handles redirect from Keycloak                      |
| `/profile`  | Shows raw ID token claims (protected)               |
| `/logout`   | Clears session + triggers Keycloak front-channel logout |
| `/health`   | JSON health probe used by Docker                    |

## Stopping and cleaning up

```bash
# Stop (keep data):
docker compose down

# Stop and wipe everything (Keycloak H2 DB, etc.):
docker compose down -v
```

> **Note:** Keycloak uses an embedded H2 database in dev mode. Data does not persist across `docker compose down -v`. Running `docker compose down` (without `-v`) keeps the container layer but H2 is not volume-mounted, so data is also lost on container removal. Re-running `docker compose up` re-provisions from scratch (the provisioner is idempotent).

## Architecture

```
Browser
  │
  ├─► :3000  demo app (Node/Express + openid-client)
  │           │  server-to-server calls via internal Docker DNS
  │           └─► keycloak:8080  (token exchange, JWKS, userinfo)
  │
  └─► :8080  Keycloak (auth redirects land here from browser)
               │
               └─► mailpit:1025  (outbound SMTP)
```

The demo app uses two Keycloak base URLs:
- **Public** (`http://localhost:8080`) — browser-facing redirects (auth, logout)
- **Internal** (`http://keycloak:8080`) — server-to-server calls (token exchange, JWKS)

This is necessary because the app container cannot reach `localhost:8080` (that's the host) but the browser cannot reach `keycloak:8080` (that's inside Docker). `KC_HOSTNAME_URL=http://localhost:8080` ensures all issued tokens carry `iss=http://localhost:8080/realms/myrealm` regardless of which URL the token endpoint was called from.
