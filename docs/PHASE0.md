# Phase 0: Product Architecture & Validation

Personal Accountability Platform (working title, unnamed by design). Version 0.1, 5 October 2026. Prepared for Michael. Source of truth: the Master App Build Specification (docs/SPEC.md).

## 1. The decisions on one page

> The product is one Commitment Engine with five ways to be supported. Everything in this document is that sentence made precise.

1. **One engine, no verticals.** Every goal is a Commitment with a kind (stop, start, become, achieve), a measure and a schedule. Categories only configure defaults: copy, sensitivity, suggested interventions.
2. **Occurrences make honesty possible.** Each commitment generates expected check-in periods (a day, a week, a deadline). Check-in rate, consistency and "missed" are computed from them, in the user's own timezone, so a setback never erases history.
3. **Owner-only data, permissioned projections.** Personal tables are readable only by their owner under row-level security. A partner sees a projection built from a per-field permission matrix; by default that is a status and nothing else.
4. **Anonymous by default, per relationship.** Each partnership gets its own alias ("Anonymous #4821"), so one person cannot be traced across partnerships. Identity is revealed only by its owner, one partner at a time.
5. **Adults only in V1.** Nigerian law treats under-18s as children whose data needs a parent's consent. V1 serves 18+; the schema already carries age bands, and teen mode comes later.
6. **Safety is structural, not a policy page.** Matched strangers cannot send links, phone numbers or media. Sensitive categories match same-gender, same-category only. Reports freeze messaging instantly; a human decides.
7. **AI is a set of narrow functions, not a chatbot.** Each function reads only the fields it needs. Crisis detection is deterministic and runs before any AI. The AI never contacts a partner and never claims to be a professional.
8. **Zero-cost stack.** Expo (React Native) + Supabase (Auth, Postgres, RLS, Edge Functions, Realtime, pg_cron) + Expo push + Gemini free tier with a fallback. Check-ins work offline through an idempotent queue.

## 2. The product frame

The central question is "What are you trying to do, become, start, stop, or overcome?" The loop every feature must serve:

```
DECIDE -> COMMIT -> ACT -> CHECK IN --+-- on track ---------------------+
                                      +-- struggling --> SUPPORT -------+
                                      +-- off track ---> RECOVERY ------+
                                                                        |
           GROW <-- ADJUST <-- INSIGHT <-- REFLECT <--------------------+
```

Six product rules turn the philosophy into engineering constraints:

- **Least data by default.** Nothing personal leaves the owner's rows unless the owner switches it on.
- **No dead ends.** Every "off track" leads to a recovery flow; every "struggling" leads to a next action within two taps.
- **History is cumulative.** Consistency can reset; completed periods, recovered setbacks and helpful interventions never do.
- **Support is chosen, never imposed.** The user picks the mode and can change it at any time without losing data.
- **Calm by default.** No red failure screens, no countdown pressure, no public ranking of private goals.
- **Light on the phone.** Every screen must work on a low-end Android over a slow 3G connection.

## 3. The Commitment object

A Commitment is something a person has decided to accomplish, change, maintain, stop or become. It is the only goal object in the system.

### 3.1 Fields

| Field | Type | Notes |
|---|---|---|
| id | uuid | Primary key |
| user_id | uuid | Owner; every RLS rule keys on it |
| title | text, 1–120 | "Finish my book in 30 days" |
| description | text, ≤1000 | Optional detail |
| category_slug | text → categories | Configures defaults; never branches code |
| kind | stop · start · become · achieve | From the onboarding family |
| why | text, ≤1000 | Shown back in struggle and SOS moments |
| success_definition | text, ≤500 | "What does success look like?" |
| measure | binary · quantity · duration · milestone | How a check-in is scored |
| target_value / target_unit | numeric / text | Required for quantity and duration (20 pages, 180 minutes) |
| frequency | daily · weekly · specific_days · one_time | Summary; detail lives in the schedule |
| start_date / end_date | date | end_date ≥ start_date; open-ended allowed |
| status | draft · active · paused · completed · ended · archived | Guarded state machine (3.3) |
| privacy | private · supporters · group | Who may receive a projection at all |
| support_mode | self · ai · partner · friend · group · undecided | The user's chosen mode; changeable |
| sensitivity | standard · personal · sensitive | Inherited from category; can be raised, never lowered |
| mission_template_id | uuid → mission_templates | 7/30/90-day, Personal or Comeback Mission |
| parent_id | uuid → commitments | A smaller step or Comeback Mission spun from this one |
| group_id | uuid → groups | When the commitment belongs to a group challenge |
| paused_until, completed_at, ended_at | date / timestamptz | Lifecycle stamps |
| created_at / updated_at | timestamptz | Audit |

The spec's partner_id is deliberately replaced by the partner_permissions table: one commitment can be shared with a partner and a trusted person at once, each with different visibility.

### 3.2 Related entities

| Entity | Purpose |
|---|---|
| commitment_schedules | Versioned plan: frequency, days, times per week, check-in time, reminder offsets, timezone. A plan change closes the old row, so past rates stay true. |
| occurrences | One row per expected period (day, week or deadline) with target_count, done_count and status pending · done · partial · missed · excused. |
| check_ins | The user's answer: status, value, reasons, note, local_date, client_id for idempotent offline sync. |
| progress_logs | Quantity entries (pages, minutes, applications) between or within check-ins. |
| milestones | Ordered sub-goals for achieve-type commitments. |
| setbacks | The recovery record: reasons, what happened just before, reflection, chosen changes, recovered_at. |
| triggers | Known risk moments with an if-then plan ("After 11pm on my phone → phone charges in the kitchen"). |
| interventions / intervention_sessions | A library of short guided actions, plus a log of each use and whether it helped. |
| reflections | Private journal, weekly and mission-end reflections. Never shared, never sent to AI without consent. |
| support_requests | Struggle and SOS events, who was notified, and acknowledgement. |
| ai_insights | Weekly reviews, patterns and plan suggestions, each accepted, modified or ignored. |

