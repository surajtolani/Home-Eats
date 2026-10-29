"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const dns = require("node:dns");
const { isBlockedAddress, guardedLookup } = require("../../lib/safeFetch");

test("isBlockedAddress blocks internal, reserved and malformed addresses", () => {
  for (const ip of [
    "127.0.0.1",
    "10.1.2.3",
    "100.64.0.1",
    "169.254.169.254",
    "172.16.0.1",
    "172.31.255.255",
    "192.168.1.1",
    "192.0.0.8",
    "198.18.0.1",
    "224.0.0.1",
    "240.0.0.1",
    "255.255.255.255",
    "0.0.0.0",
    "::",
    "::1",
    "::ffff:127.0.0.1",
    "::ffff:7f00:1",
    "0:0:0:0:0:ffff:7f00:1",
    "::ffff:a9fe:a9fe",
    "fd00::1",
    "fe80::1",
    "ff02::1",
    "64:ff9b::a00:1",
    "2002:a00:1::1",
    "::ffff:0:7f00:1",
    "::ffff:0:127.0.0.1",
    "not-an-ip",
    "",
    undefined,
  ]) {
    assert.equal(isBlockedAddress(ip), true, `${ip} should be blocked`);
  }
});

test("isBlockedAddress allows public addresses", () => {
  for (const ip of ["93.184.216.34", "8.8.8.8", "172.32.0.1", "2606:2800:220:1::1", "::ffff:5db8:d822"]) {
    assert.equal(isBlockedAddress(ip), false, `${ip} should be allowed`);
  }
});

function lookupWith(t, answers) {
  t.mock.method(dns, "lookup", (hostname, options, callback) => callback(null, answers));
}

test("guardedLookup rejects a name if any of its addresses is blocked", (t, done) => {
  lookupWith(t, [
    { address: "93.184.216.34", family: 4 },
    { address: "10.0.0.1", family: 4 },
  ]);
  guardedLookup("rebind.example", {}, (error) => {
    assert.ok(error);
    assert.equal(error.code, "E_IMAGE_PROXY_BLOCKED_ADDRESS");
    done();
  });
});

test("guardedLookup returns the checked address, in both call shapes", (t, done) => {
  lookupWith(t, [{ address: "93.184.216.34", family: 4 }]);
  guardedLookup("ok.example", { all: true }, (error, addresses) => {
    assert.equal(error, null);
    assert.deepEqual(addresses, [{ address: "93.184.216.34", family: 4 }]);
    guardedLookup("ok.example", {}, (error2, address, family) => {
      assert.equal(error2, null);
      assert.equal(address, "93.184.216.34");
      assert.equal(family, 4);
      done();
    });
  });
});
