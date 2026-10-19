// GET /recipes/image-proxy through the real app. No database needed: the
// route's rate limiter fails open when the database is unreachable.
"use strict";

process.env.DATABASE_URL = "postgresql://test:test@127.0.0.1:1/unreachable";

const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { app } = require("../../app");
const { prisma } = require("../../lib/prisma");

let appServer;
let appURL;
let target;
let targetHits = 0;

test.before(async () => {
  appServer = await new Promise((resolve) => {
    const s = app.listen(0, "127.0.0.1", () => resolve(s));
  });
  appURL = `http://127.0.0.1:${appServer.address().port}`;
  target = http.createServer((req, res) => {
    targetHits += 1;
    res.writeHead(200, { "content-type": "image/png", "x-internal-secret": "do-not-leak" });
    res.end("internal");
  });
  await new Promise((resolve) => target.listen(0, "127.0.0.1", resolve));
});

test.after(async () => {
  await new Promise((resolve) => appServer.close(resolve));
  await new Promise((resolve) => target.close(resolve));
  await prisma.$disconnect();
});

async function proxy(url) {
  const res = await fetch(`${appURL}/recipes/image-proxy?url=${encodeURIComponent(url)}`);
  return { status: res.status, headers: res.headers, body: await res.json() };
}

test("internal targets get a fixed 400 and are never contacted", async (t) => {
  t.mock.method(console, "error", () => {});
  targetHits = 0;
  const port = target.address().port;
  const cases = [
    [`http://127.0.0.1:${port}/`, "Invalid 'url'."],
    ["http://127.0.0.1/", "That image can't be loaded."],
    ["http://localhost/", "That image can't be loaded."],
    ["http://169.254.169.254/latest/meta-data/", "That image can't be loaded."],
    ["http://[::1]/", "That image can't be loaded."],
    ["http://10.0.0.1/", "That image can't be loaded."],
    ["ftp://example.com/x.png", "Invalid 'url'."],
    ["not a url", "Invalid 'url'."],
  ];
  for (const [url, message] of cases) {
    // eslint-disable-next-line no-await-in-loop
    const res = await proxy(url);
    assert.equal(res.status, 400, url);
    assert.deepEqual(res.body, { error: message }, url);
    assert.equal(res.headers.get("x-internal-secret"), null);
  }
  assert.equal(targetHits, 0);
});

test("a hostname that doesn't exist is a 400", async (t) => {
  t.mock.method(console, "error", () => {});
  const res = await proxy("http://does-not-exist.invalid/x.png");
  assert.equal(res.status, 400);
  assert.deepEqual(res.body, { error: "That image can't be loaded." });
});

test("a missing url is still a 400", async (t) => {
  t.mock.method(console, "error", () => {});
  const res = await fetch(`${appURL}/recipes/image-proxy`);
  assert.equal(res.status, 400);
});
