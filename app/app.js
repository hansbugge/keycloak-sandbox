'use strict';

const express = require('express');
const session = require('express-session');
const { Issuer, generators } = require('openid-client');

const app = express();
const PORT = parseInt(process.env.PORT || '3000', 10);

// Keycloak coordinates
const KEYCLOAK_INTERNAL = process.env.KEYCLOAK_INTERNAL_URL || 'http://localhost:8080';
const KEYCLOAK_PUBLIC   = process.env.KEYCLOAK_PUBLIC_URL   || 'http://localhost:8080';
const REALM             = process.env.KEYCLOAK_REALM        || 'myrealm';
const CLIENT_ID         = process.env.CLIENT_ID             || 'myapp';
const CLIENT_SECRET     = process.env.CLIENT_SECRET         || 'dev-secret-change-me';
const APP_URL           = process.env.APP_URL               || 'http://localhost:3000';
const SESSION_SECRET    = process.env.SESSION_SECRET        || 'change-me-in-production';

// ── OIDC client ────────────────────────────────────────────────────────────────
//
// We build the Issuer manually instead of using Issuer.discover() to handle the
// split-URL problem in Docker Compose:
//   - Browser-facing URLs (auth redirect, logout) must use the public hostname
//     (localhost:8080) so the browser can reach them.
//   - Server-to-server calls (token exchange, JWKS, userinfo) use the internal
//     Docker hostname (keycloak:8080) so the Node process can reach them.
//
// KC_HOSTNAME=http://localhost:8080 in Keycloak ensures all issued tokens
// carry iss=http://localhost:8080/realms/myrealm, matching the issuer below.

let oidcClient = null;

function buildOIDCClient() {
  const internalBase = `${KEYCLOAK_INTERNAL}/realms/${REALM}`;
  const publicBase   = `${KEYCLOAK_PUBLIC}/realms/${REALM}`;

  const issuer = new Issuer({
    issuer:                 publicBase,
    authorization_endpoint: `${publicBase}/protocol/openid-connect/auth`,
    token_endpoint:         `${internalBase}/protocol/openid-connect/token`,
    userinfo_endpoint:      `${internalBase}/protocol/openid-connect/userinfo`,
    jwks_uri:               `${internalBase}/protocol/openid-connect/certs`,
    end_session_endpoint:   `${publicBase}/protocol/openid-connect/logout`,
  });

  return new issuer.Client({
    client_id:     CLIENT_ID,
    client_secret: CLIENT_SECRET,
    redirect_uris: [`${APP_URL}/callback`],
    response_types: ['code'],
  });
}

// ── Session ────────────────────────────────────────────────────────────────────
app.use(session({
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, sameSite: 'lax' },
}));

// ── Health ─────────────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', oidcReady: oidcClient !== null });
});

// ── Home ───────────────────────────────────────────────────────────────────────
app.get('/', (req, res) => {
  const user = req.session.claims;
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Keycloak OIDC Demo</title>
  <style>
    body { font-family: sans-serif; max-width: 600px; margin: 60px auto; padding: 0 20px; }
    pre  { background: #f4f4f4; padding: 12px; border-radius: 4px; overflow: auto; }
    a    { margin-right: 12px; }
  </style>
</head>
<body>
  <h1>Keycloak OIDC Demo</h1>
  ${user
    ? `<p>Logged in as <strong>${user.name || user.preferred_username || user.email}</strong></p>
       <a href="/profile">View profile</a>
       <a href="/logout">Logout</a>`
    : `<p>Not logged in.</p>
       <a href="/login"><button>Login with Keycloak</button></a>`
  }
  <hr>
  <p style="color:#888;font-size:0.85em">
    Realm: <code>myrealm</code> &nbsp;|&nbsp;
    <a href="http://localhost:8080" target="_blank">Keycloak console</a> &nbsp;|&nbsp;
    <a href="http://localhost:8025" target="_blank">Mailpit</a>
  </p>
</body>
</html>`);
});

// ── Login ──────────────────────────────────────────────────────────────────────
app.get('/login', (req, res) => {
  if (!oidcClient) return res.status(503).send('OIDC client not ready yet, please retry.');

  const state = generators.state();
  const nonce = generators.nonce();
  req.session.oidcState = state;
  req.session.oidcNonce = nonce;

  const url = oidcClient.authorizationUrl({
    scope: 'openid email profile',
    state,
    nonce,
  });
  res.redirect(url);
});

// ── Callback ───────────────────────────────────────────────────────────────────
app.get('/callback', async (req, res) => {
  if (!oidcClient) return res.status(503).send('OIDC client not ready.');

  try {
    const params   = oidcClient.callbackParams(req);
    const tokenSet = await oidcClient.callback(
      `${APP_URL}/callback`,
      params,
      { state: req.session.oidcState, nonce: req.session.oidcNonce },
    );

    req.session.claims  = tokenSet.claims();
    req.session.idToken = tokenSet.id_token;
    delete req.session.oidcState;
    delete req.session.oidcNonce;

    res.redirect('/');
  } catch (err) {
    console.error('OIDC callback error:', err.message);
    res.status(400).send(`<pre>Login failed: ${err.message}\n\n<a href="/">Home</a></pre>`);
  }
});

// ── Profile ────────────────────────────────────────────────────────────────────
app.get('/profile', (req, res) => {
  if (!req.session.claims) return res.redirect('/login');

  const pretty = JSON.stringify(req.session.claims, null, 2);
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Profile — Keycloak OIDC Demo</title>
  <style>
    body { font-family: sans-serif; max-width: 700px; margin: 60px auto; padding: 0 20px; }
    pre  { background: #f4f4f4; padding: 16px; border-radius: 4px; overflow: auto; }
    a    { margin-right: 12px; }
  </style>
</head>
<body>
  <h1>Token Claims</h1>
  <pre>${pretty}</pre>
  <a href="/">Home</a>
  <a href="/logout">Logout</a>
</body>
</html>`);
});

// ── Logout ─────────────────────────────────────────────────────────────────────
app.get('/logout', (req, res) => {
  const idToken = req.session.idToken;
  req.session.destroy(() => {});

  if (oidcClient && idToken) {
    const url = oidcClient.endSessionUrl({
      id_token_hint:             idToken,
      post_logout_redirect_uri:  APP_URL,
    });
    return res.redirect(url);
  }
  res.redirect('/');
});

// ── Startup ────────────────────────────────────────────────────────────────────
async function start() {
  // Retry OIDC client construction (mainly for local dev outside Docker where
  // Keycloak might not yet be up).
  const MAX_RETRIES = 12;
  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      oidcClient = buildOIDCClient();
      console.log(`OIDC client configured (${KEYCLOAK_PUBLIC}/realms/${REALM})`);
      break;
    } catch (err) {
      if (attempt === MAX_RETRIES) {
        console.error('Could not build OIDC client:', err.message);
        process.exit(1);
      }
      console.log(`OIDC setup attempt ${attempt}/${MAX_RETRIES} failed: ${err.message} — retrying in 5 s`);
      await new Promise(r => setTimeout(r, 5000));
    }
  }

  app.listen(PORT, () => {
    console.log(`App listening on http://localhost:${PORT}`);
  });
}

start();
