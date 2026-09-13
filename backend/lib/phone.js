// Shared E.164 phone number shape check, used by routes/auth.js,
// routes/friends.js, and routes/groups.js (anywhere a phone number comes in
// on a request body). E.164: a leading "+", a country code digit 1-9 (no
// leading 0), then 6-14 more digits. This is intentionally just a shape
// check — real validation that the number is reachable happens at Twilio.
"use strict";

const E164_PHONE_REGEX = /^\+[1-9]\d{6,14}$/;
const PHONE_ERROR = "phoneNumber must be in E.164 format, e.g. +14155551234.";

// A single field-level Zod schema, spreadable into any z.object({...}).
const { z } = require("zod");
const phoneNumberField = z.string().regex(E164_PHONE_REGEX, PHONE_ERROR);

module.exports = { E164_PHONE_REGEX, PHONE_ERROR, phoneNumberField };
