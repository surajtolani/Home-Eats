// Keeps raw phone numbers out of logs and out of anything stored only for
// bookkeeping (rate-limit keys). See backend/README.md's "Phone numbers in
// logs" note.
"use strict";

const crypto = require("crypto");

// Country calling codes are prefix-free: 1 and 7 are the only one-digit
// codes, these are the two-digit ones (ITU-T E.164 assignments), and every
// other code has three digits.
const TWO_DIGIT_COUNTRY_CODES = new Set([
  "20", "27", "30", "31", "32", "33", "34", "36", "39", "40", "41", "43", "44", "45", "46", "47", "48", "49",
  "51", "52", "53", "54", "55", "56", "57", "58", "60", "61", "62", "63", "64", "65", "66", "81", "82", "84",
  "86", "90", "91", "92", "93", "94", "95", "98",
]);

function countryCodeLength(digits) {
  if (digits[0] === "1" || digits[0] === "7") return 1;
  return TWO_DIGIT_COUNTRY_CODES.has(digits.slice(0, 2)) ? 2 : 3;
}

const E164 = /^\+[1-9]\d{6,14}$/;

// "+14155551234" -> "+1•••••1234": the country code and the last 4 digits,
// with a fixed-length mask so the number's length isn't revealed either.
// Anything that isn't an E.164 number becomes "[redacted]".
function redactPhone(e164) {
  if (typeof e164 !== "string" || !E164.test(e164)) return "[redacted]";
  const digits = e164.slice(1);
  return `+${digits.slice(0, countryCodeLength(digits))}•••••${digits.slice(-4)}`;
}

// Used only when neither secret is configured (local development), so
// hashing still works; such keys change on every restart.
const fallbackSecret = crypto.randomBytes(32);

function hashSecret() {
  return process.env.LOG_HASH_SECRET || process.env.JWT_SECRET || fallbackSecret;
}

// A short, stable, keyed hash of a phone number (12 hex characters of an
// HMAC-SHA256 with LOG_HASH_SECRET, falling back to JWT_SECRET). The same
// number always gives the same key, so repeated hits on one number can be
// correlated in logs and counted by rate limiters, but the number itself
// can't be recovered from it without the secret.
function phoneLogKey(e164) {
  return crypto.createHmac("sha256", hashSecret()).update(String(e164)).digest("hex").slice(0, 12);
}

// Masks anything in free text that looks like a phone number: "+" followed
// by 7-15 digits is redacted with redactPhone; any other run of 7 or more
// digits becomes "[number]". For error messages from Twilio or Prisma, which
// can quote the number they were given.
function redactPhonesInText(text) {
  return String(text ?? "").replace(/\+?\d{7,15}/g, (match) =>
    match.startsWith("+") ? redactPhone(match) : "[number]"
  );
}

// A one-line, phone-free description of an error for console.error, in
// place of logging the whole error object (which can carry request details
// such as the number a Twilio call was sent to).
function describeError(error) {
  if (!error || typeof error !== "object") return redactPhonesInText(error);
  const parts = [error.name || "Error"];
  if (error.code !== undefined) parts.push(`code=${error.code}`);
  if (error.status !== undefined) parts.push(`status=${error.status}`);
  if (error.message) parts.push(redactPhonesInText(error.message));
  return parts.join(" ");
}

module.exports = { redactPhone, phoneLogKey, redactPhonesInText, describeError };
