// Home Eats backend entry point. The Express app itself (middleware and
// every route) is built in app.js; this file only connects to Postgres and
// starts listening. Keeping the two apart lets tests (see test/) import the
// app without opening a port or requiring a database at load time.
"use strict";

const { app } = require("./app");
const { prisma } = require("./lib/prisma");

const PORT = process.env.PORT || 4000;

// Connect to Postgres before accepting traffic, so a misconfigured
// DATABASE_URL fails loudly at startup (visible in Render's deploy logs)
// rather than on the first request that happens to touch the database.
// The restaurant/recipe routes in app.js don't use Prisma at all, so this
// only affects the accounts/friends/groups routes in practice.
prisma
  .$connect()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`Home Eats backend listening on port ${PORT}`);
    });
  })
  .catch((error) => {
    console.error("Failed to connect to the database:", error);
    process.exit(1);
  });
