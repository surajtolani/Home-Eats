# Home Eats: Getting Ready for the App Store

**A plain-English guide to what needs fixing, and how to fix it phase by phase with Claude Code.**

This guide is for you if you own or manage Home Eats but don't write code
yourself. It explains:

1. What the problems are and why they matter, in plain language.
2. How the work is split into three phases.
3. Exactly what to type into Claude Code to get each fix done.
4. How to keep each phase separate, so you can test it on its own and
   undo it if something goes wrong.
5. The tasks only a person can do (account settings, billing, App Store
   forms).

The detailed technical instructions Claude follows live in the
[plans index](README.md) and the files it links to. You don't need to read
those. Claude does.

---

## Part 1: Quick glossary

| Term | What it means here |
|---|---|
| **Backend / server** | The computer program that runs on the internet (on a hosting service called **Render**). It handles sign-in, sharing, groups, and talking to Google and Anthropic. The iPhone app talks to it constantly. |
| **Database** | Where the server stores everyone's accounts, recipes, groups, meal plans, and grocery lists. It's a **PostgreSQL** database. |
| **Repository (repo)** | The project's code on GitHub: `surajtolani/Home-Eats`. |
| **Branch** | A separate copy of the code where changes can be made safely without affecting the live app. Think of it as a draft. |
| **Main branch** | The "official" version of the code that the live server runs. In this repo it's currently named `claude/app-creation-qn2e51`. This guide calls it **the main branch**. |
| **Pull request (PR)** | A proposal to merge one branch's changes into another. GitHub shows exactly what changed, and you click **Merge** to accept it. |
| **Merge** | Accepting a pull request so its changes become part of the target branch. |
| **TestFlight** | Apple's tool for installing test versions of the app on real phones before release. |
| **[HUMAN] step** | Something Claude can't do for you, like changing a setting in an online dashboard or filling in an App Store form. |

---

## Part 2: What's wrong, in plain English

### Security problems (fix first)

| # | Problem | Why it matters |
|---|---|---|
| 1 | **Anyone with an account can make our server text any phone number, as many times as they like,** and the text can include words they choose (their name or a group name). | Scammers could send phishing texts that come from *your* number. You pay for every text, and phone carriers can block your number or cancel your SMS registration. |
| 2 | **The "spam brakes" forget everything whenever the server restarts.** The limits on how often someone can request sign-in codes, use AI features, and so on are kept in short-term memory. | After every update or restart, an attacker gets a fresh allowance. It's like a bouncer who forgets every face at midnight. |
| 3 | **The recipe-picture loader can be tricked into fetching things from inside our hosting network.** | That's a known attack (called "SSRF") used to probe private systems. It also lets anyone on the internet use our server as a free image downloader. |
| 4 | **Some features that cost money don't require sign-in or limit request size.** Restaurant photos cost money per view from Google. AI features accept unlimited amounts of text. | Someone could run up a large Google or Anthropic bill. |
| 5 | **Signing out doesn't fully sign you out.** The phone keeps getting that person's notifications, and there's no "sign out of all devices" if a phone is lost or a login is stolen. | Privacy: the next person using that phone sees someone else's alerts, and a stolen login stays valid for 30 days. |
| 6 | **Phone numbers show up in server logs and, sometimes, in messages sent to other people.** | Unnecessary exposure of personal information. |

**Is the database safe from "SQL injection" (a common hacking technique)?**
Yes, largely. The app uses a tool called Prisma that keeps user input
separate from database commands, every input is checked before it reaches
the database, and there's no hand-written database code. The plans include
a rule to keep it that way.

### App Store blockers (fix before submitting 1.0)

