// Twilio Verify client construction — used by routes/auth.js for both
// sending and checking SMS codes. Verify (not raw SMS + our own OTP table)
// owns code generation, expiry, and rate-limiting, which matters here since
// this holds real phone numbers.
"use strict";

const twilio = require("twilio");

// Lazily constructed per call, and returns null instead of throwing when
// credentials are missing — same "construct eagerly, guard per-route" shape
// as `anthropicClient()` in index.js, so a missing Twilio config surfaces as
// a clear 500 from the specific route that needed it rather than crashing
// the whole server at startup.
function twilioClient() {
  const { TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN } = process.env;
  if (!TWILIO_ACCOUNT_SID || !TWILIO_AUTH_TOKEN) return null;
  return twilio(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN);
}

module.exports = { twilioClient };
