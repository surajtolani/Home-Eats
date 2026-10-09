// Twilio client construction — used by routes/auth.js's Verify calls (code
// generation/expiry/rate-limiting all owned by Verify itself, not a raw SMS
// + our own OTP table) and by `sendInviteSMS` below (a plain text message,
// nothing to do with Verify).
"use strict";

const twilio = require("twilio");

// Lazily constructed per call, and returns null instead of throwing when
// credentials are missing — same "construct eagerly, guard per-route" shape
// as `anthropicClient()` in app.js, so a missing Twilio config surfaces as
// a clear 500 from the specific route that needed it rather than crashing
// the whole server at startup.
function twilioClient() {
  const { TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN } = process.env;
  if (!TWILIO_ACCOUNT_SID || !TWILIO_AUTH_TOKEN) return null;
  return twilio(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN);
}

// Direct user report: inviting a phone number with no Home Eats account yet
// (to a group, or as a friend) used to just leave a PENDING Invite sitting
// in the database with nothing telling that person it exists at all — no
// push (there's no account/device to push to), and, until now, no text
// either. This sends one.
//
// A DIFFERENT Twilio product from `twilioClient()`'s other caller
// (routes/auth.js's Verify sends): this is a plain SMS message, which needs
// its own "from" sender — Verify's own service SID isn't usable as a `from`
// for an arbitrary message. `TWILIO_SMS_FROM_NUMBER` is a Twilio phone
// number (or a Messaging Service SID, which `client.messages.create` also
// accepts as `from`) capable of sending SMS, purchased/configured
// separately from the Verify service already in use.
//
// Optional, same "silently no-ops rather than failing the caller" shape as
// `sendPush` — an invite to someone with no account yet always succeeds and
// leaves a real, resolvable Invite row regardless of whether this is
// configured or the send itself fails; this is a courtesy notification on
// top of that, not something the invite's own success depends on.
async function sendInviteSMS({ to, body }) {
  const client = twilioClient();
  const fromNumber = process.env.TWILIO_SMS_FROM_NUMBER;
  if (!client || !fromNumber) return;
  try {
    await client.messages.create({ to, from: fromNumber, body });
  } catch (error) {
    console.error("Invite SMS send failed", error);
  }
}

// Shared by both callers of `sendInviteSMS` (routes/groups.js and
// routes/friends.js) so the "mention the download link, if we have one" and
// "always carry an opt-out line" rules live in one place rather than being
// copy-pasted at each call site. `APP_DOWNLOAD_URL` is optional (e.g. not
// set yet while only a private TestFlight link exists) — the message still
// reads fine without it. The trailing "Reply STOP to opt out" is not
// optional — it's what this app's A2P 10DLC Campaign registration declares
// every invite SMS includes (see backend/README.md's SMS-invite section),
// so it has to actually be there on every send, not just when convenient.
function inviteSMSBody(message) {
  const downloadUrl = process.env.APP_DOWNLOAD_URL;
  const withLink = downloadUrl ? `${message} Get Home Eats: ${downloadUrl}` : message;
  return `${withLink} Reply STOP to opt out.`;
}

module.exports = { twilioClient, sendInviteSMS, inviteSMSBody };