| # | Problem | Why Apple cares |
|---|---|---|
| 7 | **There's no way to delete your account in the app.** | Apple **requires** this for any app with accounts, and our privacy policy already claims it exists. |
| 8 | **Apple's reviewers can't sign in.** Sign-in needs an SMS code sent to your phone, which reviewers can't receive. | The app gets rejected as "unable to review". |
| 9 | **The privacy declarations are wrong.** The app tells Apple it collects no data, but it collects phone numbers, names, location, photos, and more. There's also no privacy policy link inside the app. | Apple checks these, and an inaccurate declaration means rejection (and possible legal exposure). |
| 10 | **Sign-up demands more personal information than needed** (full name, city, state, country) before you can use anything. | Apple rejects apps that require unnecessary personal data. |
| 11 | **Users can publish recipes everyone sees, but there's no way to block people, no filter for offensive words, and no way to take down reported content.** | Apple **requires** all of these for apps with user-posted content. |
| 12 | **The app claims to support iPad but has no iPad design.** | Reviewers test on iPad, and a stretched or awkward layout leads to rejection. Shipping iPhone-only for 1.0 avoids this. |
| 13 | **The server may "fall asleep"** if it's on a free hosting plan, making the first sign-in take up to a minute. | If a reviewer sees a spinning wheel, that's a rejection. |
| 14 | **The server isn't sturdy enough yet.** It doesn't shut down cleanly during updates, one unexpected error can crash it, it waits forever on slow outside services, and some lists grow without limit. **We also don't know if the database is backed up.** | Outages and possible permanent data loss. |
| 15 | **Small build settings are out of date** (an old insecure-network setting, an older build tool, version still 0.1.0). | Apple flags these, and they're quick to fix. |
| 16 | **A future app update could wipe the data stored only on users' phones** (personal meal plans, grocery lists), because there's no "upgrade path" for the on-phone database. | Real users losing their data after an update is a support and reputation disaster. It must be set up *before* 1.0 ships. |

### Improvements after launch (Phase 3)

| # | Improvement | Benefit |
|---|---|---|
| 17 | Store recipe photos in proper file storage, and load the recipe library in pages. | The library stays fast as users grow, and the database stays small. |
| 18 | A separate test server ("staging"). | Test changes without touching real users' data. |
| 19 | Automatic tests on every change. | Problems are caught before they reach users. |
| 20 | Tidy up the server code. | Faster, safer future changes. |
| 21 | Use cheaper AI models where they're good enough. | Lower monthly costs. |
| 22 | Let people use the app without an account (guest mode). | Easier first experience. Also removes an App Store risk. |
| 23 | Better logging and error tracking. | Problems get found and fixed faster. |

---

## Part 3: The three phases

| Phase | What's in it | When | Goes live when |
|---|---|---|---|
| **Phase 1: Security** | Items 1–6 (7 tasks: S0–S6) | First | You merge the Phase 1 branch |
| **Phase 2: App Store 1.0** | Items 7–16 (10 tasks: A1–A10) | After Phase 1 | You merge the Phase 2 branch, then submit to Apple |
| **Phase 3: After launch** | Items 17–23 (7 tasks: R1–R7) | Any time after 1.0 | Each task can be merged when ready |

Each task has a short code (like **S2** or **A1**). You'll use these codes
when talking to Claude.

---

## Part 4: How phases stay separate

We use one **phase branch** per phase. Every task in that phase is built on
its own small branch, reviewed, and merged into the phase branch. **Nothing
reaches the live server or the App Store until you merge the whole phase
branch into the main branch.** That means:

- You can test a whole phase before anyone else sees it.
- If a phase causes trouble after you merge it, it can be undone as one
  unit.
- Phase 2 builds on top of Phase 1, so you always finish (and merge) one
  phase before starting the next.

```
main branch ──●────────────────────────●──────────────────────────●──▶
              │ tag: before-phase-1    ▲ merge Phase 1            ▲ merge Phase 2
              ▼                        │                          │
       phase-1-security ──●──●──●──●───┘                          │
                          S0 S1 S2 ...                            │
                                       ▼                          │
                                phase-2-app-store ──●──●──●──●────┘
                                                    A1 A2 A3 ...
```

> **Before you start, a [HUMAN] check:** in the Render dashboard, open the
> web service → **Settings** → **Build & Deploy** and note which **branch**
> it deploys from. It should be the main branch. If it's set to deploy from
> some other branch, tell Claude before starting. The whole "nothing goes
> live until you merge the phase" promise depends on this.

