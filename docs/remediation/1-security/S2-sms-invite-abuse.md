# S2 — SMS invite abuse (spam, phishing, toll fraud)

| | |
|---|---|
| Phase | 1 — Security |
| Severity | High |
| Depends on | S1 (durable limiter) |
| Size | M |
| Touches | `backend/lib/twilio.js`, `backend/routes/friends.js`, `backend/routes/groups.js`, `backend/routes/me.js`, `backend/routes/groups.js` (create/rename schema), tests |

## Problem

Any signed-in user can make the server text **any** E.164 phone number, with
no limit:
- `POST /friends/request` with an unregistered number → `sendInviteSMS`
  (`routes/friends.js:285`)
- `POST /groups/:groupId/invite` with an unregistered number →
  `sendInviteSMS` (`routes/groups.js:544`)

The SMS body includes text the sender controls: their `displayName` (up to
100 characters) and, for group invites, the group `name` (up to 200
characters, and the sender can rename the group at will). An attacker can:
1. **Phish or spam** from your registered 10DLC number, e.g. a group named
   "Your bank account is locked, verify at evil.example". That puts your A2P
   campaign registration at risk and gets your number filtered.
2. **Pump traffic** to premium or international numbers (SMS toll fraud).
   Accounts only cost one SMS verification to create.
3. **Harass** one number repeatedly: create a group, invite, delete the
   group, repeat. The "already invited" check only covers PENDING invites
   from the same inviter for the same group.

## Goal

Invite SMS can't be used to deliver attacker-written text, and volume is
capped per sender, per recipient, and globally.

## Acceptance criteria

- [ ] Invite SMS bodies are a **fixed template**. The only variable text is
      the sender's display name, sanitized (rules below). The group name is
      never included.
- [ ] Per-sender cap: at most **5 invite SMS per rolling 24 h** and
      **20 per 30 days** per user (`failClosed`).
- [ ] Per-recipient cap: any one phone number gets at most **1 invite SMS per
      7 days**, across *all* senders (`failClosed`).
- [ ] Global circuit breaker: at most `INVITE_SMS_DAILY_GLOBAL_MAX`
      (default 200) invite SMS per UTC day across the whole deployment. Over
      that, log an error and skip the send.
- [ ] Country allow-list: only send to country codes in
      `INVITE_SMS_ALLOWED_COUNTRY_CODES` (default `"1"`, i.e. US and Canada).
      Comma-separated digits matched against the E.164 prefix.
- [ ] When any cap blocks the SMS, the **invite row is still created** and
      the API response is **unchanged**. The SMS is a courtesy, and the
      response must not reveal whether a text was sent, so it can't be used
      as an oracle.
- [ ] Tests cover each cap, the sanitizer, and the template.

## Steps

1. **Sanitizer** in `backend/lib/twilio.js`:
   ```js
   // Strip anything that could carry a link or look like one, so a display
   // name can't smuggle a phishing URL into an SMS we send.
   function sanitizeNameForSMS(raw) { ... }
   ```
   Rules, in this order:
   - NFKC-normalize, then strip control and format characters (`\p{C}`).
   - Remove every character except letters, marks, spaces, `'`, `-`, and `.`
     (`/[^\p{L}\p{M} '.-]/gu`).
   - Then remove any `.` that sits between two letters, so `evil.com` becomes
     `evilcom` and domains can't render as links.
   - Collapse whitespace, trim, and cap at **30 characters**.
   - If the result is empty, use `"A friend"`.
2. **Fixed templates** in `lib/twilio.js`, replacing the free-form `message`
   argument to `inviteSMSBody`:
   - `friendInviteSMS(senderName)` →
     `"<name> invited you to Home Eats, a family meal-planning app."`
   - `groupInviteSMS(senderName)` →
     `"<name> invited you to plan meals together on Home Eats."`
   - Both still go through the existing download-link and
     `"Reply STOP to opt out."` suffix logic.
3. **Caps.** Create the limiters with `createRateLimiter` from S1, all
   `failClosed: true`:
   - `invite-sms:sender-day` (24 h, 5) keyed by `req.userId`
   - `invite-sms:sender-month` (30 d, 20) keyed by `req.userId`
   - `invite-sms:recipient` (7 d, 1) keyed by the recipient's E.164 number
   - `invite-sms:global` (24 h, `INVITE_SMS_DAILY_GLOBAL_MAX`) keyed by
     `"all"`

   Add `async function trySendInviteSMS({ senderUserId, senderName, to, kind })`
   to `lib/twilio.js` that:
   1. checks the country allow-list;
   2. checks the recipient limiter, then the sender limiters, then the
      global one (all must pass);
   3. builds the template;
   4. calls `sendInviteSMS`;
   5. logs `[invite-sms] sent|skipped reason=<...> sender=<userId>
      to=<hashed>`. Use S6's hash helper if it has landed; otherwise log only
      the last 4 digits.
4. **Call sites.** In `routes/friends.js` and `routes/groups.js`, replace the
   `sendInviteSMS({ to, body: inviteSMSBody(...) })` calls with
   `trySendInviteSMS(...)`. Keep them after the transaction, fire-and-forget
   as they are today. Pass `me.displayName`, **never** `me.phoneNumber` (see
   S6).
5. **Environment.** Add `INVITE_SMS_DAILY_GLOBAL_MAX` and
   `INVITE_SMS_ALLOWED_COUNTRY_CODES` to `.env.example` and the README's
   SMS-invite section.
6. **Consent page.** `/sms-consent` (`smsConsentHtml()` in `index.js`) shows
   the message wording. Update it to the new fixed template so it matches
   what the A2P campaign declares.
7. **Tests:**
   - Unit: the sanitizer turns `"Bob visit evil.com/x"` into
     `"Bob visit evilcomx"`; a name made only of emoji becomes
     `"A friend"`; output length is ≤ 30.
   - Integration: the 6th friend-request SMS in 24 h from one user is
     skipped while the response is still 200 and the Invite row exists. A
     second invite to the same number from a different user within 7 days is
     skipped. A `+44` number with the default allow-list is skipped.
   - Stub Twilio by setting `TWILIO_SMS_FROM_NUMBER` unset, or by injecting a
     fake client. Expose a small seam in `lib/twilio.js`, e.g.
     `module.exports.__setClientForTests`.

## [HUMAN] steps

- In the Twilio Console → Messaging → **Geo permissions**, disable every
  country you don't serve. Do the same under Verify → **Geo permissions** for
  sign-in codes.
- Turn on Verify **Fraud Guard** (SMS pumping protection) at its strictest
  setting.
- Set a Twilio **usage trigger** (Console → Usage → Triggers) that emails you
  at a daily spend threshold.
- Resubmit or update the A2P campaign's sample message if the template text
  changes from what was registered.

## Out of scope

- Moving SMS sending to a queue or worker.
- Changing push notification text (S6 handles phone-number fallbacks there).
