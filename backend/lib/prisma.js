// A single shared PrismaClient instance, reused across every request and
// route file. Same reasoning as the `const anthropic = new Anthropic();`
// line in index.js — Prisma is designed to be instantiated once per process
// (it manages its own connection pool internally) rather than constructed
// per-request, which would open a fresh pool on every call.
//
// PrismaClient reads `DATABASE_URL` itself (see the `url = env("DATABASE_URL")`
// line in prisma/schema.prisma) — nothing here needs to touch it directly.
"use strict";

const { PrismaClient } = require("@prisma/client");

const prisma = new PrismaClient();

module.exports = { prisma };
