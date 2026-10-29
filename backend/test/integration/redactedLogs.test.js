"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { startTestServer, resetDatabase } = require("../helpers/server");

test("the request-code log line never contains the full phone number", async (t) => {
  const server = await startTestServer();
  if (!server) {
    t.skip("TEST_DATABASE_URL is not set");
    return;
  }
  t.after(() => server.close());
  await resetDatabase();
  const { phoneLogKey } = require("../../lib/redact");

  const lines = [];
  t.mock.method(console, "log", (...args) => lines.push(args.map(String).join(" ")));
  t.mock.method(console, "error", (...args) => lines.push(args.map(String).join(" ")));

  const phoneNumber = "+14155550123";
  await fetch(`${server.baseURL}/auth/request-code`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ phoneNumber }),
  });

  const requestLine = lines.find((line) => line.startsWith("[request-code]"));
  assert.ok(requestLine, lines.join("\n"));
  assert.ok(requestLine.includes(`phone=+1•••••0123 phoneKey=${phoneLogKey(phoneNumber)} `), requestLine);
  for (const line of lines) {
    assert.ok(!line.includes("4155550123"), line);
  }
});
