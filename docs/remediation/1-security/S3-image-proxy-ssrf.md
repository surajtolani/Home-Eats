# S3 — Image proxy SSRF hardening

| | |
|---|---|
| Phase | 1 — Security |
| Severity | Medium |
| Depends on | S0 |
| Size | M |
| Touches | `backend/index.js` (or `app.js`) `GET /recipes/image-proxy`, new `backend/lib/safeFetch.js`, tests |

## Problem

`GET /recipes/image-proxy?url=...` (`index.js:1242`) fetches any URL the
caller supplies. It needs no login. It guards against internal targets by
resolving the hostname and rejecting private IPs (`isPrivateOrLoopbackIP`,
`index.js:145`), but:

1. **Redirects bypass the check.** `fetch(parsed.toString(), ...)`
   (`index.js:1272`) uses the default `redirect: "follow"`. An external URL
   that returns `302 Location: http://169.254.169.254/...` or
   `http://10.x.x.x/` is followed without re-validation.
2. **DNS rebinding.** The IP is checked at lookup time, but `fetch` resolves
   the name again. An attacker's DNS can answer "public" first and "private"
   second.
3. **Incomplete block list.** Missing ranges include 100.64.0.0/10 (CGNAT,
   often used for platform-internal networks), 192.0.0.0/24, 198.18.0.0/15,
   224.0.0.0/4, 240.0.0.0/4, 255.255.255.255, `::`, and IPv4-mapped IPv6 in
   hex form (`::ffff:7f00:1`), plus other IPv6 forms (`64:ff9b::/96`,
   `2002::/16` wrapping private IPv4).
4. **Unbounded read.** `await imageResponse.arrayBuffer()` reads the whole
   body before checking its size when there's no `Content-Length` header
   (chunked responses), so a large stream can exhaust memory.
5. **Open bandwidth proxy.** No login and 600 requests per hour per IP at up
   to 8 MB each. Login is added in S4. This plan makes the fetch itself safe.

## Goal

A reusable `safeFetchImage(url)` that validates **every** hop and the
**actual connected IP**, enforces a streaming size cap and timeout, and only
returns image bytes.

## Acceptance criteria

- [ ] New `backend/lib/safeFetch.js` exporting
      `isBlockedAddress(ip)` and `safeFetchImage(url, { maxBytes, timeoutMs, maxRedirects })`.
- [ ] Redirects are followed **manually**, at most 3, and each `Location` is
      re-parsed (http/https only) and re-validated.
- [ ] The IP is validated **at connect time** via a custom `lookup` passed to
      Node's `http`/`https` request, so rebinding can't swap the address
      between check and connect.
- [ ] The block list uses `net.BlockList` and covers every range listed in
      the Problem section, plus normalization of IPv4-mapped IPv6.
- [ ] The body is streamed and aborted as soon as it exceeds `maxBytes`
      (8 MB), regardless of headers.
- [ ] The response must have an `image/*` content type, excluding
      `image/svg+xml` (SVG can carry script if anyone ever opens it in a web
      view).
- [ ] Ports are limited to 80 and 443.
- [ ] The route returns the same opaque errors as today: no upstream
      headers, bodies, or error details reach the caller.
- [ ] Unit tests for `isBlockedAddress`. Integration tests using a local HTTP
      server that redirects to `127.0.0.1` → rejected.

## Steps

1. **Create `lib/safeFetch.js`.**
   - Build a `net.BlockList` with: IPv4 `0.0.0.0/8`, `10.0.0.0/8`,
     `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`,
     `192.0.0.0/24`, `192.168.0.0/16`, `198.18.0.0/15`, `224.0.0.0/4`, and
     `240.0.0.0/4` (which includes 255.255.255.255). IPv6 `::/128`, `::1/128`,
     `fc00::/7`, `fe80::/10`, `ff00::/8`, `64:ff9b::/96`, and `2002::/16`.
   - `isBlockedAddress(ip)`: if the address is IPv6 and in `::ffff:0:0/96`,
     extract the embedded IPv4 (handling both dotted `::ffff:1.2.3.4` and hex
     `::ffff:0102:0304` forms) and check that against the IPv4 list. Anything
     that isn't a valid IP returns `true`.
   - `guardedLookup(hostname, options, callback)`: call `dns.lookup` with
     `{ all: true }`. If **any** answer is blocked, call back with an error.
     Otherwise call back with the first answer, which is the address the
     socket will actually connect to.
   - `safeFetchImage(url, opts)`: loop up to `maxRedirects + 1` times:
     - Parse the URL. Require http/https and port 80/443 or empty.
     - Issue the request with `http.request` or `https.request`, passing
       `{ lookup: guardedLookup, timeout: timeoutMs, headers: { 'user-agent': 'HomeEatsImageProxy/1.0', accept: 'image/*' } }`.
     - On 301, 302, 303, 307, or 308: read `Location`, resolve it against the
       current URL, drain and destroy the response, and continue the loop.
     - On non-2xx: throw `ProxyError('upstream')`.
     - Check `content-type` (image/*, not svg). Check `content-length` if
       present.
     - Stream chunks into an array, tracking total bytes, and
       `req.destroy()` the moment the total exceeds `maxBytes`.
     - Return `{ contentType, buffer }`.
   - Use an `AbortController` or `setTimeout` as an overall deadline (10 s),
     covering all hops.
2. **Rewire the route.** Replace the body of `GET /recipes/image-proxy` after
   URL parsing with a call to `safeFetchImage` and a mapping of errors to the
   existing 400/413/502 responses. Delete the old `dns.lookup` pre-check and
   `isPrivateOrLoopbackIP` once nothing references it (grep first).
3. **Tests:**
   - `test/unit/safeFetch.test.js`: blocked: `127.0.0.1`, `10.1.2.3`,
     `100.64.0.1`, `169.254.169.254`, `::1`, `::ffff:127.0.0.1`,
     `::ffff:7f00:1`, `fd00::1`, `0.0.0.0`, `not-an-ip`. Allowed:
     `93.184.216.34`, `2606:2800:220:1::1`.
   - `test/integration/imageProxy.test.js`: there's a catch-22 because the
     test server is on 127.0.0.1, which the guard blocks. Export a test-only
     option `safeFetchImage(url, { _allowLoopbackForTests: true })` used
     **only** to reach the first hop, then assert that a redirect from that
     server to `http://127.0.0.1:<port>/secret` is rejected. Keep the option
     non-reachable from HTTP input.
   - Oversized chunked body (9 MB, no `Content-Length`) → rejected, and the
     process doesn't buffer all 9 MB (assert on the error type only).
   - `text/html` response → 400. `image/svg+xml` → 400.

## Verification

```bash
npm test
# manual, with server running locally:
curl -i 'http://localhost:4000/recipes/image-proxy?url=http://127.0.0.1:4000/health'   # 400
curl -i 'http://localhost:4000/recipes/image-proxy?url=https://httpbin.org/redirect-to?url=http://169.254.169.254/'  # 400
```

## Out of scope

- Requiring login on this route (S4).
- Caching proxied images (R1).