---

## Part 5: How to use Claude Code for this

You'll run everything from **Claude Code on the web** (claude.ai/code) or
the Claude app.

**General rules:**

1. **Start a fresh Claude Code session for each task.** Choose the
   `Home-Eats` repository when starting it. A fresh session per task keeps
   things focused and avoids mix-ups.
2. **Copy the prompts below exactly.** Only change the parts in
   `<angle brackets>`.
3. **Do the tasks in order.** Several tasks depend on earlier ones.
4. **When Claude finishes a task,** it gives you a pull request link. Open
   it, read Claude's summary, and check the **"Needs a human"** section for
   anything you need to do.
5. **Wait for the green check.** On each pull request, GitHub runs automatic
   checks. A green ✓ means the code builds. A red ✗ means something's wrong:
   ask Claude in the same session to fix it ("The checks on the PR failed,
   please fix them").
6. **Then click Merge** on the pull request (it merges into the phase
   branch, not the live app).

### Prompt A: Start a phase (once per phase)

Paste this into a new session. Replace `<N>` and `<phase-branch-name>`:

| Phase | `<N>` | `<phase-branch-name>` |
|---|---|---|
| 1 | 1 | `phase-1-security` |
| 2 | 2 | `phase-2-app-store` |
| 3 | 3 | `phase-3-post-launch` |

```text
I'm starting Phase <N> of the Home Eats remediation plans in docs/remediation/.
Please:
1. Create a git tag named before-phase-<N> on the current main branch
   (claude/app-creation-qn2e51) and push the tag.
2. Create a new branch named <phase-branch-name> from the main branch and push it.
Don't change any files. Tell me when both are done.
```

### Prompt B: Do one task (repeat for each task in the phase)

Paste this into a **new** session for each task. Replace `<TASK>` with the
task code (e.g. `S0`) and `<phase-branch-name>` as above:

```text
Implement remediation plan <TASK> from docs/remediation/.
First read docs/remediation/README.md (especially "Conventions for agents"),
then read the plan file for <TASK> and follow it exactly.

Isolation rules:
- Base your work on the branch <phase-branch-name> (fetch it first).
- Create a new branch named claude/<TASK in lowercase>-<short-description> from it.
- Only make the changes that plan <TASK> describes. Note anything else you
  notice under "Follow-ups" in the PR description instead of fixing it.
- When done and checks pass, open a pull request INTO <phase-branch-name>
  (not into the main branch).

In the pull request description, include:
1. A plain-English summary I can understand (no jargon).
2. The plan's acceptance checklist, ticked.
3. A "Needs a human" section listing every [HUMAN] step from the plan,
   written as simple instructions for me.
Then watch the pull request and fix any failing checks.
```

### Prompt C: Check a task's work before merging (optional, recommended for big tasks)

Use it in the same session after Claude opens the PR. It's worth doing on
S2, S3, S4, A1, A5, and A10.

```text
Before I merge, please review your own pull request for bugs and security
problems with /code-review, fix anything real you find, and then give me a
two-sentence plain-English summary of what changed and anything I should
test by hand.
```

### Prompt D: Finish a phase (once all its tasks are merged)

```text
All tasks for Phase <N> are merged into <phase-branch-name>.
Please:
1. Bring in any new changes from the main branch (claude/app-creation-qn2e51)
   and resolve conflicts if any.
2. Open a pull request from <phase-branch-name> into the main branch titled
   "Phase <N>: <phase name>".
3. In the description, give me a plain-English summary of everything in this
   phase, a combined list of every "Needs a human" step from all its tasks,
   and a short testing checklist for me to run on TestFlight.
Don't merge it. I'll merge after testing.
```

**When you merge this pull request, the phase goes live** (the server
updates automatically). For the iPhone side, you or Claude also need to
produce a new TestFlight build (see "Releasing the iPhone app" below).

### Prompt E: Undo a phase (only if something goes badly wrong)

```text
Phase <N> was merged into the main branch and is causing problems.
Please open a pull request that reverts the Phase <N> merge commit on the
main branch (use git revert, don't rewrite history), and tell me in plain
English whether any database changes from this phase need special handling.
```

> **Important about undoing:** undoing the code doesn't automatically undo
> **database changes**. Phases 1 and 2 include some database structure
> changes (S1, A1, A4, A5). These are designed to be harmless if the code is
> rolled back, but **always ask Claude** (as in the prompt above) before
> reverting, and never delete database data by hand.

---

## Part 6: Phase-by-phase checklists

Tick these off as you go. Each line is one run of **Prompt B** (one
session, one pull request).

### Phase 1: Security

Start with **Prompt A** (N = 1, branch `phase-1-security`).

| ✓ | Task | What it fixes (plain English) | Things only you can do |
|---|---|---|---|
| ☐ | **S0** | Adds automatic tests to the server so later fixes can be checked. | — |
| ☐ | **S1** | Makes the "spam brakes" remember limits even after a restart. | — |
| ☐ | **S2** | Stops strangers using our server to text anyone. Texts become a fixed, safe message with daily limits. | **Twilio:** turn off countries you don't serve (Geo permissions), turn on Fraud Guard, set a daily spend alert. |
| ☐ | **S3** | Closes the picture-loader security hole. | — |
| ☐ | **S4** | Requires sign-in for paid features, limits request sizes, adds daily usage caps. | **Google Cloud:** restrict each API key to only the services it needs, set daily quotas and a budget alert. **Anthropic Console:** set a monthly spend limit. |
| ☐ | **S5** | Sign-out really signs out; adds "Sign out of all devices". | — |
| ☐ | **S6** | Removes phone numbers from logs and from messages to others. | — |

Finish with **Prompt D**, test (see below), then merge.

**Test Phase 1 on TestFlight before merging:**
- Sign in, sign out, and sign back in. After signing out, the phone should
  get no more notifications for that account.
- Try "Sign out of all devices" on one phone, and confirm another phone
  signed into the same account is signed out too.
- Invite a friend by phone number. The text they get should be the new
  fixed message.
- Recipe and restaurant photos still load.
- AI recipe import (photo and typed notes) still works.

### Phase 2: App Store 1.0

Start with **Prompt A** (N = 2, branch `phase-2-app-store`).

| ✓ | Task | What it fixes (plain English) | Things only you can do |
|---|---|---|---|
| ☐ | **A1** | Adds **Delete Account** in Settings. | Add "Settings → Delete Account" to the App Review notes. |
| ☐ | **A2** | Gives Apple reviewers a special login that doesn't need an SMS. | **Render:** set the review phone number and code. Run the "seed review account" command Claude gives you. **App Store Connect:** enter the reviewer login details. |
| ☐ | **A3** | Makes the privacy declarations and policy accurate, and adds in-app Privacy and Terms links. | **App Store Connect:** fill in the App Privacy questionnaire to match what Claude lists. Set a non-personal contact email (e.g. privacy@yourdomain). |
| ☐ | **A4** | Sign-up only asks for a display name. | Add one sentence to the App Review notes explaining why an account is needed (Claude will draft it). |
| ☐ | **A5** | Adds Block User, an offensive-word filter, automatic hiding of reported recipes, and a way to remove content. | Create a Slack or Discord alert channel for reports. **Commit to checking reports daily** (Apple expects action within 24 hours). |
| ☐ | **A6** | Ships as iPhone-only for now. | Confirm no iPad version was ever *publicly released* (TestFlight doesn't count). Upload iPhone screenshots only. |
| ☐ | **A7** | Keeps the server awake and responsive, with friendly "can't connect" messages. | **Render:** upgrade the web service to a paid plan so it never sleeps, and set the health check path Claude gives you. |
| ☐ | **A10** | Makes the server sturdier: clean restarts, timeouts, crash protection, size limits on lists. | **Render:** find out where the database lives (Claude explains how), make sure it's on a paid plan **with backups**, and do one test restore. |
| ☐ | **A8** | Updates build settings and version to 1.0.0. | Build the final version with the latest Xcode (or ask a developer). |
| ☐ | **A9** | Makes sure future updates won't wipe users' on-phone data. | Install the current TestFlight build, add some data, then install the new build over it and confirm the data is still there. |

Finish with **Prompt D**, test (see below), then merge. **Then submit to
Apple.**

**Test Phase 2 on TestFlight before merging:**
- Create a test account, add a recipe and a group, then **delete the
  account**. Signing in again with the same number should give a fresh,
  empty account.
- Sign in with the **reviewer login** on a phone that's never seen your SMS
  codes.
- Settings shows Privacy Policy and Terms links, and both open.
- Sign-up only asks for a display name.
- Publish a recipe, then block its author from a second account. Their
  recipes should disappear from your library.
- Turn on Airplane Mode and try to sign in. You should see a friendly "can't
  reach Home Eats" message, not a freeze.
- Your existing meal plans and grocery lists are still there after
  updating.

**Before you press Submit for Review**, confirm every [HUMAN] item in the
Phase 2 table is done, especially **A2** (reviewer login), **A3** (privacy
questionnaire), and **A7/A10** (paid server and database).

### Phase 3: After launch

These are independent improvements. You can start a phase branch with
**Prompt A** (N = 3, branch `phase-3-post-launch`) and do them in any order
(**R3 before R4** is the one rule), or, because they're lower-risk, merge
each one separately.

| ✓ | Task | Improvement | Things only you can do |
|---|---|---|---|
| ☐ | **R1** | Photos move to file storage, and the library loads in pages. | Pick a storage provider (e.g. Cloudflare R2 or AWS S3), create a bucket, and add its keys to Render. |
| ☐ | **R2** | Separate test server and database. | Create the staging service and database on Render. |
| ☐ | **R3** | Automatic tests run on every change. | — |
| ☐ | **R4** | Tidies up server code. | — |
| ☐ | **R5** | Cheaper AI models where quality allows. | Review Claude's quality comparison table before merging. |
| ☐ | **R6** | Guest mode (use without an account). | Try the guest experience yourself before merging. |
| ☐ | **R7** | Better logs and error tracking. | Decide whether to use an error-tracking service (e.g. Sentry). |

---

## Part 7: Releasing the iPhone app

The server updates itself when a phase is merged. The **iPhone app does
not**: someone has to build and upload it. You can ask Claude to prepare
for that:

```text
Phase <N> is merged into the main branch. Please bump CURRENT_PROJECT_VERSION
in project.yml by 1 (and confirm MARKETING_VERSION is correct), open a pull
request for it, and then give me step-by-step instructions for archiving
and uploading the build to TestFlight from Xcode.
```

The actual archive and upload must be done in **Xcode on a Mac** by you or a
developer. Claude can't run Xcode in its cloud environment.

---

## Part 8: If something goes wrong

| Situation | What to do |
|---|---|
| A pull request has a red ✗ | In the same Claude session: "The checks on the pull request failed, please investigate and fix." |
| Claude seems to be doing more than the task | Say: "Please only do what plan `<TASK>` describes; list the rest as follow-ups." |
| You don't understand a change | Ask: "Explain this pull request to me as if I'm not technical." |
| The live app breaks right after a phase merge | Use **Prompt E** to undo the phase, then start a new session to investigate. |
| Two task branches conflict | In the later task's session: "Please bring in the latest `<phase-branch-name>` and resolve the conflicts." |
| You're not sure whether a [HUMAN] step was done | Ask Claude: "Check the server's /health endpoint and tell me which integrations are configured." (After A7, that needs the health token, so share it with Claude in the session.) |

---

## Where everything lives

- **This guide:** `docs/remediation/START-HERE.md`
- **Task list and technical rules:** [`docs/remediation/README.md`](README.md)
- **Phase 1 plans:** `docs/remediation/1-security/`
- **Phase 2 plans:** `docs/remediation/2-app-store-v1/`
- **Phase 3 plans:** `docs/remediation/3-post-v1/`
