// Express 4 (unlike 5) does NOT automatically catch a rejected promise
// returned by an async route handler — an unhandled rejection there is just
// an unhandled rejection, and modern Node terminates the whole process on
// one by default. Every route in routes/auth.js, routes/me.js,
// routes/friends.js, and routes/groups.js is async and talks to Prisma, so
// a single dropped database connection or unexpected error could otherwise
// crash the server for every user, not just fail the one request. Wrapping
// each handler with this turns any thrown/rejected error into a normal
// `next(error)` call, caught by the generic error-handling middleware in
// index.js instead.
"use strict";

function asyncHandler(fn) {
  return (req, res, next) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}

module.exports = { asyncHandler };
