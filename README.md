# Accountability Partner V1 (MVP)

Keep the promises you make to yourself, with a friend in your corner. By Olaoluwa Michael.

**Live:** https://accountability-ng.vercel.app (installable PWA: open in Chrome on Android, then "Add to Home screen").

The full product plan is in [`docs/PHASE0.md`](docs/PHASE0.md) (from the `phase-0` branch). This branch is the first working slice of it, built with the six recommended defaults from section 18:

1. Adults only (18+). Birth year is asked at sign-up, checked by the database and locked afterwards. Under-18s see a kind "we're building a version for you" screen, and no account data is kept.
2. Faith layer off by default, offered in onboarding ("Include faith-based encouragement?"). When on, hard moments show a short KJV verse. Changeable in Me.
3. Same-gender matching for sensitive categories with strangers: matching is not in V1 (invited friends only), so nothing to enforce yet. Sensitive categories are already marked and hide the title from partners by default.
4. Michael plus one volunteer moderate: every report is emailed to Michael and freezes messaging on that partnership instantly.
5. Closed beta from the Blossom audience: Reading, Prayer, Study and Bible study are featured first in onboarding.
6. Private notes are never sent to any AI. V1 has no AI at all, and the "what happened just before" note is owner-only and never in a partner's view.

## What works

- **Start privately:** anonymous Supabase session, no email or phone. Age gate 18+.
- **Onboarding:** faith toggle, then a goal family (Start / Stop / Become / Achieve) and a category.
- **Commitment:** title, why, measure (done-or-not, or an amount like 10 pages), days of the week, check-in time.
- **Daily check-in in one tap:** Done / Partly / Missed / Struggling. For "Stop" goals, the labels are Kept it / Partly / Slipped / Struggling. Check-ins made offline are saved on the phone and sync later.
- **Struggling:** a support screen (smaller step, 2-minute reset, ask my partner, change my plan).
- **Recovery flow (rule-based, no AI):** "What got in the way?" (up to 3 reasons), "What happened just before?" (private note), "What should we change?" (up to 3 suggested changes, ranked from the reasons and from what helped this person before). "Update my plan" writes a new schedule version, so past rates stay true. A Comeback Mission (7 days) is offered. The setback is marked recovered at the next on-track check-in.
- **Journey:** check-in rate, current run, best run, recovered setbacks, and a 4-week calendar. History is never erased: there is no delete on check-ins or setbacks.
- **Invite a friend by link:** single-use, 7-day expiry, only a hash is stored. Shared through WhatsApp, the share sheet or copy.
- **Partner view:** a status-only projection by default (today's status, progress over 30 days, current run, last check-in). One-tap encouragement and short messages (280 characters).
- **Per-field sharing screen for the owner:** status, progress, run, last active, title, category, why, notes, setback count. Private notes from hard days and other commitments are never shared.
- **Day-7 "Keep going?":** shown to both people after a week. "End kindly" closes the partnership, and history stays.
- **SOS ("I need support"):** quiet, not red. A breathing and step-away screen works offline, then:
  - notify my partner (capped at 6 an hour);
  - message someone I trust on WhatsApp (pre-written);
  - crisis lines. The lines are Nigeria 112, Lagos 767, MANI 0809 111 6264, SURPIN 0800 078 7746 and findahelpline.com. They are stored in the database and cached on the phone. Self-harm words in notes trigger the lines deterministically.
- **Report a problem:** stored in `ap_reports`. It freezes messaging on that partnership and emails Michael through Brevo (`/api/report`).
- **Me:** name, faith toggle, time zone, pause/resume commitments, sign out, delete my data.

## Stack

- No build step. Plain HTML, CSS and JS (about 70 KB) plus a vendored `supabase-js` UMD (218 KB, about 55 KB compressed), all from `public/`. This keeps it light for a Redmi A5 on slow 3G. The service worker caches the app shell.
- **Supabase:** tables live in the Blossom project (`rlbrhpjljjgpqpqjrpkc`), public schema. Every object is prefixed `ap_` so nothing collides with Blossom or Ranti. RLS is on for every table. Column-level grants allow only harmless writes. Partners never read owner tables: they read `ap_partner_view()`, a security-definer projection that checks the owner's permissions first.
- **Vercel:** project `accountability-ng`. `api/report.js` is the only server function; it needs these environment variables:
  - `SUPABASE_URL`
  - `SUPABASE_ANON_KEY`
  - `SUPABASE_SECRET_KEY`
  - `BREVO_API_KEY`
  - `REPORT_TO`
  - `REPORT_FROM`

```
public/            the app (index.html, app.js, styles.css, sw.js, manifest, icons, vendor/supabase.js)
api/report.js      report email to the moderator
supabase/          01_schema.sql, 02_functions.sql, 03_seed.sql (idempotent; apply in order)
test/rls_test.py   31 RLS and privacy checks against the live project
test/e2e.mjs       two-person walk of the core loop on the live site (phone viewport), saves screenshots
```

## Tests (6 Oct 2026)

- `test/rls_test.py`: **31/31 pass**. The checks cover:
  - the under-18 block and profile spoofing;
  - backdating of start dates;
  - another user reading any owner table (A vs B vs a stranger);
  - check-ins on someone else's goal, and deleting history;
  - single-use invites and accepting your own invite;
  - the partner projection: status only, with why, notes and setbacks hidden until shared;
  - private notes never being projected;
  - messaging by strangers, SOS, recovery marking, report freeze, and delete-my-data.
- `test/e2e.mjs`: **12/12 pass**. Owner creates a commitment, invites a partner, partner accepts, owner struggles, recovery suggests changes, plan updated, partner sees "Struggling" (and not the private note), partner encourages and messages, owner turns the day around, Journey shows 1 recovered setback, sharing controls, SOS shows crisis lines and notifies the partner.

Both scripts create throwaway anonymous users. To clean up afterwards (SQL editor): `delete from auth.users where is_anonymous and created_at > now() - interval '1 hour';`

## Things Michael must do

- **Google sign-in (optional, to save an account across phones):** in Google Cloud Console, open Credentials, then the OAuth client `177805466721-pt2dj9...`. Add this Authorized redirect URI: `https://rlbrhpjljjgpqpqjrpkc.supabase.co/auth/v1/callback`. It is missing today, so Google sign-in fails with `redirect_uri_mismatch` on this project. Then set `GOOGLE_READY = true` at the top of `public/app.js` and redeploy. Until then, people start privately on their phone.
- **Email sign-in (later):** the Blossom project has no custom SMTP. Supabase's built-in mailer only sends a few emails an hour, to team members, so magic links are off. Adding Brevo SMTP under Auth, then SMTP settings, would enable it.
- **Moderation:** reports arrive by email. To unfreeze or end a partnership, update `ap_partnerships.status` in the Supabase table editor.

## Next phases (deferred from V1)

- Stranger matching: the five questions, queue, same-gender for sensitive categories, adjacent age bands, 7-day trial.
- Private groups (up to 12, group aliases, "7 of 10 checked in").
- Moderation tooling: queue, evidence snapshots, warn, suspend or ban, a held-message review screen.
- AI functions: Goal Builder, Plan Builder, check-in assistant, weekly review, bounded "Talk to AI". Private notes stay out without opt-in.
- Web push reminders (VAPID + a cron sender). The service worker already shows lock-screen-safe copy ("Time to check in", never the goal).
- Trusted-person templated updates, reflections and journal, data export, app lock (PIN).
- Payments (ethical premium), teen mode with guardian consent.
- An APK (TWA) wrapper once the PWA has settled.
