// Twilio client construction — used by routes/auth.js's Verify calls (code
// generation/expiry/rate-limiting all owned by Verify itself, not a raw SMS
// + our own OTP table) and by `sendInviteSMS` below (a plain text message,
// nothing to do with Verify).
"use strict";

const twilio = require("twilio");
const { reserveQuotas } = require("./rateLimit");
const { redactPhone, phoneLogKey, describeError } = require("./redact");

// Set only by tests (see `__setClientForTests` below) so invite SMS can be
// captured without real Twilio credentials.
let clientOverrideForTests = null;

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
// Resolves to true if Twilio accepted the message, false otherwise.
async function sendInviteSMS({ to, body }) {
  const client = clientOverrideForTests || twilioClient();
  const fromNumber = process.env.TWILIO_SMS_FROM_NUMBER;
  if (!client || !fromNumber) return false;
  try {
    await client.messages.create({ to, from: fromNumber, body });
    return true;
  } catch (error) {
    // describeError, not the error object: Twilio's error can echo the
    // number the text was sent to.
    console.error("Invite SMS send failed", describeError(error));
    return false;
  }
}

// Shared by both invite templates below (`friendInviteSMS`,
// `groupInviteSMS`) so the "mention the download link, if we have one" and
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

// Strip anything that could carry a link or look like one, so a display
// name can't smuggle a phishing URL (or a phone number) into an SMS we send.
// The display name is the only sender-controlled text in an invite SMS.
const SMS_NAME_MAX_LENGTH = 30;
const SMS_NAME_FALLBACK = "A friend";
function sanitizeNameForSMS(raw) {
  let name = String(raw ?? "").normalize("NFKC");
  name = name.replace(/\p{C}/gu, "");
  name = name.replace(/[^\p{L}\p{M} '.-]/gu, "");
  // Drop every dot that comes right before a letter, even with combining
  // marks in between ("evil.com" -> "evilcom", "evil-.com" -> "evil-com"):
  // a domain's last part always starts with a letter, so what's left can't
  // render as a link.
  name = name.replace(/\.(?=\p{M}*\p{L})/gu, "");
  name = name.replace(/\s+/g, " ").trim();
  // Cut by code point, not UTF-16 unit, so a character outside the Basic
  // Multilingual Plane is never split in half.
  name = Array.from(name).slice(0, SMS_NAME_MAX_LENGTH).join("").trim();
  // A name with no letters left (only punctuation, or nothing) reads badly
  // at the start of a text, so it gets the fallback too.
  return /\p{L}/u.test(name) ? name : SMS_NAME_FALLBACK;
}

// The only two invite texts this server sends. Fixed wording (no group
// name, no free text) so the A2P campaign's registered sample messages
// stay accurate and nobody can use invites to deliver their own message.
function friendInviteSMS(senderName) {
  return inviteSMSBody(`${sanitizeNameForSMS(senderName)} invited you to Home Eats, a family meal-planning app.`);
}

function groupInviteSMS(senderName) {
  return inviteSMSBody(`${sanitizeNameForSMS(senderName)} invited you to plan meals together on Home Eats.`);
}

const DAY_MS = 24 * 60 * 60 * 1000;
// Defaults for the invite-SMS settings, each overridable by the environment
// variable of the same name. The per-sender limits are generous on purpose
// so people can invite their whole family and friends while the app grows.
const INVITE_SMS_LIMIT_DEFAULTS = {
  INVITE_SMS_SENDER_DAILY_MAX: 75,
  INVITE_SMS_SENDER_MONTHLY_MAX: 300,
  INVITE_SMS_DAILY_GLOBAL_MAX: 500,
};
// "*" means every country. Which countries actually receive texts is then
// controlled in Twilio's Messaging Geo permissions (see backend/README.md).
const DEFAULT_INVITE_SMS_ALLOWED_COUNTRY_CODES = "*";

// Read on every call (not once at startup) so a changed environment
// variable takes effect on the next deploy without code changes, and so
// tests can vary it.
function inviteSMSLimit(name) {
  const fallback = INVITE_SMS_LIMIT_DEFAULTS[name];
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 0) {
    console.error(`[invite-sms] ${name}=${JSON.stringify(raw)} is not a whole number; using ${fallback}`);
    return fallback;
  }
  return parsed;
}

// "*" (every country), or comma-separated country calling codes matched
// against the start of the E.164 number ("1,44" or "+1,+44"). Unset or
// blank means the default. Note "1" covers every country in the North
// American Numbering Plan, not only the US and Canada. Returns null for
// "every country".
function inviteSMSAllowedCountryCodes() {
  const raw = process.env.INVITE_SMS_ALLOWED_COUNTRY_CODES;
  const value = raw === undefined || raw.trim() === "" ? DEFAULT_INVITE_SMS_ALLOWED_COUNTRY_CODES : raw;
  if (value.trim() === "*") return null;
  const codes = [];
  for (const entry of value.split(",")) {
    const code = entry.trim().replace(/^\+/, "");
    if (/^\d{1,3}$/.test(code)) {
      codes.push(code);
    } else if (code !== "") {
      console.error(`[invite-sms] ignoring invalid entry ${JSON.stringify(entry)} in INVITE_SMS_ALLOWED_COUNTRY_CODES`);
    }
  }
  return codes;
}

// How a recipient appears in the logs: redacted (country code and last 4
// digits) plus the same keyed hash used in sign-in logs, never in full.
function maskPhoneForLog(phoneNumber) {
  return `${redactPhone(phoneNumber)} toKey=${phoneLogKey(phoneNumber)}`;
}

// Sends one invite SMS if every safeguard allows it, otherwise skips it.
// Never throws, and its outcome never changes the API response (the caller
// has already responded), so the response can't reveal whether a text went
// out. Caps, all-or-nothing (nothing is used up unless the text is sent):
// - per recipient: 1 per rolling 7 days, across all senders
// - per sender: INVITE_SMS_SENDER_DAILY_MAX per rolling 24 hours (default
//   75) and INVITE_SMS_SENDER_MONTHLY_MAX per rolling 30 days (default 300)
// - whole deployment: INVITE_SMS_DAILY_GLOBAL_MAX per UTC day (default 500)
// If the cap check itself fails (database down), the text is skipped.
async function trySendInviteSMS({ senderUserId, senderName, to, kind }) {
  const logSkip = (reason, log = console.log) =>
    log(`[invite-sms] skipped reason=${reason} kind=${kind} sender=${senderUserId} to=${maskPhoneForLog(to)}`);
  try {
    const client = clientOverrideForTests || twilioClient();
    if (!client || !process.env.TWILIO_SMS_FROM_NUMBER) {
      return logSkip("not-configured");
    }
    const allowedCodes = inviteSMSAllowedCountryCodes();
    if (allowedCodes && !allowedCodes.some((code) => to.startsWith(`+${code}`))) {
      return logSkip("country-not-allowed");
    }

    let reservation;
    try {
      reservation = await reserveQuotas([
        // Keyed by a hash of the number, so the table never stores it.
        { reason: "recipient-limit", key: `invite-sms:recipient:${phoneLogKey(to)}`, windowMs: 7 * DAY_MS, max: 1 },
        {
          reason: "sender-day-limit",
          key: `invite-sms:sender-day:${senderUserId}`,
          windowMs: DAY_MS,
          max: inviteSMSLimit("INVITE_SMS_SENDER_DAILY_MAX"),
        },
        {
          reason: "sender-month-limit",
          key: `invite-sms:sender-month:${senderUserId}`,
          windowMs: 30 * DAY_MS,
          max: inviteSMSLimit("INVITE_SMS_SENDER_MONTHLY_MAX"),
        },
        {
          reason: "global-daily-limit",
          key: "invite-sms:global:all",
          utcDay: true,
          max: inviteSMSLimit("INVITE_SMS_DAILY_GLOBAL_MAX"),
        },
      ]);
    } catch (error) {
      console.error("[invite-sms] cap check failed", describeError(error));
      return logSkip("cap-check-failed", console.error);
    }
    if (!reservation.allowed) {
      // The global cap being hit is worth an error-level log: it means the
      // whole deployment has stopped sending invite texts for the day.
      return logSkip(reservation.reason, reservation.reason === "global-daily-limit" ? console.error : console.log);
    }

    const body = kind === "group" ? groupInviteSMS(senderName) : friendInviteSMS(senderName);
    // The caps above are already used up at this point even if Twilio
    // rejects the message, which errs on the side of sending fewer texts.
    if (await sendInviteSMS({ to, body })) {
      console.log(`[invite-sms] sent kind=${kind} sender=${senderUserId} to=${maskPhoneForLog(to)}`);
    } else {
      console.error(`[invite-sms] failed reason=twilio-error kind=${kind} sender=${senderUserId} to=${maskPhoneForLog(to)}`);
    }
  } catch (error) {
    console.error("[invite-sms] unexpected error", describeError(error));
  }
}

module.exports = {
  twilioClient,
  sendInviteSMS,
  inviteSMSBody,
  sanitizeNameForSMS,
  friendInviteSMS,
  groupInviteSMS,
  trySendInviteSMS,
  // Test seam: pass a fake `{ messages: { create } }` client, or null to reset.
  __setClientForTests(client) {
    clientOverrideForTests = client;
  },
};
