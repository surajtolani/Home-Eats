// Runs against a real local HTTP server. Needs no database, so it always
// runs. The server is on 127.0.0.1, which the proxy blocks, so the library
// tests use ALLOW_LOOPBACK_FOR_TESTS to reach it on the first hop only.
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { safeFetchImage, ProxyError, ALLOW_LOOPBACK_FOR_TESTS } = require("../../lib/safeFetch");

const PNG_BYTES = Buffer.from("89504e470d0a1a0a0000000d49484452", "hex");
const MB = 1024 * 1024;

let server;
let base;
let secretHits = 0;

test.before(async () => {
  server = http.createServer((req, res) => {
    const { pathname } = new URL(req.url, "http://localhost");
    switch (pathname) {
      case "/image":
        res.writeHead(200, { "content-type": "image/png" });
        return res.end(PNG_BYTES);
      case "/image-with-params":
        res.writeHead(200, { "content-type": "Image/PNG; charset=binary" });
        return res.end(PNG_BYTES);
      case "/secret":
        secretHits += 1;
        res.writeHead(200, { "content-type": "image/png" });
        return res.end(PNG_BYTES);
      case "/redirect-to-loopback-ip":
        res.writeHead(302, { location: "http://127.0.0.1/secret" });
        return res.end();
      case "/redirect-to-localhost":
        res.writeHead(302, { location: "http://localhost/secret" });
        return res.end();
      case "/redirect-to-metadata":
        res.writeHead(307, { location: "http://169.254.169.254/latest/meta-data/" });
        return res.end();
      case "/redirect-same-server":
        // Relative redirect back to this same loopback server: the second
        // hop is checked like any other, so it's blocked too.
        res.writeHead(301, { location: "/secret" });
        return res.end();
      case "/redirect-to-file":
        res.writeHead(302, { location: "file:///etc/passwd" });
        return res.end();
      case "/redirect-odd-port":
        res.writeHead(302, { location: "http://example.com:8080/x.png" });
        return res.end();
      case "/gzip":
        res.writeHead(200, { "content-type": "image/png", "content-encoding": "gzip" });
        return res.end(PNG_BYTES);
      case "/echo-encoding":
        res.writeHead(200, { "content-type": "image/png", "x-seen-accept-encoding": req.headers["accept-encoding"] || "" });
        return res.end(req.headers["accept-encoding"] === "identity" ? PNG_BYTES : Buffer.alloc(0));
      case "/html":
        res.writeHead(200, { "content-type": "text/html" });
        return res.end("<html></html>");
      case "/svg":
        res.writeHead(200, { "content-type": "image/svg+xml" });
        return res.end("<svg xmlns='http://www.w3.org/2000/svg'/>");
      case "/no-type":
        res.writeHead(200);
        return res.end(PNG_BYTES);
      case "/not-found":
        res.writeHead(404, { "content-type": "image/png" });
        return res.end();
      case "/declared-too-large":
        res.writeHead(200, { "content-type": "image/png", "content-length": String(9 * MB) });
        return res.end();
      case "/chunked-too-large": {
        // 9 MB with no Content-Length, written in 64 KB chunks.
        res.writeHead(200, { "content-type": "image/png" });
        const chunk = Buffer.alloc(64 * 1024);
        let remaining = 9 * MB;
        const writeMore = () => {
          while (remaining > 0) {
            remaining -= chunk.length;
            if (!res.write(chunk)) return res.once("drain", writeMore);
          }
          return res.end();
        };
        res.on("close", () => {
          remaining = 0;
        });
        return writeMore();
      }
      case "/slow":
        res.writeHead(200, { "content-type": "image/png" });
        res.write(PNG_BYTES);
        return undefined; // never ends
      default:
        res.writeHead(404);
        return res.end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});

const viaLoopback = (path, opts = {}) => safeFetchImage(`${base}${path}`, { [ALLOW_LOOPBACK_FOR_TESTS]: true, ...opts });

async function rejectsWith(promise, kind) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof ProxyError, `expected ProxyError, got ${error}`);
    assert.equal(error.kind, kind);
    return true;
  });
}

test("returns an image's bytes and normalized content type", async () => {
  const result = await viaLoopback("/image");
  assert.equal(result.contentType, "image/png");
  assert.deepEqual(result.buffer, PNG_BYTES);
  const withParams = await viaLoopback("/image-with-params");
  assert.equal(withParams.contentType, "image/png");
});

test("without the test option, loopback is blocked", async () => {
  await rejectsWith(safeFetchImage(`${base}/image`), "invalid-url"); // non-standard port
  await rejectsWith(safeFetchImage("http://127.0.0.1/image"), "blocked");
  await rejectsWith(safeFetchImage("http://[::1]/image"), "blocked");
  await rejectsWith(safeFetchImage("http://[::ffff:7f00:1]/image"), "blocked");
  await rejectsWith(safeFetchImage("http://localhost/image"), "blocked");
});

test("a redirect to a private address is rejected without being followed", async () => {
  secretHits = 0;
  await rejectsWith(viaLoopback("/redirect-to-loopback-ip"), "blocked");
  await rejectsWith(viaLoopback("/redirect-to-localhost"), "blocked");
  await rejectsWith(viaLoopback("/redirect-to-metadata"), "blocked");
  assert.equal(secretHits, 0);
});

test("the test option only applies to the first hop", async () => {
  secretHits = 0;
  await rejectsWith(viaLoopback("/redirect-same-server"), "invalid-url"); // port check on hop 2
  assert.equal(secretHits, 0);
});

test("redirects to other schemes or ports are rejected", async () => {
  await rejectsWith(viaLoopback("/redirect-to-file"), "invalid-url");
  await rejectsWith(viaLoopback("/redirect-odd-port"), "invalid-url");
});

test("too many redirects are rejected", async () => {
  await rejectsWith(viaLoopback("/redirect-same-server", { maxRedirects: 0 }), "upstream");
});

test("non-image, SVG and untyped responses are rejected", async () => {
  await rejectsWith(viaLoopback("/html"), "not-image");
  await rejectsWith(viaLoopback("/svg"), "not-image");
  await rejectsWith(viaLoopback("/no-type"), "not-image");
});

test("compressed responses are rejected, and only identity encoding is requested", async () => {
  await rejectsWith(viaLoopback("/gzip"), "upstream");
  const result = await viaLoopback("/echo-encoding");
  assert.deepEqual(result.buffer, PNG_BYTES);
});

test("the loopback test option can't be switched on by a plain string key", async () => {
  await rejectsWith(safeFetchImage(`${base}/image`, { _allowLoopbackForTests: true, allowLoopbackForTests: true }), "invalid-url");
  await rejectsWith(safeFetchImage("http://127.0.0.1/image", { allowLoopbackForTests: true }), "blocked");
});

test("a non-2xx response is an upstream error", async () => {
  await rejectsWith(viaLoopback("/not-found"), "upstream");
});

test("a declared Content-Length over the limit is rejected", async () => {
  await rejectsWith(viaLoopback("/declared-too-large"), "too-large");
});

test("a 9 MB chunked body with no Content-Length is rejected while streaming", async () => {
  // With no declared length, "too-large" can only come from the running
  // byte count, which stops reading as soon as it passes the limit.
  await rejectsWith(viaLoopback("/chunked-too-large", { maxBytes: 8 * MB }), "too-large");
});

test("a response that never finishes hits the overall deadline", async () => {
  const started = Date.now();
  await rejectsWith(viaLoopback("/slow", { timeoutMs: 300 }), "upstream");
  assert.ok(Date.now() - started < 3000);
});