Streaks are not stored. Current and longest consistency, check-in rate, recovered setbacks and helpful interventions are derived by the commitment_stats view, so they can never drift out of truth.

### 3.3 State machine

| From | To | Trigger |
|---|---|---|
| draft | active | User finishes "Let's make this real" |
| draft | archived | Abandoned before starting |
| active | paused | User pauses (illness, travel); optional paused_until; no occurrences generated |
| paused | active | Resume, manual or at paused_until |
| active | completed | end_date reached with targets met, achieve-type done, or user marks complete |
| active / paused | ended | User stops it; neutral wording: "You closed this commitment" |
| completed / ended / archived | active | Restart; history stays attached |
| completed / ended | archived | Tidy away from Missions |

There is no "failed" state. A database trigger rejects every other transition.

### 3.4 How one engine fits every goal

| Kind | A check-in means | On track | Example |
|---|---|---|---|
| stop | "Did I stay clear today?" | Stayed clear | Pornography, gambling, social media after 10pm |
| start | "Did I do it?" | Did it, or met the quantity | Pray every morning; read 20 pages |
| become | "Did I practise it?" | Practised the chosen behaviour | Be more focused: two deep-work blocks |
| achieve | "Did I move it forward?" | Weekly progress; milestones close it | Finish the website; apply to five jobs a week |

A Mission is a Commitment with a mission template: fixed duration, a start ritual and a "Mission complete" moment. A Comeback Mission is a 7-day Mission spun from a setback with a smaller target.

## 4. People, roles and age

There is one account type. Roles are relationships between accounts, so the same person can be someone's partner, another person's trusted contact and a member of a group.

| Role | Who | Can see | Can do |
|---|---|---|---|
| Self (owner) | The account holder | Everything they own | Everything; the only writer of their data |
| Partner (matched) | A stranger paired by matching | The permissioned projection only, under a per-partnership alias | Encourage, nudge, message (text only, no links or contacts), acknowledge SOS, end the partnership |
| Friend (invited) | Someone the owner invited by link | The same projection, nickname-level identity by default | As partner, and may share contact details because they already know each other |
| Trusted person | Spouse, mentor, pastor, coach, sibling | Templated lines only: "checked in", "completed today", "asked for support" | Receive updates; be contacted from SOS. No messaging in V1 |
| Group member | Joined a private group by invite | Group aliases, group-visible commitments as status, group stats | Check in, encourage, group messages |
| Group owner / admin | Created the group | As member, plus the member list | Invite, remove members, archive the group |
| Moderator | Platform staff (app_roles) | Reports, evidence snapshots, held messages | Warn, freeze, end partnerships, suspend, ban, release held messages |

Trusted people do not need the app. In V1 the trusted contact is a card the owner keeps (name, relationship, WhatsApp number). The app writes the safe message ("Dami completed today's commitment") and the owner sends it through WhatsApp or SMS from their own phone, which costs nothing and needs no messaging API. If the trusted person installs the app and accepts a link, they receive the same lines as in-app notifications.

### Age handling

- Birth year is asked at sign-up and locked afterwards; the age band is derived by the database, never sent by the client.
- **V1 is 18+.** Nigeria's Data Protection Act 2023 treats anyone under 18 as a child and requires a parent's or guardian's consent to process their data. Under-18s see a respectful screen ("We're building a version for you") and no account data is kept.
- Matching never pairs anyone under 18 and only pairs adults within one adjacent age band (a 19-year-old will not be matched with a 45-year-old).
- Teen mode (V2) is designed now: guardian consent, Self + AI + invited people only, peer-only groups, no stranger matching, stricter moderation.

## 5. Support modes as flows

The differentiator is choice: "I'll do it myself", "AI, keep me accountable", "Find me someone", "My friend should keep me accountable", "Put me in a private group", "I need someone right now". Every mode sits on the same commitment and check-in data; switching modes never loses history.

### Mode A: Self

1. Create the commitment and choose a check-in time.
2. A reminder arrives at that time: "You said this mattered to you. Ready to check in?"
3. One-tap check-in; struggling and off-track branch into the support and recovery flows.
4. Journey and weekly review show progress; self-guided interventions are always available.

### Mode B: AI

1. The Goal Builder turns a sentence ("I want to stop procrastinating") into a draft commitment with a realistic target; the user edits and confirms.
2. The Plan Builder proposes three to five first actions or a schedule; the user accepts each one.
3. At check-in the Check-in Assistant asks one useful follow-up when the answer is struggling or off track.
4. Sunday evening brings a Weekly Review with one suggestion: accept, modify or ignore.
5. "Talk to AI" opens a bounded support session (at most 10 turns) that always ends with a concrete next action.

### Mode C: Matched partner

