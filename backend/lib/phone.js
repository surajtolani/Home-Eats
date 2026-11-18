// Shared phone number check and normalization, used by routes/auth.js,
// routes/friends.js, and routes/groups.js (anywhere a phone number comes in
// on a request body).
//
// Every phone number is stored in E.164 form: a "+", the country code, then
// the national number with no national prefix and no formatting (US
// +17813633306, UK +447911123456, India +919876543210). Two strings that
// mean the same phone must end up as the same string, or the same person
// gets two accounts. That happened: iOS autofill put "+1 781 363 3306" in
// the field, the app put its own "+1" in front, and "+117813633306" reached
// the server. That string passed the old shape-only check, Twilio still
// delivered the code to +17813633306, and verify-code created a second user.
//
// So a number that libphonenumber recognizes as a real number is rewritten
// to its one canonical E.164 form ("+117813633306" becomes "+17813633306",
// "+44 07911 123456" becomes "+447911123456"). A number it doesn't recognize
// still gets the old rule (already E.164, nothing else), so a new number
// range the library's data doesn't know about yet never locks anyone out;
// Twilio remains the final judge of whether a number is reachable.
"use strict";

const { z } = require("zod");
const { parsePhoneNumberFromString } = require("libphonenumber-js/max");

const E164_PHONE_REGEX = /^\+[1-9]\d{6,14}$/;
const PHONE_ERROR = "Enter a full phone number with its country code, e.g. +14155551234.";

// What may appear in the raw input: a leading "+", digits, and the
// separators people and autofill put in phone numbers. Anything else (an
// extension, letters, a second number) is rejected rather than parsed,
// because libphonenumber will otherwise pull a number out of free text.
const RAW_INPUT_REGEX = /^\+[\d\s().\- ]+$/;
// Long enough for any formatted international number, short enough that
// nobody can send a large string into the parser.
const MAX_RAW_LENGTH = 40;

// Returns the canonical E.164 string for `raw`, or null if `raw` isn't an
// acceptable phone number. There's no region on the server, so the number
// has to carry its own country code (start with "+"); the iOS app does the
// region-aware parsing of what the user typed before it sends anything.
function normalizePhoneNumber(raw) {
  if (typeof raw !== "string") return null;
  const input = raw.trim();
  if (input.length === 0 || input.length > MAX_RAW_LENGTH) return null;
  if (!RAW_INPUT_REGEX.test(input)) return null;

  const parsed = parsePhoneNumberFromString(input);
  if (parsed && parsed.isValid() && !parsed.ext) {
    return parsed.number;
  }
  return E164_PHONE_REGEX.test(input) ? input : null;
}

// A single field-level Zod schema, spreadable into any z.object({...}).
// Parsing yields the canonical E.164 string, so routes always use
// `parsed.data.phoneNumber`, never the raw request body.
const phoneNumberField = z.string(PHONE_ERROR).transform((value, ctx) => {
  const normalized = normalizePhoneNumber(value);
  if (normalized === null) {
    ctx.addIssue({ code: "custom", message: PHONE_ERROR });
    return z.NEVER;
  }
  return normalized;
});

module.exports = { E164_PHONE_REGEX, PHONE_ERROR, normalizePhoneNumber, phoneNumberField };
