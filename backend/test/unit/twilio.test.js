"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { inviteSMSBody } = require("../../lib/twilio");

const OPT_OUT = "Reply STOP to opt out.";

function withDownloadURL(value, fn) {
  const original = process.env.APP_DOWNLOAD_URL;
  if (value === undefined) delete process.env.APP_DOWNLOAD_URL;
  else process.env.APP_DOWNLOAD_URL = value;
  try {
    fn();
  } finally {
    if (original === undefined) delete process.env.APP_DOWNLOAD_URL;
    else process.env.APP_DOWNLOAD_URL = original;
  }
}

test("inviteSMSBody ends with the opt-out line without APP_DOWNLOAD_URL", () => {
  withDownloadURL(undefined, () => {
    const body = inviteSMSBody("Sam invited you to Home Eats.");
    assert.ok(body.endsWith(OPT_OUT), body);
    assert.ok(!body.includes("Get Home Eats:"), body);
  });
});

test("inviteSMSBody ends with the opt-out line with APP_DOWNLOAD_URL", () => {
  withDownloadURL("https://example.com/app", () => {
    const body = inviteSMSBody("Sam invited you to Home Eats.");
    assert.ok(body.endsWith(OPT_OUT), body);
    assert.ok(body.includes("Get Home Eats: https://example.com/app"), body);
  });
});