1. The user taps "Find me a partner" on a commitment and answers five quick questions: preferred partner (same gender or anyone), check-in style (gentle, direct, structured), availability (morning, afternoon, evening, night), experience (new, returning, experienced) and identity (anonymous or nickname).
2. The request joins the queue. The app says honestly: "We're looking for someone with a similar goal. Usually under a day. Meanwhile, AI support is on."
3. When a match is made, both get a neutral notification. The partnership opens in a 7-day trial; either person can end it with one tap and no explanation.
4. Each person reviews what they share (the permission screen, pre-set to safe defaults) before the partner sees anything.
5. Day to day: the partner sees status, encourages with one tap or a short message, and gets notified of check-ins and SOS requests.
6. At day 7, both are asked "Keep going with this partner?" Two yeses make the partnership active; anything else ends it kindly and offers a re-match.

### Mode D: Invited friend

1. The owner taps "Invite a friend" and types a private label ("Tolu").
2. The app creates a single-use link (7-day expiry; only its hash is stored) and opens the share sheet, WhatsApp first.
3. The friend installs, signs up and opens the link; they see what they are agreeing to before accepting.
4. On accept, the partnership becomes active immediately (no trial), with nickname identity and the commitment's title shared unless it is sensitive.
5. From then on it behaves like Mode C, except that contact sharing is allowed.

### Mode E: Private group

1. The owner creates a group (name, category, optional dates, up to 12 members in V1.5) and shares an invite link.
2. Members join under a group alias. Each member links their own commitment, visible to the group as a status only.
3. The group home shows today's check-ins as a count ("7 of 10 checked in"), encouragement and group statistics.
4. Sensitive commitments cannot be group-visible; sensitive groups are private and invite-only, never discoverable.

### Struggle flow

1. "What's happening?" Choose up to three: tired, stressed, distracted, bored, overwhelmed, tempted, lost motivation, unexpected situation, other.
2. "What would help right now?" Break it into something smaller · Take a short intervention · Talk to AI · Contact my partner · Change my plan.
3. The chosen action runs immediately; a later "Did that help?" records whether it worked, which feeds insights.

### SOS: "I need support"

The button sits on the home screen and on every commitment, visible but quiet: no red, no alarm styling.

1. **Self-guided first, immediately, offline.** A short, full-screen intervention: step away, slow breathing, change the environment, read your own why. It works without a connection.
2. **Then offer:** Contact partner · Talk to AI · Open another intervention · Contact trusted person.
3. **Partner notification is minimal:** "Your accountability partner needs support. They have requested an accountability check-in." No category, no details unless the owner allowed them.
4. **Trusted person:** the app opens WhatsApp with a pre-written line the owner can edit: "I'm having a hard moment with something I'm working on. Could you check in with me?"
5. **Crisis signposting:** if the user's words match self-harm language (a deterministic list, checked on the device before any AI call), the screen shows help immediately: Nigeria emergency 112, SURPIN's toll-free line 0800 078 7746 (24 hours), MANI on 0809 111 6264, and findahelpline.com for other countries. The app never claims to be an emergency service. Numbers live in a database table, so they can be updated without an app release.
6. Rate limit: partner notifications from SOS are capped at six an hour; the self-guided steps are never limited.

### Recovery flow (after "I slipped" / off track)

1. "Let's understand what happened." Never the word "failed".
2. "What got in the way?" stress, environment, distraction, lack of planning, temptation, fatigue, forgot, unexpected event, loss of motivation, other.
3. "What happened just before?" A short optional note, private by default.
4. "What should we change?" The app proposes up to three changes, ranked from this person's own history: smaller target, schedule change, earlier reminder, new intervention, partner check-in, AI support, environment change.
5. "Update my plan" applies them (a new schedule version) and offers a Comeback Mission.
6. The setback is marked recovered at the next on-track check-in, and "Recovered setbacks" grows on the Journey screen.

## 6. Partner matching

Matching runs as one database function, every 10 minutes and immediately after each new request. Requests are filled in by the server from the profile and commitment (age band, gender, category, sensitivity), so a client cannot claim to be someone else.

### Hard filters (never relaxed)

- Both people 18+, and no more than one age band apart.
- Same category family (stop, start, become, achieve) and the same sensitivity level.
- Sensitive categories: same exact category and same gender, enforced for both people.
- If either person asks for "same gender", both must share a stated gender.
- At least one shared language.
- Never blocked by each other, never matched before, neither restricted by moderation.
- At most two live partnerships per person.

### Soft score (0–100)

| Factor | Points |
|---|---|
| Same category (otherwise same family) | 30 (12) |
| Timezone within 1 h / 3 h / 6 h | 20 / 12 / 4 |
| Same check-in frequency | 15 |
| Overlapping availability | 10 |
| Same check-in style | 10 (3 otherwise) |
| Same age band | 8 |
| Experience fit | 4 |
| Same identity preference | 3 |

A pair needs 55 points at first. After 24 hours waiting the bar drops to 40, after 72 hours to 25. Hard filters never move. Requests expire after 14 days with an honest message and an offer to keep going with AI or invite a friend.

### Cold start with few users

- Self and AI modes are complete products on day one, so nobody waits on a match to get value.
- The waiting state is honest and useful: AI support switches on automatically and the user is told the realistic wait.
- Family-level pooling (any "start" goal with any other) widens the pool for standard categories while the bar relaxes.
- "Invite a friend" sits beside "Find me a partner"; every invite is also growth.
- Launch with seeded cohorts: open the beta to two or three communities Michael already reaches (for example Blossom readers around reading, prayer and study) so the first pools are dense.

### Re-matching

