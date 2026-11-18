// Fetches a caller-supplied image URL without letting the caller use this
// server to reach anything internal (SSRF). Used by GET /recipes/image-proxy,
// whose `url` can name any host.
//
// Every hop is checked: redirects are followed by hand and re-validated, and
// the address check runs inside the socket's own DNS lookup, so the IP that
// was checked is the IP that gets connected to (a DNS answer can't change in
// between). The body is streamed and cut off at `maxBytes`, and only image
// content types are returned.
"use strict";

const dns = require("dns");
const http = require("http");
const https = require("https");
const net = require("net");

// Addresses this server must never fetch from on a caller's behalf.
const blockList = new net.BlockList();
for (const [network, prefix] of [
  ["0.0.0.0", 8], // "this network"
  ["10.0.0.0", 8], // private
  ["100.64.0.0", 10], // carrier-grade NAT, often platform-internal
  ["127.0.0.0", 8], // loopback
  ["169.254.0.0", 16], // link-local, including cloud metadata (169.254.169.254)
  ["172.16.0.0", 12], // private
  ["192.0.0.0", 24], // IETF protocol assignments
  ["192.168.0.0", 16], // private
  ["198.18.0.0", 15], // benchmarking
  ["224.0.0.0", 4], // multicast
  ["240.0.0.0", 4], // reserved, including broadcast 255.255.255.255
]) {
  blockList.addSubnet(network, prefix, "ipv4");
}
for (const [network, prefix] of [
  ["::", 96], // unspecified, loopback (::1) and deprecated IPv4-compatible forms
  ["::ffff:0:0:0", 96], // IPv4-translated (SIIT), which embeds an IPv4 address
  ["fc00::", 7], // unique local
  ["fe80::", 10], // link-local
  ["fec0::", 10], // deprecated site-local
  ["ff00::", 8], // multicast
  ["64:ff9b::", 96], // NAT64, which can wrap a private IPv4 address
  ["64:ff9b:1::", 48], // local-use NAT64
  ["2001::", 32], // Teredo, which embeds an IPv4 address
  ["2002::", 16], // 6to4, which embeds an IPv4 address
]) {
  blockList.addSubnet(network, prefix, "ipv6");
}

