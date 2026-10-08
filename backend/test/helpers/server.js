// Shared setup for integration tests. These run the real Express app (see
// app.js) against a throwaway Postgres named by TEST_DATABASE_URL, and are
// skipped when it isn't set so `npm test` still works with no database.
"use strict";

const crypto = require("node:crypto");
const jwt = require("jsonwebtoken");

const TEST_JWT_SECRET = "home-eats-test-secret";

// Returns null when no test database is configured. Environment variables
// must be set before app.js (and through it, lib/prisma.js) is first
// required, because PrismaClient reads DATABASE_URL when it's constructed.
async function startTestServer() {
  if (!process.env.TEST_DATABASE_URL) return null;
  process.env.DATABASE_URL = process.env.TEST_DATABASE_URL;
  process.env.JWT_SECRET = TEST_JWT_SECRET;

  const { app } = require("../../app");
  const { prisma } = require("../../lib/prisma");

  const server = await new Promise((resolve) => {
    const s = app.listen(0, () => resolve(s));
  });
  const { port } = server.address();

  return {
    baseURL: `http://127.0.0.1:${port}`,
    async close() {
      await new Promise((resolve) => server.close(resolve));
      await prisma.$disconnect();
    },
  };
}

// Same payload shape and options as signToken in routes/auth.js.
function signTestToken(userId, tokenVersion = 0) {
  return jwt.sign({ userId, tokenVersion }, TEST_JWT_SECRET, { expiresIn: "30d" });
}

function randomPhoneNumber() {
  // +1 followed by 10 digits, first digit 2-9 so it's a plausible NANP number.
  const digits = String(crypto.randomInt(2_000_000_000, 10_000_000_000));
  return `+1${digits}`;
}

async function createTestUser(overrides = {}) {
  const { prisma } = require("../../lib/prisma");
  return prisma.user.create({
    data: { phoneNumber: randomPhoneNumber(), ...overrides },
  });
}

// Empties every table backing a Prisma model. Table names come from the
// generated client's own schema metadata, never from request input, so
// building the statement with $executeRawUnsafe is safe here; identifiers
// can't be passed as bound parameters.
async function resetDatabase() {
  const { prisma } = require("../../lib/prisma");
  const { Prisma } = require("@prisma/client");
  const tables = Prisma.dmmf.datamodel.models
    .map((model) => `"${model.dbName || model.name}"`)
    .join(", ");
  await prisma.$executeRawUnsafe(`TRUNCATE ${tables} RESTART IDENTITY CASCADE`);
}

module.exports = { startTestServer, signTestToken, createTestUser, resetDatabase };