- Either person can end a partnership at any time, with an optional private reason. The other sees only "Your partnership has ended" and an offer to find someone new.
- If one side is silent for 7 days, the other is gently asked whether to continue or re-match; after 14 days of silence the partnership ends as "inactive".
- The same two people are never matched again. A block ends the partnership instantly and silently.

## 7. Privacy model

Privacy is enforced in the database, not only in the interface. Personal tables (commitments, check-ins, setbacks, reflections, triggers, trusted contacts) have owner-only row-level security; no other user can select a row, whatever the app does. Everything another person sees is produced by one security-definer function per audience (get_partner_overview, get_trusted_updates) that reads the owner's permissions first.

### Identity modes

| Mode | Partner sees | Default for |
|---|---|---|
| Anonymous | A per-partnership alias, "Anonymous #4821" | Matched partners, groups |
| Nickname | The nickname the user chose, "Daniel" | Invited friends |
| Identified | Full name | Only when the owner turns it on for one partner |

Aliases are generated per partnership and per group, so the same person cannot be recognised across relationships. Identity can be raised (anonymous → nickname → identified) by its owner, one relationship at a time, and lowered again.

### Partner permission matrix

Set per partnership, per shared commitment, per field. Defaults are chosen so that sharing nothing sensitive is the zero-effort path.

| Field | Standard default | Sensitive default | Owner can share |
|---|---|---|---|
| Check-in status and time | Shown | Shown | Yes |
| Progress (done vs due, 30 days) | Shown | Shown | Yes |
| Consistency (current run) | Shown | Shown | Yes |
| Last active | Shown | Shown | Yes |
| Commitment title | Shown for invited friends, hidden for matches | Hidden: "Personal commitment" | Yes |
| Category | As title | Hidden | Yes |
| Why | Hidden | Hidden | Yes |
| Check-in notes | Hidden | Hidden | Yes |
| Setbacks | Hidden | Hidden | Count, or dates and reasons |
| Local time | Hidden | Hidden | Yes |
| Reflections and journal | Never | Never | No |
| Email, phone, location | Never | Never | No (friends may exchange contacts in messages) |
| Other commitments | Never | Never | Only by sharing that commitment too |

### What a trusted person sees

Only fixed, templated lines, chosen per commitment: "checked in", "completed today's commitment", "asked for support", and an optional weekly line ("5 of 7 days this week"). Never a title, category, note or setback detail. The owner sees exactly the line before it is sent.

### Data handling

- Transport is TLS only; data at rest is encrypted by Supabase. The anon key in the app is safe because RLS is on for every table; the service-role key lives only in Edge Functions.
- Push notifications are lock-screen safe by default: "Time to check in", never the commitment's title. An optional app lock (PIN or fingerprint) is offered during onboarding.
- Deleting the account deletes every personal row through cascades within minutes. Only safety records survive: report evidence snapshots are kept for 180 days.
- Export: "Download my data" produces a JSON file (V1.1).
- Users can start with an anonymous Supabase session and add Google or email later, so nobody must hand over an identity to try the product.

## 8. Safety model

| Tool | What happens |
|---|---|
| Block | The partnership ends silently. Neither can see or message the other, and they are never matched again. Their messages disappear from the blocker's view. |
| Mute | Notifications from a partner or group stop, quietly. Nothing changes for the other person. |
| Disconnect | Ends a partnership, no reason required. The other sees "Your partnership has ended" with a re-match offer. |
| Report | Reasons: sexual content, harassment, spam or scam, hate, self-harm concern, minor safety, impersonation, other. The reported message is hidden at once and the last 20 messages are snapshotted as evidence. |
| Replace partner | One tap from Disconnect: "Find me someone new" re-queues the request with the old pair excluded. |
| Safety centre | One screen: block list, reports made and their status, privacy settings, crisis lines, and how moderation works. |

### Moderation queue

- Reports land in a prioritised queue: priority 0 for minor safety, self-harm concern and sexual content; 1 for harassment and hate; 2 for the rest.
- Automatic, reversible holds protect people before a human looks: any priority-0 report, or three independent reports in seven days, freezes the reported user's messaging and matching for seven days.
- A moderator reviews every freeze within 24 hours and records an action: warn, freeze, end partnership, suspend, ban, release, dismiss. AI may summarise a report, but it never decides a sanction.
- V1 moderation runs from the Supabase dashboard with saved queries; a small web admin follows in V1.1.

### Sexual-content guardrails

