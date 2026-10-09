// Route-level fail-closed/fail-open behavior when the rate-limit database is
// unreachable. Runs the real app with no working database: the routes below
// check their limiters before touching anything else that needs Postgres.
"use strict";

process.env.DATABASE_URL = "postgresql://test:test@127.0.0.1:1/unreachable";

const test = require("node:test");
const assert = require("node:assert/strict");
const { app } = require("../../app");
const { prisma } = require("../../lib/prisma");

let server;
let baseURL;

test.before(async () => {
  server = await new Promise((resolve) => {
    const s = app.listen(0, () => resolve(s));
  });
  baseURL = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await prisma.$disconnect();
});

function postJSON(path, body) {
  return fetch(`${baseURL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

test("POST /auth/request-code returns 503 (fails closed)", async (t) => {
  t.mock.method(console, "error", () => {});
  t.mock.method(console, "log", () => {});
  const res = await postJSON("/auth/request-code", { phoneNumber: "+14155550100" });
  assert.equal(res.status, 503);
});

test("POST /auth/verify-code returns 503 (fails closed)", async (t) => {
  t.mock.method(console, "error", () => {});
  const res = await postJSON("/auth/verify-code", { phoneNumber: "+14155550100", code: "123456" });
  assert.equal(res.status, 503);
});

test("GET /recipes/image-proxy is let through (fails open)", async (t) => {
  t.mock.method(console, "error", () => {});
  // No `url` query parameter, so once past the limiter the route itself
  // rejects the request with 400. A 503 or 429 here would mean the
  // limiter blocked it.
  const res = await fetch(`${baseURL}/recipes/image-proxy`);
  assert.equal(res.status, 400);
});