// The IPv4 address inside an IPv4-mapped IPv6 address (::ffff:0:0/96), in
// either the dotted (::ffff:1.2.3.4) or hex (::ffff:102:304) form, or null.
function mappedIPv4(ipv6) {
  const lower = ipv6.toLowerCase();
  const dotted = lower.match(/^(?:0{0,4}:){0,5}:?ffff:(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (dotted && net.isIPv4(dotted[1])) return dotted[1];
  const hex = lower.match(/^(?:0{0,4}:){0,5}:?ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  if (hex) {
    const high = parseInt(hex[1], 16);
    const low = parseInt(hex[2], 16);
    return [high >> 8, high & 0xff, low >> 8, low & 0xff].join(".");
  }
  return null;
}

// True if `ip` must not be fetched from. Anything that isn't a valid IP
// address counts as blocked.
function isBlockedAddress(ip) {
  if (typeof ip !== "string") return true;
  if (net.isIPv4(ip)) return blockList.check(ip, "ipv4");
  if (net.isIPv6(ip)) {
    const mapped = mappedIPv4(ip);
    if (mapped) return blockList.check(mapped, "ipv4");
    return blockList.check(ip, "ipv6");
  }
  return true;
}

class ProxyError extends Error {
  // `kind` is one of: "invalid-url", "blocked", "not-image", "too-large",
  // "upstream". The route maps each to a fixed response; nothing else about
  // the upstream server ever reaches the caller.
  constructor(kind, detail) {
    super(detail ? `${kind}: ${detail}` : kind);
    this.name = "ProxyError";
    this.kind = kind;
  }
}

const BLOCKED_ADDRESS_CODE = "E_IMAGE_PROXY_BLOCKED_ADDRESS";

// Drop-in replacement for dns.lookup, given to http(s).request as `lookup`.
// Fails if ANY address the name resolves to is blocked, then hands back
// exactly the address(es) it checked, so the socket connects to one of them.
// Handles both call shapes Node uses: `all: true` (Happy Eyeballs, the
// default from Node 20) expects an array, otherwise a single address.
function guardedLookup(hostname, options, callback) {
  const opts = typeof options === "number" ? { family: options } : { ...(options || {}) };
  const wantAll = Boolean(opts.all);
  dns.lookup(hostname, { ...opts, all: true }, (error, addresses) => {
    if (error) return callback(error);
    if (!addresses || addresses.length === 0 || addresses.some((entry) => isBlockedAddress(entry.address))) {
      const blocked = new Error(`Blocked address for ${hostname}`);
      blocked.code = BLOCKED_ADDRESS_CODE;
      return callback(blocked);
    }
    if (wantAll) return callback(null, addresses);
    return callback(null, addresses[0].address, addresses[0].family);
  });
}

const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

// Media type without parameters, lowercased: "image/png; q=1" -> "image/png".
function mediaType(contentTypeHeader) {
  return String(contentTypeHeader || "").split(";")[0].trim().toLowerCase();
}

// Checks one hop's URL before any connection is made.
function validateHop(url, { allowLoopback }) {
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new ProxyError("invalid-url", "scheme");
  }
  if (url.username || url.password) {
    throw new ProxyError("invalid-url", "credentials");
  }
  if (!allowLoopback && url.port !== "" && url.port !== "80" && url.port !== "443") {
    throw new ProxyError("invalid-url", "port");
  }
  // Node connects to a literal IP directly without calling `lookup`, so a
  // literal address has to be checked here.
  const host = url.hostname.replace(/^\[(.*)\]$/, "$1");
  if (net.isIP(host) && !allowLoopback && isBlockedAddress(host)) {
    throw new ProxyError("blocked", "literal address");
  }
  return host;
}

// One HTTP request for one hop. Resolves to { redirectTo } or
// { contentType, buffer }. The overall deadline is enforced by `signal`.
function requestOnce(url, host, { maxBytes, signal, allowLoopback }) {
  return new Promise((resolve, reject) => {
    const transport = url.protocol === "https:" ? https : http;
    const req = transport.request(
      {
        protocol: url.protocol,
        hostname: host,
        port: url.port || undefined,
        path: `${url.pathname}${url.search}`,
        method: "GET",
        // Ask for the raw bytes: http.request doesn't decompress, and a
        // compressed body would be passed on as a broken image.
        headers: { "user-agent": "HomeEatsImageProxy/1.0", accept: "image/*", "accept-encoding": "identity" },
        // The loopback allowance exists only for this module's own tests
        // (see ALLOW_LOOPBACK_FOR_TESTS below).
        lookup: allowLoopback ? dns.lookup : guardedLookup,
        // A fresh connection every time: a pooled socket would skip the
        // guarded lookup.
        agent: false,
        signal,
      },
      (res) => {
        const status = res.statusCode || 0;
        if (REDIRECT_STATUSES.has(status)) {
          const location = res.headers.location;
          res.resume();
          res.destroy();
          if (!location) return reject(new ProxyError("upstream", "redirect without location"));
          let next;
          try {
            next = new URL(location, url);
          } catch (error) {
            return reject(new ProxyError("blocked", "bad redirect location"));
          }
          return resolve({ redirectTo: next });
        }
        if (status < 200 || status >= 300) {
          res.resume();
          res.destroy();
          return reject(new ProxyError("upstream", `status ${status}`));
        }
        const encoding = String(res.headers["content-encoding"] || "identity").trim().toLowerCase();
        if (encoding !== "identity") {
          res.destroy();
          return reject(new ProxyError("upstream", `content-encoding ${encoding}`));
        }
        const type = mediaType(res.headers["content-type"]);
        if (!type.startsWith("image/") || type === "image/svg+xml") {
          res.destroy();
          return reject(new ProxyError("not-image"));
        }
        const declaredLength = Number(res.headers["content-length"]);
        if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
          res.destroy();
          return reject(new ProxyError("too-large"));
        }
        const chunks = [];
        let total = 0;
        let finished = false;
        res.on("data", (chunk) => {
          if (finished) return;
          total += chunk.length;
          if (total > maxBytes) {
            finished = true;
            req.destroy();
            reject(new ProxyError("too-large"));
            return;
          }
          chunks.push(chunk);
        });
        res.on("end", () => {
          if (finished) return;
          finished = true;
          resolve({ contentType: type, buffer: Buffer.concat(chunks, total) });
        });
        res.on("error", (error) => {
          if (finished) return;
          finished = true;
          reject(new ProxyError("upstream", error.message));
        });
        res.on("aborted", () => {
          if (finished) return;
          finished = true;
          reject(new ProxyError("upstream", "response aborted"));
        });
      }
    );
    req.on("error", (error) => {
      if (error instanceof ProxyError) return reject(error);
      if (error.code === BLOCKED_ADDRESS_CODE) return reject(new ProxyError("blocked", "resolved address"));
      // A name that doesn't exist is the caller's problem (400); a resolver
      // failure (EAI_AGAIN, timeouts) is ours, so it's an upstream error.
      if (error.code === "ENOTFOUND") return reject(new ProxyError("blocked", "unresolvable host"));
      reject(new ProxyError("upstream", error.message));
    });
    req.end();
  });
}

// Fetches an image from `rawURL`, following at most `maxRedirects`
// redirects, each re-validated. Resolves to { contentType, buffer } or
// rejects with a ProxyError. `timeoutMs` bounds the whole fetch, all hops
// included.
//
// Tests reach a local server by passing `[ALLOW_LOOPBACK_FOR_TESTS]: true`,
// which skips the address and port checks on the FIRST hop only (every
// redirect is still fully checked). It's a Symbol key, so it can't arrive
// from a query string, JSON body or environment variable. No route passes it.
const ALLOW_LOOPBACK_FOR_TESTS = Symbol("allowLoopbackForTests");

async function safeFetchImage(rawURL, options = {}) {
  const { maxBytes = 8 * 1024 * 1024, timeoutMs = 10_000, maxRedirects = 3 } = options;
  const allowLoopbackForTests = options[ALLOW_LOOPBACK_FOR_TESTS] === true;
  let url;
  try {
    url = new URL(rawURL);
  } catch (error) {
    throw new ProxyError("invalid-url", "unparseable");
  }

  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), timeoutMs);
  try {
    for (let hop = 0; hop <= maxRedirects; hop += 1) {
      const allowLoopback = allowLoopbackForTests && hop === 0;
      const host = validateHop(url, { allowLoopback });
      let result;
      try {
        // eslint-disable-next-line no-await-in-loop
        result = await requestOnce(url, host, { maxBytes, signal: controller.signal, allowLoopback });
      } catch (error) {
        if (error instanceof ProxyError) throw error;
        throw new ProxyError("upstream", error.message);
      }
      if (!result.redirectTo) return result;
      url = result.redirectTo;
    }
    throw new ProxyError("upstream", "too many redirects");
  } finally {
    clearTimeout(deadline);
  }
}

module.exports = { isBlockedAddress, guardedLookup, safeFetchImage, ProxyError, ALLOW_LOOPBACK_FOR_TESTS };