- Messaging is text only in V1: no images, voice notes, video or files.
- Between matched strangers and in groups, links, phone numbers, emails and social handles are rejected by the database, so the conversation cannot move off-platform.
- A moderator-maintained term list holds or blocks messages before delivery; held messages are invisible to the recipient until reviewed.
- AI moderation (the provider's safety classifier) scores messages after delivery and hides high-risk ones within seconds.
- The AI refuses sexual or romantic role-play and never generates explicit content, including in recovery contexts.

### Safeguards for sensitive categories

Pornography, masturbation, gambling and substances are sensitive by default; users can mark any other commitment sensitive.

- 18+ only; matched partners must share the exact category and gender.
- Private by default, never group-visible, never in public challenges or leaderboards.
- Partner sees "Personal commitment" unless the owner chooses otherwise.
- Notifications never name the goal. Interventions use neutral language.
- AI receives only structured data (statuses, reason codes, times) for these commitments unless the user explicitly allows their notes.

### Rate limits (enforced in the database)

| Action | Limit |
|---|---|
| Messages | 60 an hour, 300 a day |
| Partner requests | 3 a day |
| Invites | 10 a day |
| Reports | 10 a day |
| SOS partner notifications | 6 an hour (self-help unlimited) |
| New commitments | 20 a day |
| AI calls | 40 a day per user, plus a global daily budget |

## 9. AI boundaries

The AI is eight narrow functions behind Edge Functions. The client never holds a model key. Each function receives a minimal JSON payload with no names, emails or partner data, and must return JSON that matches a schema; anything else is discarded and a calm fallback is shown.

| Function | May read | Writes | Never reads |
|---|---|---|---|
| Goal Builder | The sentence typed, chosen category | A draft commitment the user confirms | Anything else |
| Plan Builder | Draft commitment, schedule, kind | Suggested actions and schedule | Notes, other commitments |
| Check-in Assistant | Today's status, reason codes, last 7 check-in statuses | One follow-up question | Partner data, journal |
| Pattern Detector | 30–90 days of statuses, times, weekdays, reason codes, intervention outcomes | Pattern insights | Note text unless consented |
| Recovery Assistant | The setback's reasons, schedule, recent outcomes | Up to three plan changes | Partner data |
| Weekly Review | The week's aggregates per commitment | Summary and one suggestion | Journal, messages |
| Adaptive Planning | Completion rate by target size and time of day | A smaller or retimed target | Note text |
| Intervention Generator | Reason codes, kind, sensitivity | A short, neutral intervention | Identity, location |

### Guardrails

- The system prompt states: you are an accountability assistant inside an app; you are not a therapist, doctor, pastor, addiction specialist or emergency service; be warm, brief and practical; never shame; never give medical, legal or financial advice; suggest, never command; no sexual or romantic content; do not encourage reliance on you; point to real people (partner, trusted person, professionals) when appropriate.
- Crisis language is detected deterministically before any model call; the crisis screen is shown and the AI is not used as the authority.
- The AI cannot message partners, change plans or share anything. Every suggestion is a card the user accepts, modifies or ignores.
- "Talk to AI" sessions are capped at 10 turns and end with an action. No persona name, no "I miss you", no streaks for talking to the AI.
- Per-user AI switch (Profile → Privacy), daily caps and a global budget. If the AI is unavailable, every flow still works with templated copy.

### Provider

Gemini Flash-class models on the free tier are the primary engine; Michael already uses them in VoicePad. Model names live in environment configuration, not code, because Google retires models (this broke VoicePad's scan feature). Groq's free tier is the automatic fallback. Google's terms allow free-tier inputs to be used to improve its products, so free-text notes are never sent without the user's explicit consent, and sensitive commitments send structured data only. When revenue exists, moving to the paid tier (which excludes training on inputs) is the first upgrade.

## 10. Data model and access rules

The full, runnable DDL is schema.sql in the repository's docs folder: 35 tables, 50 RLS policies, 46 indexes, the triggers and the RPCs. It was executed end to end on Postgres 15 with Supabase-style auth stubs, and the core rules were exercised: owner isolation, idempotent check-ins, the status machine, matching filters, the partner projection, message guards, report freezes and invites. Appendix A lists every table; the relationships at a glance:

```
auth.users 1-1 profiles
profiles 1-* commitments 1-* commitment_schedules (versioned)
                         1-* occurrences 1-* check_ins -- progress_logs
                         1-* milestones, setbacks, triggers, reflections
profiles *-* profiles via partnerships 1-* partner_permissions
partnerships 1-* messages       groups 1-* group_members, messages
profiles 1-* trusted_contacts, invites, support_requests, ai_insights
profiles 1-* reports, blocked_users, mutes, notifications, push_tokens
```

Spec name mapping: users is Supabase's auth.users; partners is partnerships; missions is mission_templates (a Mission is a commitment with a template); interventions is split into the library and intervention_sessions.

### Access pattern by table group

| Group | Tables | Rule |
|---|---|---|
| Personal | commitments, schedules, check_ins, progress_logs, milestones, setbacks, triggers, reflections, trusted_contacts, support_requests, intervention_sessions, push_tokens, mutes | Owner-only for every operation; a trigger also checks that child rows belong to a commitment the same user owns |
| Generated | occurrences, notifications, ai_insights | Owner reads; owner may excuse an occurrence, mark a notification read, respond to an insight; creation by scheduler and Edge Functions |
| Relationship | partnerships, partner_permissions, invites, partner_requests | Members read the partnership; only the owner edits their permissions; creation and ending go through functions |
| Shared | messages, groups, group_members | Members only; blocked senders filtered out; held messages visible only to their sender |
| Safety | reports, moderation_actions, blocked_users, user_restrictions, moderation_terms, app_roles | Reporter forced by trigger; moderators read the queue; restrictions and terms are service-only writes |
| Reference | categories, mission_templates, interventions, crisis_resources | Read-only to everyone signed in; crisis lines readable even before sign-in |

### Functions the app calls

| Function | Purpose |
|---|---|
| log_check_in | Idempotent check-in keyed on the phone's client_id; safe to retry from the offline queue |
| get_partner_overview | The partner's view, built field by field from the owner's permissions |
| get_trusted_updates | Templated lines for a linked trusted person |
| accept_invite | Validates a link token (only its hash is stored) and creates the partnership, trusted link or group membership |
| end_partnership | Either member, any time, neutral notice to the other |
| set_partnership_identity | Reveal or hide identity for one partner |
| run_matching, generate_occurrences, close_missed_occurrences | Scheduled jobs (pg_cron); not callable by users |

## 11. Core screens for MVP V1

Five tabs, as the spec asks: Home, Missions, Support, Journey, Profile. SOS is reachable from Home and every commitment.

| # | Screen | Content |
|---|---|---|
| 1 | Welcome | "You don't have to do it alone." Subtext from the spec; Get Started; "I already have an account" |
| 2 | Age and basics | Birth year, optional nickname; under-18 exit screen; anonymous session created here |
| 3 | What are you working on? | Four families (Stop, Start, Become, Achieve) as calm cards, each opening its categories; Other for a custom goal |
| 4 | Let's make this real | One question per step: what, why, what success looks like, how often, start date, check-in time. "Help me shape this" calls the Goal Builder |
| 5 | Choose your support | Just me · AI support · Accountability partner · Friend · Private group (shown "coming soon" in V1) · I'm not sure (Self + AI, partner suggested after 7 days) |
| 6 | Notifications and app lock | Permission request explained in one line; lock-screen privacy; optional PIN |
| 7 | Home | Greeting; today's commitments with progress; one-tap check-in row; Your support (AI, partner's last check-in); Your journey strip; quiet SOS button |
| 8 | Check-in sheet | "How did today go?" Five options with one-line meanings; optional value and note; saves offline |
| 9 | Struggle flow | What's happening → What would help → action |
| 10 | Recovery flow | What got in the way → What happened just before → What should we change → Update my plan |
| 11 | SOS | Full-screen self-guided steps, then Contact partner · Talk to AI · Intervention · Trusted person; crisis lines when needed |
| 12 | Intervention player | Step-by-step timer card; "Did that help?" at the end |
| 13 | Missions list | Active, paused, completed; new commitment; Mission templates |
| 14 | Commitment detail | Why, schedule, milestones, recent check-ins, sharing summary, edit plan, pause, complete |
| 15 | Support hub | AI card, partner card(s), trusted people, invite a friend, find a partner |
| 16 | Find a partner | Five preference questions, honest waiting state |
| 17 | Partner dashboard | Alias, shared commitment, status, last check-in; Encourage, Ask how they're doing, Message, Send support; Mute, Disconnect, Block, Report |
| 18 | Messages | Text-only thread, preset encouragements, guard errors explained kindly |
| 19 | Sharing permissions | Per-partner, per-commitment toggles with a live preview of what they see |
| 20 | Talk to AI | Bounded session with suggested replies; ends in an action card |
| 21 | Journey | Current and longest consistency, completed, check-in rate, recovered setbacks, helpful interventions, 12-week calendar |
| 22 | Weekly review | Your week: done, missed, strongest and weakest day, obstacles; AI reflection with Accept · Modify · Ignore |
| 23 | Insights | Your patterns, unlocked after 14 days of data |
| 24 | Profile and privacy | Identity mode, AI switch and consent, notification frequency and quiet hours, data export, delete account |
| 25 | Safety centre | Blocked, reports, crisis lines, how moderation works |

## 12. The five most important experiences

### 1. "I want to change something" (under 60 seconds)

Welcome → birth year → "What are you working on?" → taps Stop → Procrastination. No sign-up wall: an anonymous session starts in the background.

### 2. "I make a commitment" (under 2 minutes)

"Let's make this real." Types "Stop putting off my project work". Taps "Help me shape this": the Goal Builder proposes "Work on my project for 45 minutes before noon, Monday to Friday". Edits to 30 minutes. Why: "I'm tired of starting and stopping." Success: "Project shipped by 30 November." Check-in at 12:30. Support: AI plus "Find me a partner". Lands on Home with the commitment and a message: "Your first check-in is tomorrow at 12:30."

### 3. "I check in" (under 5 seconds)

Notification at 12:30: "Ready to check in?" Taps it, opens straight to the check-in sheet, taps On track. A small confirmation, the consistency count moves, the partner sees "on track". On a bus with no signal, it saves on the phone and syncs later, in silence.

### 4. "I'm struggling, so I get support"

Taps I'm struggling → "Tired" and "Overwhelmed" → "Break this into something smaller". The AI proposes "Open the project and write down the next three tasks. Ten minutes." Starts a 10-minute timer. Later: "Did that help?" Yes. On a harder night the user taps I need support: two minutes of guided steps, then "Contact partner"; the partner receives only "Your accountability partner needs support" and taps "Check in with them".

### 5. "I recover and continue"

Thursday evening: I slipped. "Let's understand what happened." Picks "Lack of planning" and "Distraction"; notes "Phone in hand at 9am". The app proposes: phone in another room until 10am, and a 9:15 reminder. "Update my plan" saves a new schedule version. Friday: On track. The setback is marked recovered; Journey shows "Recovered setbacks: 1" and the 3-week history still stands.

## 13. Edge cases

| Case | Behaviour |
|---|---|
| Timezones | Each schedule stores an IANA timezone; occurrences are generated in the user's local dates. Travelling users are asked once whether to move their schedule ("You're now on London time"); history is never re-dated. Partners see the other's local time only if shared. |
| Midnight and late check-ins | A day is "missed" only the next morning at 10:00 local time, so a 1am check-in still counts for yesterday. Check-ins can be logged up to 7 days back, marked as late. |
| Missed check-ins | One gentle reminder at the check-in time and one an hour later, inside quiet hours rules. After three missed days in a row, a single "Yesterday doesn't have to decide today" message offers a smaller target or a pause. No further nagging. |
| Offline check-ins | Saved to a local SQLite outbox with a client_id and the local date; shown immediately; synced on reconnect or app open. The server ignores duplicates, so retries are always safe. |
| Phone clock wrong | The server stores its own receive time beside the client's; a client time in the future is clamped. |
| Illness, travel, exams | "Excuse today" or pause the commitment: excused periods neither count against consistency nor break it. |
| Weekly targets | A "3 times a week" commitment is one weekly occurrence with target 3; each on-track check-in counts once; partial weeks show as partial, not missed. |
| Partner goes silent | After 7 days without a check-in or message, the active partner is asked: keep waiting, nudge once, or re-match. At 14 days the partnership ends as inactive, kindly. |
| Account deleted mid-partnership | An Edge Function ends every partnership first ("Your partner has left the app"), then deletes the auth user; every personal row cascades. Report evidence is retained for 180 days. |
| Abuse report against your partner | The reported message is hidden at once; serious reasons freeze the other person's messaging and matching until reviewed. The reporter is offered Block and a re-match immediately. |
| False or revenge reports | Holds expire after 7 days unless a moderator confirms; repeated false reporting is itself actionable. |
| Both partners struggle at once | Each SOS notifies the other once; the app suggests a short shared encouragement rather than chaining alerts. |
| Under-18 discovered later | Account frozen, partnerships ended, data deleted after 30 days unless age is corrected by support. |
| AI unavailable or over quota | Templated copy for every AI moment; insights wait for the next run; nothing blocks a check-in. |
| Supabase free-tier pause | Free projects pause after a week of no activity; real usage prevents it, and a daily scheduled ping covers quiet test periods. |

## 14. MVP V1 and later

| MVP V1 | V1.5 | Later (after the core loop is proven) |
|---|---|---|
| Auth (anonymous, Google, email OTP), anonymous profile, identity modes | Private groups and group challenges | Public community challenges |
| Create commitment, categories, Missions | Friend challenges ("let's both read 20 pages") | Teen mode with guardian consent |
| Daily check-ins with offline queue; progress and Journey | Data export; small web admin for moderation | Web dashboard |
| Struggle, recovery and SOS flows | Trusted person in-app accounts | Gentle progression levels (Beginning → Accountability Builder) |
| The eight narrow AI functions; weekly review and basic insights | Richer insights | Localisation (Yoruba, Hausa, Igbo, Pidgin, French) |
| Invite a friend, anonymous matching, text-only partner messaging | Optional faith-based interventions library | Partner and organisation programmes; payments |
| Notifications and quiet hours; privacy controls and permission matrix; block, mute, disconnect, report, moderation | Voice check-ins | Professional referrals, never a therapy marketplace |

Never: advertising inside the app, selling or sharing personal data, public leaderboards of private goals, device monitoring, live video.

## 15. Monetization (later, ethical)

- **Free forever:** commitments, check-ins, recovery, SOS, partner matching, friends, safety and privacy. Support is never paywalled.
- **Plus subscription** (local pricing, around ₦1,500–2,500 a month, with student pricing): deeper insights and history, unlimited Missions, advanced AI planning, themes, data export extras. The free tier must stay fully useful.
- **Groups for organisations:** churches, schools, bootcamps and companies running accountability cohorts pay per cohort, with aggregate-only reporting and no individual data.
- **Sponsored free Plus:** an organisation can fund Plus for a community without seeing anyone's data.
- **Payments:** Paystack or Flutterwave for Nigeria; store billing where Apple and Google require it.

## 16. Technical architecture

| Layer | Choice | Why |
|---|---|---|
| App | Expo (React Native) with TypeScript and Expo Router, Hermes | Michael's existing stack; one codebase for Android and iOS; web later from the same code |
| Data in the app | TanStack Query with a persisted cache; expo-sqlite outbox for check-ins | Instant screens on slow networks; offline check-ins |
| Backend | Supabase: Auth, Postgres, RLS, Edge Functions, Realtime, pg_cron | Free tier covers the MVP; security lives in the database |
| Auth | Anonymous sign-in first, then link Google or email OTP | Try before identifying; no SMS cost |
| Messaging | Supabase Realtime on messages, filtered by RLS | Live chat with no extra server |
| Push | Expo Push Service via an Edge Function reading the notifications outbox | Free; one API for Android and iOS |
| AI | Edge Functions calling Gemini Flash-class (free tier), Groq fallback | Keys server-side; schema-validated JSON output |
| Email | Brevo free SMTP for sign-in emails (Supabase's built-in mailer is rate-limited) | 300 emails a day free |
| Builds | EAS Build free tier, local Gradle builds as fallback | Michael has built Android locally before |
| Monitoring | Sentry free tier, Supabase logs | Crash and error visibility at zero cost |

Edge Functions: ai-goal, ai-plan, ai-checkin, ai-recovery, ai-weekly, ai-patterns, moderate-message, send-notifications, delete-account. Scheduled jobs: occurrences every hour, missed periods twice an hour, matching every 10 minutes, notifications every 5 minutes, weekly review hourly for users whose local time is Sunday 18:00.

Performance budget for low-end Android: install size under 25 MB, cold start under 3 seconds, Home renders from cache before any network call, no custom fonts heavier than two weights, images avoided in core flows, every list paginated, every request retried with backoff.

## 17. Build plan for MVP V1

Roughly 10 weeks for one developer working with AI assistance. Each milestone ends with the spec's test pass: UI, UX, responsiveness, database, auth, security, errors, performance, accessibility and mobile behaviour.

| Milestone | Weeks | Delivers | Done when |
|---|---|---|---|
| M0 Foundations | 0.5 | Repo, Expo app, Supabase project, schema.sql migration, CI, design tokens (provisional, unbranded) | App runs on a low-end Android; RLS tests pass |
| M1 Commit | 1.5 | Onboarding, anonymous auth, categories, create commitment, schedules, Missions list, Home | A new user can commit in under 2 minutes |
| M2 Check in | 1.5 | Occurrences job, check-in sheet, offline outbox, Journey stats, commitment detail | Airplane-mode check-ins sync once, with no duplicates |
| M3 Support and recovery | 1.5 | Struggle flow, recovery flow, SOS, intervention player, crisis lines, plan versioning | All three flows complete offline where specified |
| M4 AI | 1 | The eight Edge Functions, prompts, JSON validation, caps, fallbacks, AI settings | Every AI moment degrades gracefully with the AI off |
| M5 People | 1.5 | Invite a friend, partner requests, matching job, partner dashboard, permissions, messaging, trusted contacts | Two test accounts complete matching, sharing and messaging; guards hold |
| M6 Safety | 1 | Block, mute, disconnect, report, moderation queries, rate limits, account deletion | Abuse scenarios scripted and passing |
| M7 Rhythm and polish | 1 | Notifications and quiet hours, weekly review, insights, accessibility, dark and light mode, performance | Closed beta build ready |
| Beta | 2–4 | 30–50 users from two or three seeded communities | Week-2 check-in rate and setback recovery measured |

Validation signals for the beta: at least 60% of users check in on 4 or more days in week 2; at least half of setbacks are followed by an on-track check-in within 3 days; partner matches made within 24 hours for at least 70% of requests in seeded categories; zero safety incidents left unreviewed for more than 24 hours.

## 18. Decisions only Michael can make

1. **Minimum age.** Recommended default: 18+ for V1, with teen mode later under guardian consent.
2. **Faith layer.** Recommended default: off by default and offered in onboarding ("Include faith-based encouragement?"), so the product stays universal while honouring believers.
3. **Same-gender matching for sensitive categories.** Recommended default: enforced for matched strangers; invited friends are the user's choice.
4. **Who moderates at launch.** Recommended default: Michael plus one trusted volunteer, with a 24-hour review promise, until reports exceed about 10 a week.
5. **Launch cohort.** Recommended default: a closed beta drawn from Michael's Blossom audience, seeded around reading, prayer and study, before opening every category.
6. **AI and private notes.** Recommended default: notes are never sent to the free AI tier without explicit opt-in; sensitive commitments use structured data only until a paid, no-training tier is affordable.

## Appendix A. Table reference

Full DDL, triggers, RPCs, RLS policies and seed data: docs/schema.sql.

| Table | Key columns | RLS |
|---|---|---|
| profiles | id, identity_mode, nickname, birth_year → age_band, gender, timezone, languages, faith_content, ai flags, notification_prefs | Self; moderators read |
| app_roles | user_id, role | Self read; service writes |
| user_restrictions | messaging_frozen_until, matching_blocked, suspended_until, banned | Self and moderators read |
| categories | slug, family, sensitivity, default_kind, faith | Read-only |
| mission_templates | slug, duration_days, is_comeback | Read-only |
| interventions | owner_id (null = library), steps, for_reasons, sensitive_safe | Library read; own rows writable |
| crisis_resources | country_code, name, phone, url, hours, verified_at | Public read |
| commitments | see section 3 | Owner |
| commitment_schedules | valid_from/to, frequency, days_of_week, times_per_week, check_in_time, timezone | Owner |
| occurrences | period_start/end, due_at, target_count, done_count, status | Owner read; excuse only |
| check_ins | client_id (unique per user), status, value, reasons, note, local_date | Owner |
| progress_logs | value, unit, logged_on, client_id | Owner |
| milestones | title, target_date, achieved_at | Owner |
| setbacks | reasons, before_text, reflection, changes, recovered_at | Owner |
| triggers | label, kind, plan | Owner |
| reflections | kind, body, week_start | Owner |
| partner_requests | server-filled matching facts, preferences, relax_level, status | Owner read, insert, cancel |
| partnerships | user_a/b, origin, status, per-side alias and identity, trial_ends_at, activity | Members read; functions write |
| partner_permissions | per field: title, category, why, status, progress, consistency, notes, setbacks, last active, local time | Owner writes; partner reads |
| invites | kind, token_hash, invitee_label, status, expires_at | Inviter |
| trusted_contacts | name, relationship, phone, linked_user_id, share flags, commitment_ids | Owner |
| groups / group_members | name, sensitivity, max_members / role, alias | Members |
| messages | partnership or group, body ≤1000, status visible · held · hidden | Members (visible only); sender sees own held |
| support_requests | kind, reasons, notify flags, crisis_shown, acknowledged | Owner |
| intervention_sessions | intervention, commitment, helped | Owner |
| blocked_users / mutes | blocker, blocked / target, until | Owner |
| reports / moderation_actions | reason, evidence, priority, status / action, expires_at | Reporter and moderators |
| moderation_terms | pattern, action, scope | Service only |
| push_tokens / notifications | Expo token / kind, lock-screen-safe title, scheduled_for, sent_at, read_at | Owner |
| ai_insights / ai_usage | kind, body, suggestion, status / function, tokens | Owner |
