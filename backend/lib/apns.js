// Real push notifications (a friend request, a group invite) delivered as
// an actual phone notification, not just something that shows up in the
// in-app Notifications feed if someone happens to open the app and look —
// direct user request. Token-based (.p8) APNs auth via `@parse/node-apn`
// (the actively maintained fork of the original `apn` package, which pulls
// in an abandoned GitHub-tarball dependency this deployment's package
// manager can't even resolve).
//
// Same "lazily constructed, returns null instead of throwing when
// credentials are missing" shape as `twilioClient()`
// (backend/lib/twilio.js) and `anthropicClient()` (backend/index.js) — a
// push send is best-effort background work triggered as a side effect of
// something else (creating a friend request, a group invite), never
// something a request is waiting on, so a missing/misconfigured deployment
// should silently no-op rather than fail the request that triggered it.
//
// Needs four env vars, all from the Apple Developer account this app's
// bundle id (`family.homeeats.app`, see project.yml) belongs to:
// - APNS_KEY_ID / APNS_TEAM_ID: from the .p8 Auth Key's own page in the
//   Developer Portal (Certificates, Identifiers & Profiles -> Keys).
// - APNS_AUTH_KEY: the .p8 file's raw contents (the whole
//   "-----BEGIN PRIVATE KEY-----...-----END PRIVATE KEY-----" block,
//   including those header/footer lines) — paste it directly into the env
//   var; `resolveCredential` (in @parse/node-apn's own
//   lib/credentials/resolve.js) recognizes a PEM block and uses it as-is
//   without trying to read it as a file path.
// - APNS_PRODUCTION: "true" for a TestFlight/App Store build, unset/"false"
//   for a Debug build signed with the `development` aps-environment (see
//   HomeEats/Supporting/HomeEats.entitlements) — sending against the wrong
//   environment for a given build silently fails to deliver, so this has
//   to match whichever build is actually receiving the push.
"use strict";

const apn = require("@parse/node-apn");

const BUNDLE_ID = "family.homeeats.app";

let cachedProvider;
let cachedConfigKey;

function configKey() {
  // Cheap way to detect "the relevant env vars changed since the cached
  // provider was built" without a restart — not expected to happen in
  // practice on Render (env vars are fixed per deploy), but cheap insurance
  // against a stale cached provider if they ever are changed live.
  return [
    process.env.APNS_KEY_ID,
    process.env.APNS_TEAM_ID,
    process.env.APNS_AUTH_KEY,
    process.env.APNS_PRODUCTION,
  ].join("|");
}

function apnsProvider() {
  const { APNS_KEY_ID, APNS_TEAM_ID, APNS_AUTH_KEY } = process.env;
  if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_AUTH_KEY) return null;

  const key = configKey();
  if (cachedProvider && cachedConfigKey === key) return cachedProvider;

  cachedProvider = new apn.Provider({
    token: { key: APNS_AUTH_KEY, keyId: APNS_KEY_ID, teamId: APNS_TEAM_ID },
    production: process.env.APNS_PRODUCTION === "true",
  });
  cachedConfigKey = key;
  return cachedProvider;
}

// Sends one alert-style push to every one of `deviceTokens` (typically all
// of one user's `DeviceToken` rows — see routes/me.js — since someone can
// have more than one device registered). `title`/`body` are the banner
// text; `payload` is arbitrary extra JSON the client could use later for
// deep-linking (not acted on by the iOS client yet — see
// HomeEatsAppDelegate.swift — this just carries it through in case that's
// worth adding later). Silently does nothing at all if APNs isn't
// configured yet (see this file's own doc comment) or `deviceTokens` is
// empty (nobody signed in on a real device to push to — most commonly, the
// recipient hasn't downloaded/signed into the app at all yet, in which case
// there's nothing to push to no matter what).
//
// Deliberately fire-and-forget from every call site (`routes/friends.js`,
// `routes/groups.js`) — a push failing (an expired/invalid token, APNs
// being briefly unreachable, ...) must never fail the friend
// request/invite it's a side effect of. Failures are logged, not thrown.
async function sendPush({ deviceTokens, title, body, payload }) {
  if (!deviceTokens.length) return;
  const provider = apnsProvider();
  if (!provider) return;

  const notification = new apn.Notification();
  notification.alert = { title, body };
  notification.sound = "default";
  notification.topic = BUNDLE_ID;
  notification.payload = payload || {};

  try {
    const result = await provider.send(notification, deviceTokens);
    if (result.failed.length) {
      console.error("APNs push partially failed", result.failed.map((f) => ({ device: f.device, error: f.error || f.response })));
    }
  } catch (error) {
    console.error("APNs push threw", error);
  }
}

module.exports = { sendPush };
