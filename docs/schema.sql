-- =====================================================================
-- Accountability Partner (working title) - MVP V1 schema
-- Target: Supabase (Postgres 15+). Run once in the SQL editor, or save as
-- supabase/migrations/0001_init.sql.
--
-- Rules this schema enforces:
--  1. Personal tables are OWNER-ONLY under RLS. Nobody else can select a
--     commitment, check-in, setback or reflection row directly.
--  2. Partners see a permissioned PROJECTION built by security-definer
--     functions (get_partner_overview) that read the owner's
--     partner_permissions. Only check-in status is shared by default.
--  3. Matching, moderation and restrictions are written only by
--     security-definer functions or the service role (Edge Functions).
--  4. Offline check-ins are idempotent: (user_id, client_id) is unique.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
create type identity_mode      as enum ('anonymous','nickname','identified');
create type age_band           as enum ('under_18','18_24','25_34','35_44','45_plus');
create type gender_kind        as enum ('woman','man','prefer_not');
create type category_family    as enum ('stop','start','become','achieve','other');
create type sensitivity_level  as enum ('standard','personal','sensitive');
create type commitment_kind    as enum ('stop','start','become','achieve');
create type measure_type       as enum ('binary','quantity','duration','milestone');
create type frequency_kind     as enum ('daily','weekly','specific_days','one_time');
create type commitment_status  as enum ('draft','active','paused','completed','ended','archived');
create type privacy_level      as enum ('private','supporters','group');
create type support_mode       as enum ('self','ai','partner','friend','group','undecided');
create type check_in_status    as enum ('on_track','struggling','off_track','completed','need_support');
create type occurrence_status  as enum ('pending','done','partial','missed','excused');
create type partnership_origin as enum ('matched','invite');
create type partnership_status as enum ('trial','active','ended');
create type request_status     as enum ('queued','matched','cancelled','expired');
create type checkin_style      as enum ('gentle','direct','structured');
create type support_kind       as enum ('struggle','sos');
create type support_status     as enum ('open','acknowledged','resolved','expired');
create type message_kind       as enum ('text','encouragement','nudge','system');
create type message_status     as enum ('visible','held','hidden');
create type report_reason      as enum ('sexual_content','harassment','spam_scam','hate',
                                        'self_harm_concern','minor_safety','impersonation','other');
create type report_status      as enum ('open','reviewing','actioned','dismissed');
create type mod_action         as enum ('warn','freeze_messaging','end_partnership',
                                        'suspend','ban','release_message','dismiss');
create type insight_kind       as enum ('goal','plan','weekly_review','pattern','recovery','adjustment');
create type insight_status     as enum ('pending','accepted','modified','ignored','expired');
create type invite_kind        as enum ('partner','trusted','group');
create type invite_status      as enum ('pending','accepted','declined','revoked','expired');
create type notification_kind  as enum ('reminder','partner_check_in','support_request','message',
                                        'recovery','weekly_review','match','invite','system');
create type group_role         as enum ('owner','admin','member');

create or replace function set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

create or replace function random_alias() returns text
language sql volatile as $$
  select 'Anonymous #' || (1000 + floor(random() * 9000))::int::text
$$;

create or replace function is_service_role() returns boolean
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role'
$$;

-- ---------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------
create table profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  identity_mode         identity_mode not null default 'anonymous',
  anon_handle           text not null unique default (random_alias() || '-' || substr(md5(random()::text), 1, 4)),
  nickname              text check (char_length(nickname) between 2 and 24),
  full_name             text check (char_length(full_name) <= 80),
  birth_year            smallint check (birth_year between 1900 and 2100),
  age_band              age_band,                      -- derived by trigger, never client-set
  gender                gender_kind not null default 'prefer_not',
  country_code          char(2) default 'NG',
  timezone              text not null default 'Africa/Lagos',
  languages             text[] not null default '{en}',
  faith_content         boolean not null default false, -- opt-in faith layer
  ai_enabled            boolean not null default true,
  ai_free_text_consent  boolean not null default false, -- may AI read my written notes?
  notification_prefs    jsonb not null default
    '{"reminders":true,"partner":true,"recovery":true,"weekly_review":true,
      "quiet_start":"22:00","quiet_end":"07:00","lock_screen_detail":"generic"}'::jsonb,
  onboarded_at          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create or replace function profiles_derive() returns trigger
language plpgsql as $$
declare age int;
begin
  if tg_op = 'UPDATE' and old.birth_year is not null
     and new.birth_year is distinct from old.birth_year and not is_service_role() then
    raise exception 'birth_year_locked' using hint = 'Contact support to correct your age.';
  end if;
  if new.birth_year is null then
    new.age_band := null;
  else
    age := extract(year from now())::int - new.birth_year - 1;  -- conservative: assume birthday not yet reached
    new.age_band := (case when age < 18 then 'under_18' when age < 25 then '18_24'
                          when age < 35 then '25_34' when age < 45 then '35_44' else '45_plus' end)::age_band;
  end if;
  return new;
end $$;
create trigger profiles_derive  before insert or update on profiles for each row execute function profiles_derive();
create trigger profiles_updated before update on profiles for each row execute function set_updated_at();

-- A profile is created for every auth user (including Supabase anonymous sign-ins).
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin insert into public.profiles (id) values (new.id) on conflict do nothing; return new; end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

create table app_roles (
  user_id     uuid not null references profiles(id) on delete cascade,
  role        text not null check (role in ('moderator','admin')),
  created_at  timestamptz not null default now(),
  primary key (user_id, role)
);

create table user_restrictions (
  user_id                 uuid primary key references profiles(id) on delete cascade,
  messaging_frozen_until  timestamptz,
  matching_blocked        boolean not null default false,
  suspended_until         timestamptz,
  banned                  boolean not null default false,
  note                    text,
  updated_at              timestamptz not null default now()
);

create or replace function is_moderator() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_roles where user_id = auth.uid())
$$;

create or replace function can_message(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from user_restrictions r where r.user_id = p_user
     and (r.banned or coalesce(r.suspended_until, '-infinity') > now()
          or coalesce(r.messaging_frozen_until, '-infinity') > now()))
$$;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
create table categories (
  slug          text primary key,
  family        category_family not null,
  label         text not null,
  sensitivity   sensitivity_level not null default 'standard',
  default_kind  commitment_kind not null,
  faith         boolean not null default false,
  sort          smallint not null default 100,
  is_active     boolean not null default true
);

create table mission_templates (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique,
  label          text not null,
  duration_days  smallint check (duration_days between 1 and 366),
  description    text,
  is_comeback    boolean not null default false
);

create table interventions (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid references profiles(id) on delete cascade,   -- null = built-in library
  slug              text unique,
  title             text not null check (char_length(title) <= 80),
  steps             jsonb not null,                -- [{"text": "...", "seconds": 30}]
  duration_seconds  smallint not null default 120,
  for_reasons       text[] not null default '{}',  -- tempted, stressed, bored ...
  sensitive_safe    boolean not null default true,
  faith             boolean not null default false,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now()
);

create table crisis_resources (
  id            uuid primary key default gen_random_uuid(),
  country_code  char(2),                 -- null = international
  name          text not null,
  phone         text,
  sms           text,
  url           text,
  hours         text,
  sort          smallint not null default 100,
  verified_at   date not null
);

-- ---------------------------------------------------------------------
-- The Commitment engine
-- ---------------------------------------------------------------------
create table commitments (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null references profiles(id) on delete cascade,
  title                text not null check (char_length(title) between 1 and 120),
  description          text check (char_length(description) <= 1000),
  category_slug        text not null references categories(slug),
  kind                 commitment_kind not null,
  why                  text check (char_length(why) <= 1000),
  success_definition   text check (char_length(success_definition) <= 500),
  measure              measure_type not null default 'binary',
  target_value         numeric check (target_value > 0),
  target_unit          text check (char_length(target_unit) <= 24),
  frequency            frequency_kind not null default 'daily',
  start_date           date not null default current_date,
  end_date             date,
  status               commitment_status not null default 'active',
  privacy              privacy_level not null default 'private',
  support_mode         support_mode not null default 'self',
  sensitivity          sensitivity_level not null default 'standard',
  mission_template_id  uuid references mission_templates(id),
  parent_id            uuid references commitments(id) on delete set null,  -- smaller step / comeback mission
  group_id             uuid,                                                -- fk added after groups
  paused_until         date,
  completed_at         timestamptz,
  ended_at             timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  check (end_date is null or end_date >= start_date),
  check ((measure in ('quantity','duration')) = (target_value is not null))
);
create index commitments_user_status_idx on commitments (user_id, status);
create index commitments_category_idx on commitments (category_slug);
create index commitments_group_idx on commitments (group_id) where group_id is not null;
create trigger commitments_updated before update on commitments for each row execute function set_updated_at();

-- Sensitivity follows the category and can be raised, never lowered.
create or replace function commitments_sensitivity() returns trigger
language plpgsql as $$
declare cat sensitivity_level;
begin
  select sensitivity into cat from categories where slug = new.category_slug;
  if cat = 'sensitive' then new.sensitivity := 'sensitive';
  elsif cat = 'personal' and new.sensitivity = 'standard' then new.sensitivity := 'personal';
  end if;
  if new.sensitivity = 'sensitive' and new.privacy = 'group' then
    raise exception 'sensitive_commitments_cannot_be_group_visible';
  end if;
  return new;
end $$;
create trigger commitments_sensitivity before insert or update of category_slug, sensitivity, privacy
  on commitments for each row execute function commitments_sensitivity();

-- The status machine: only legal transitions.
create or replace function commitments_status_guard() returns trigger
language plpgsql as $$
begin
  if new.status = old.status then return new; end if;
  if not (   (old.status = 'draft'     and new.status in ('active','archived'))
          or (old.status = 'active'    and new.status in ('paused','completed','ended'))
          or (old.status = 'paused'    and new.status in ('active','ended'))
          or (old.status in ('completed','ended') and new.status in ('archived','active'))
          or (old.status = 'archived'  and new.status = 'active')) then
    raise exception 'illegal_status_transition % -> %', old.status, new.status;
  end if;
  if new.status = 'completed' then new.completed_at := now(); end if;
  if new.status = 'ended'     then new.ended_at := now(); end if;
  if new.status = 'active'    then new.paused_until := null; end if;
  return new;
end $$;
create trigger commitments_status before update of status on commitments
  for each row execute function commitments_status_guard();

-- Schedules are versioned: a plan change closes the open row and opens a new
-- one, so past check-in rates are never rewritten by a new plan.
create table commitment_schedules (
  id                uuid primary key default gen_random_uuid(),
  commitment_id     uuid not null references commitments(id) on delete cascade,
  user_id           uuid not null references profiles(id) on delete cascade,
  valid_from        date not null default current_date,
  valid_to          date,
  frequency         frequency_kind not null,
  days_of_week      smallint[] check (days_of_week <@ array[1,2,3,4,5,6,7]::smallint[]),  -- ISO, 1 = Monday
  times_per_week    smallint check (times_per_week between 1 and 7),
  due_date          date,                          -- one_time
  check_in_time     time not null default '20:00', -- local time
  reminder_offsets  smallint[] not null default '{0}',  -- minutes before check_in_time
  timezone          text not null,
  created_at        timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  check (frequency <> 'specific_days' or days_of_week is not null),
  check (frequency <> 'weekly' or times_per_week is not null),
  check (frequency <> 'one_time' or due_date is not null)
);
create unique index schedules_one_open_idx on commitment_schedules (commitment_id) where valid_to is null;
create index schedules_user_idx on commitment_schedules (user_id);

-- Occurrences: one row per expected check-in period (a day, a week or the
-- deadline), generated ahead by the scheduler. They make "missed",
-- check-in rate and consistency exact and timezone-safe.
create table occurrences (
  id             uuid primary key default gen_random_uuid(),
  commitment_id  uuid not null references commitments(id) on delete cascade,
  user_id        uuid not null references profiles(id) on delete cascade,
  period_start   date not null,              -- the user's local date
  period_end     date not null,
  due_at         timestamptz not null,       -- check-in moment in UTC
  target_count   smallint not null default 1,
  done_count     smallint not null default 0,
  status         occurrence_status not null default 'pending',
  closed_at      timestamptz,
  unique (commitment_id, period_start),
  check (period_end >= period_start)
);
create index occurrences_user_period_idx on occurrences (user_id, period_start desc);
create index occurrences_pending_due_idx on occurrences (due_at) where status = 'pending';

create table check_ins (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references profiles(id) on delete cascade,
  commitment_id      uuid not null references commitments(id) on delete cascade,
  occurrence_id      uuid references occurrences(id) on delete set null,
  client_id          uuid not null,                -- made on the phone: offline sync is idempotent
  status             check_in_status not null,
  value              numeric check (value >= 0),   -- pages, minutes, applications ...
  reasons            text[] not null default '{}' check (cardinality(reasons) <= 5),
  note               text check (char_length(note) <= 2000),
  local_date         date not null,
  client_created_at  timestamptz not null,
  created_at         timestamptz not null default now(),
  unique (user_id, client_id)
);
create index check_ins_commitment_date_idx on check_ins (commitment_id, local_date desc);
create index check_ins_user_created_idx on check_ins (user_id, created_at desc);
create index check_ins_occurrence_idx on check_ins (occurrence_id);

create table progress_logs (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  commitment_id  uuid not null references commitments(id) on delete cascade,
  check_in_id    uuid references check_ins(id) on delete cascade,
  client_id      uuid not null,
  value          numeric not null,
  unit           text check (char_length(unit) <= 24),
  note           text check (char_length(note) <= 500),
  logged_on      date not null,
  created_at     timestamptz not null default now(),
  unique (user_id, client_id)
);
create index progress_logs_commitment_idx on progress_logs (commitment_id, logged_on desc);

create table milestones (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  commitment_id  uuid not null references commitments(id) on delete cascade,
  title          text not null check (char_length(title) <= 120),
  target_date    date,
  achieved_at    timestamptz,
  sort           smallint not null default 0,
  created_at     timestamptz not null default now()
);
create index milestones_commitment_idx on milestones (commitment_id, sort);

create table setbacks (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  commitment_id  uuid not null references commitments(id) on delete cascade,
  check_in_id    uuid references check_ins(id) on delete set null,
  occurred_on    date not null,
  reasons        text[] not null default '{}' check (cardinality(reasons) <= 5),
  before_text    text check (char_length(before_text) <= 1000),  -- "what happened just before?"
  reflection     text check (char_length(reflection) <= 2000),
  changes        text[] not null default '{}',   -- smaller_target, schedule_change, earlier_reminder ...
  plan_updated   boolean not null default false,
  recovered_at   timestamptz,                     -- set by the next on-track check-in
  created_at     timestamptz not null default now()
);
create index setbacks_commitment_idx on setbacks (commitment_id, occurred_on desc);
create index setbacks_open_idx on setbacks (user_id) where recovered_at is null;

create table triggers (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  commitment_id  uuid references commitments(id) on delete cascade,
  label          text not null check (char_length(label) <= 80),
  kind           text not null check (kind in ('time','place','emotion','situation','person','digital','other')),
  plan           text check (char_length(plan) <= 500),  -- "if this happens, I will ..."
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);
create index triggers_user_idx on triggers (user_id);

create table reflections (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  commitment_id  uuid references commitments(id) on delete set null,
  kind           text not null check (kind in ('journal','weekly','setback','mission_end')),
  prompt         text,
  body           text not null check (char_length(body) <= 5000),
  week_start     date,
  created_at     timestamptz not null default now()
);
create index reflections_user_idx on reflections (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- Partnerships (matched stranger or invited friend), permissions, groups
-- ---------------------------------------------------------------------
create table partner_requests (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references profiles(id) on delete cascade,
  commitment_id       uuid not null references commitments(id) on delete cascade,
  category_slug       text not null references categories(slug),
  family              category_family not null,
  sensitivity         sensitivity_level not null,
  gender              gender_kind not null,
  gender_preference   text not null default 'any' check (gender_preference in ('same','any')),
  age_band            age_band not null,
  languages           text[] not null default '{en}',
  utc_offset_minutes  smallint not null,
  check_in_frequency  frequency_kind not null default 'daily',
  style               checkin_style not null default 'gentle',
  availability        text[] not null default '{evening}',  -- morning, afternoon, evening, night
  experience          text not null default 'new' check (experience in ('new','returning','experienced')),
  identity_mode       identity_mode not null default 'anonymous',
  status              request_status not null default 'queued',
  relax_level         smallint not null default 0,     -- soft factors loosen after 24 h and 72 h
  partnership_id      uuid,
  created_at          timestamptz not null default now(),
  expires_at          timestamptz not null default now() + interval '14 days'
);
create unique index partner_requests_one_open_idx on partner_requests (user_id, commitment_id) where status = 'queued';
create index partner_requests_queue_idx on partner_requests (family, sensitivity, created_at) where status = 'queued';

-- Server-side truth for the request: copy category and profile facts so a
-- client cannot claim another age band, gender or sensitivity.
create or replace function partner_requests_fill() returns trigger
language plpgsql security definer set search_path = public as $$
declare c commitments; cat categories; pr profiles;
begin
  select * into c from commitments where id = new.commitment_id and user_id = new.user_id;
  if c.id is null then raise exception 'commitment_not_owned'; end if;
  select * into cat from categories where slug = c.category_slug;
  select * into pr from profiles where id = new.user_id;
  if pr.age_band is null or pr.age_band = 'under_18' then raise exception 'age_not_supported'; end if;
  new.category_slug := c.category_slug;
  new.family        := cat.family;
  new.sensitivity   := c.sensitivity;
  new.gender        := pr.gender;
  new.age_band      := pr.age_band;
  new.languages     := pr.languages;
  if c.sensitivity = 'sensitive' then new.gender_preference := 'same'; end if;
  return new;
end $$;
create trigger partner_requests_fill before insert on partner_requests
  for each row execute function partner_requests_fill();

create table partnerships (
  id               uuid primary key default gen_random_uuid(),
  user_a           uuid not null references profiles(id) on delete cascade,  -- requester / inviter
  user_b           uuid not null references profiles(id) on delete cascade,
  origin           partnership_origin not null,
  status           partnership_status not null default 'trial',
  alias_a          text not null default random_alias(),   -- how B sees A while A is anonymous
  alias_b          text not null default random_alias(),
  identity_a       identity_mode not null default 'anonymous',
  identity_b       identity_mode not null default 'anonymous',
  sensitivity      sensitivity_level not null default 'standard',
  trial_ends_at    timestamptz not null default now() + interval '7 days',
  last_activity_a  timestamptz,
  last_activity_b  timestamptz,
  last_read_a      timestamptz,
  last_read_b      timestamptz,
  ended_at         timestamptz,
  ended_by         uuid references profiles(id) on delete set null,
  end_reason       text check (end_reason in ('not_a_fit','goal_done','inactive','safety','blocked','account_deleted','other')),
  created_at       timestamptz not null default now(),
  check (user_a <> user_b)
);
create index partnerships_a_idx on partnerships (user_a) where status <> 'ended';
create index partnerships_b_idx on partnerships (user_b) where status <> 'ended';
create unique index partnerships_pair_live_idx on partnerships (least(user_a, user_b), greatest(user_a, user_b))
  where status <> 'ended';

alter table partner_requests add constraint partner_requests_partnership_fk
  foreign key (partnership_id) references partnerships(id) on delete set null;

create or replace function is_partner_member(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from partnerships where id = p and auth.uid() in (user_a, user_b))
$$;

-- Per partnership x shared commitment x field. Owner-controlled.
create table partner_permissions (
  id                   uuid primary key default gen_random_uuid(),
  partnership_id       uuid not null references partnerships(id) on delete cascade,
  owner_id             uuid not null references profiles(id) on delete cascade,
  commitment_id        uuid not null references commitments(id) on delete cascade,
  show_title           boolean not null default false,   -- false = "Personal commitment"
  show_category        boolean not null default false,
  show_why             boolean not null default false,
  show_status          boolean not null default true,    -- on track / struggling / off track
  show_progress        boolean not null default true,    -- done vs due, last 30 days
  show_consistency     boolean not null default true,
  show_check_in_notes  boolean not null default false,
  setbacks_detail      text not null default 'none' check (setbacks_detail in ('none','count','details')),
  show_last_active     boolean not null default true,
  show_local_time      boolean not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (partnership_id, commitment_id)
);
create index partner_permissions_owner_idx on partner_permissions (owner_id);
create index partner_permissions_commitment_idx on partner_permissions (commitment_id);
create trigger partner_permissions_updated before update on partner_permissions
  for each row execute function set_updated_at();

create table groups (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references profiles(id) on delete cascade,
  name           text not null check (char_length(name) between 2 and 60),
  description    text check (char_length(description) <= 500),
  category_slug  text references categories(slug),
  sensitivity    sensitivity_level not null default 'standard',
  max_members    smallint not null default 12 check (max_members between 2 and 50),
  starts_on      date,
  ends_on        date,
  archived_at    timestamptz,
  created_at     timestamptz not null default now()
);
create index groups_owner_idx on groups (owner_id);

create table group_members (
  group_id   uuid not null references groups(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  role       group_role not null default 'member',
  alias      text not null default random_alias(),
  joined_at  timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index group_members_user_idx on group_members (user_id);

alter table commitments add constraint commitments_group_fk
  foreign key (group_id) references groups(id) on delete set null;

create or replace function is_group_member(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from group_members where group_id = g and user_id = auth.uid())
$$;

-- The group owner becomes its first member.
create or replace function groups_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into group_members (group_id, user_id, role) values (new.id, new.owner_id, 'owner');
  return null;
end $$;
create trigger groups_after after insert on groups for each row execute function groups_after();

create table invites (
  id             uuid primary key default gen_random_uuid(),
  inviter_id     uuid not null references profiles(id) on delete cascade,
  kind           invite_kind not null,
  commitment_id  uuid references commitments(id) on delete cascade,
  group_id       uuid references groups(id) on delete cascade,
  trusted_contact_id uuid,
  token_hash     text not null unique,     -- sha256 of the link token; the token is never stored
  invitee_label  text check (char_length(invitee_label) <= 60),   -- private note, e.g. "Tolu"
  status         invite_status not null default 'pending',
  accepted_by    uuid references profiles(id) on delete set null,
  expires_at     timestamptz not null default now() + interval '7 days',
  created_at     timestamptz not null default now()
);
create index invites_inviter_idx on invites (inviter_id, created_at desc);

create table trusted_contacts (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references profiles(id) on delete cascade,
  name                    text not null check (char_length(name) <= 60),
  relationship            text not null check (relationship in
                            ('friend','spouse','mentor','pastor','coach','sibling','parent','other')),
  phone_e164              text check (phone_e164 ~ '^\+[1-9][0-9]{6,14}$'),
  linked_user_id          uuid references profiles(id) on delete set null,
  share_completions       boolean not null default true,
  share_support_requests  boolean not null default true,
  share_weekly_summary    boolean not null default false,
  commitment_ids          uuid[] not null default '{}',   -- empty = nothing shared
  created_at              timestamptz not null default now()
);
create index trusted_contacts_user_idx on trusted_contacts (user_id);
create index trusted_contacts_linked_idx on trusted_contacts (linked_user_id) where linked_user_id is not null;

alter table invites add constraint invites_trusted_fk
  foreign key (trusted_contact_id) references trusted_contacts(id) on delete cascade;

create table messages (
  id              uuid primary key default gen_random_uuid(),
  partnership_id  uuid references partnerships(id) on delete cascade,
  group_id        uuid references groups(id) on delete cascade,
  sender_id       uuid not null references profiles(id) on delete cascade,
  client_id       uuid not null,
  kind            message_kind not null default 'text',
  body            text not null check (char_length(body) between 1 and 1000),
  status          message_status not null default 'visible',
  moderation      jsonb,                    -- which rule held it; classifier scores
  created_at      timestamptz not null default now(),
  check ((partnership_id is null) <> (group_id is null)),
  unique (sender_id, client_id)
);
create index messages_partnership_idx on messages (partnership_id, created_at desc);
create index messages_group_idx on messages (group_id, created_at desc);
create index messages_held_idx on messages (created_at) where status = 'held';

create table support_requests (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references profiles(id) on delete cascade,
  commitment_id    uuid references commitments(id) on delete set null,
  kind             support_kind not null,
  status           support_status not null default 'open',
  reasons          text[] not null default '{}',
  notify_partners  boolean not null default false,
  notify_trusted   boolean not null default false,
  crisis_shown     boolean not null default false,    -- helplines were displayed
  acknowledged_by  uuid references profiles(id) on delete set null,
  acknowledged_at  timestamptz,
  resolved_at      timestamptz,
  created_at       timestamptz not null default now()
);
create index support_requests_user_idx on support_requests (user_id, created_at desc);
create index support_requests_open_idx on support_requests (created_at) where status = 'open';

create table intervention_sessions (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references profiles(id) on delete cascade,
  intervention_id     uuid not null references interventions(id) on delete cascade,
  commitment_id       uuid references commitments(id) on delete set null,
  support_request_id  uuid references support_requests(id) on delete set null,
  started_at          timestamptz not null default now(),
  completed_at        timestamptz,
  helped              boolean
);
create index intervention_sessions_user_idx on intervention_sessions (user_id, started_at desc);
create index intervention_sessions_commitment_idx on intervention_sessions (commitment_id);

-- ---------------------------------------------------------------------
-- Safety
-- ---------------------------------------------------------------------
create table blocked_users (
  blocker_id  uuid not null references profiles(id) on delete cascade,
  blocked_id  uuid not null references profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocked_users_blocked_idx on blocked_users (blocked_id);

create or replace function is_blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocked_users
                  where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a))
$$;

create table mutes (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references profiles(id) on delete cascade,
  partnership_id  uuid references partnerships(id) on delete cascade,
  group_id        uuid references groups(id) on delete cascade,
  until           timestamptz,               -- null = until unmuted
  created_at      timestamptz not null default now(),
  check ((partnership_id is null) <> (group_id is null))
);
create unique index mutes_target_idx on mutes (user_id, coalesce(partnership_id, group_id));

create table reports (
  id                uuid primary key default gen_random_uuid(),
  reporter_id       uuid references profiles(id) on delete set null,
  reported_user_id  uuid references profiles(id) on delete set null,
  partnership_id    uuid references partnerships(id) on delete set null,
  group_id          uuid references groups(id) on delete set null,
  message_id        uuid references messages(id) on delete set null,
  reason            report_reason not null,
  details           text check (char_length(details) <= 1000),
  evidence          jsonb,            -- server snapshot of the conversation, kept 180 days
  priority          smallint not null default 2,   -- 0 = urgent
  status            report_status not null default 'open',
  assigned_to       uuid references profiles(id) on delete set null,
  resolution        text,
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz
);
create index reports_queue_idx on reports (status, priority, created_at) where status in ('open','reviewing');
create index reports_reported_idx on reports (reported_user_id, created_at desc);
create index reports_reporter_idx on reports (reporter_id, created_at desc);

create table moderation_actions (
  id              uuid primary key default gen_random_uuid(),
  report_id       uuid references reports(id) on delete set null,
  moderator_id    uuid references profiles(id) on delete set null,
  target_user_id  uuid references profiles(id) on delete set null,
  action          mod_action not null,
  note            text,
  expires_at      timestamptz,
  created_at      timestamptz not null default now()
);
create index moderation_actions_target_idx on moderation_actions (target_user_id, created_at desc);

create table moderation_terms (
  id       serial primary key,
  pattern  text not null,          -- case-insensitive regex, maintained by moderators
  action   text not null check (action in ('hold','block')),
  scope    text not null default 'all' check (scope in ('all','matched'))
);

-- ---------------------------------------------------------------------
-- Notifications and AI
-- ---------------------------------------------------------------------
create table push_tokens (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id) on delete cascade,
  token         text not null unique,          -- ExponentPushToken[...]
  platform      text not null check (platform in ('android','ios','web')),
  last_seen_at  timestamptz not null default now()
);
create index push_tokens_user_idx on push_tokens (user_id);

create table notifications (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  kind           notification_kind not null,
  title          text not null,                  -- always lock-screen safe
  body           text not null,
  data           jsonb not null default '{}',    -- deep-link ids only, never content
  scheduled_for  timestamptz not null default now(),
  sent_at        timestamptz,
  read_at        timestamptz,
  created_at     timestamptz not null default now()
);
create index notifications_user_idx on notifications (user_id, created_at desc);
create index notifications_outbox_idx on notifications (scheduled_for) where sent_at is null;

create table ai_insights (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references profiles(id) on delete cascade,
  commitment_id  uuid references commitments(id) on delete cascade,
  kind           insight_kind not null,
  title          text not null check (char_length(title) <= 120),
  body           text not null check (char_length(body) <= 2000),
  suggestion     jsonb,           -- machine-applicable change, e.g. {"check_in_time": "08:00"}
  status         insight_status not null default 'pending',
  period_start   date,
  model          text,
  created_at     timestamptz not null default now(),
  responded_at   timestamptz
);
create index ai_insights_user_idx on ai_insights (user_id, created_at desc);

create table ai_usage (
  id          bigserial primary key,
  user_id     uuid not null references profiles(id) on delete cascade,
  function    text not null,
  tokens_in   int not null default 0,
  tokens_out  int not null default 0,
  created_at  timestamptz not null default now()
);
create index ai_usage_user_day_idx on ai_usage (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- Rate limits: one generic trigger (args: user column, window, max rows)
-- ---------------------------------------------------------------------
create or replace function enforce_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
declare col text := tg_argv[0]; win interval := tg_argv[1]::interval; lim int := tg_argv[2]::int;
        uid uuid; n int;
begin
  execute format('select ($1).%I', col) using new into uid;
  if uid is null or is_service_role() then return new; end if;
  execute format('select count(*) from %I.%I where %I = $1 and created_at > now() - $2',
                 tg_table_schema, tg_table_name, col) using uid, win into n;
  if n >= lim then
    raise exception 'rate_limited' using detail = tg_table_name, hint = 'Try again a little later.';
  end if;
  return new;
end $$;

create trigger rl_messages_hour before insert on messages         for each row execute function enforce_rate_limit('sender_id',  '1 hour', '60');
create trigger rl_messages_day  before insert on messages         for each row execute function enforce_rate_limit('sender_id',  '1 day',  '300');
create trigger rl_requests      before insert on partner_requests for each row execute function enforce_rate_limit('user_id',    '1 day',  '3');
create trigger rl_invites       before insert on invites          for each row execute function enforce_rate_limit('inviter_id', '1 day',  '10');
create trigger rl_reports       before insert on reports          for each row execute function enforce_rate_limit('reporter_id','1 day',  '10');
create trigger rl_support       before insert on support_requests for each row execute function enforce_rate_limit('user_id',    '1 hour', '6');
create trigger rl_commitments   before insert on commitments      for each row execute function enforce_rate_limit('user_id',    '1 day',  '20');
create trigger rl_ai            before insert on ai_usage         for each row execute function enforce_rate_limit('user_id',    '1 day',  '40');

-- ---------------------------------------------------------------------
-- Integrity: a child row must belong to a commitment its user owns
-- ---------------------------------------------------------------------
create or replace function ensure_commitment_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.commitment_id is not null and not exists
     (select 1 from commitments where id = new.commitment_id and user_id = new.user_id) then
    raise exception 'commitment_not_owned';
  end if;
  return new;
end $$;
create trigger own_schedules  before insert or update on commitment_schedules  for each row execute function ensure_commitment_owner();
create trigger own_check_ins  before insert or update on check_ins             for each row execute function ensure_commitment_owner();
create trigger own_progress   before insert or update on progress_logs         for each row execute function ensure_commitment_owner();
create trigger own_milestones before insert or update on milestones            for each row execute function ensure_commitment_owner();
create trigger own_setbacks   before insert or update on setbacks              for each row execute function ensure_commitment_owner();
create trigger own_triggers   before insert or update on triggers              for each row execute function ensure_commitment_owner();
create trigger own_reflect    before insert or update on reflections           for each row execute function ensure_commitment_owner();
create trigger own_support    before insert or update on support_requests      for each row execute function ensure_commitment_owner();
create trigger own_sessions   before insert or update on intervention_sessions for each row execute function ensure_commitment_owner();
create trigger own_insights   before insert or update on ai_insights           for each row execute function ensure_commitment_owner();

create or replace function permissions_owner_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from commitments where id = new.commitment_id and user_id = new.owner_id) then
    raise exception 'commitment_not_owned';
  end if;
  if not exists (select 1 from partnerships where id = new.partnership_id and new.owner_id in (user_a, user_b)) then
    raise exception 'not_a_member';
  end if;
  return new;
end $$;
create trigger own_permissions before insert or update on partner_permissions
  for each row execute function permissions_owner_check();

-- ---------------------------------------------------------------------
-- Check-in side effects: close the occurrence, mark recovery, touch partnerships
-- ---------------------------------------------------------------------
create or replace function check_ins_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare occ occurrences;
begin
  if new.occurrence_id is null then
    select * into occ from occurrences
     where commitment_id = new.commitment_id and new.local_date between period_start and period_end
     limit 1;
    if occ.id is not null then update check_ins set occurrence_id = occ.id where id = new.id; end if;
  else
    select * into occ from occurrences where id = new.occurrence_id;
  end if;

  if occ.id is not null and occ.status <> 'excused' then
    if new.status in ('on_track','completed') then
      update occurrences
         set done_count = done_count + 1,
             status     = (case when done_count + 1 >= target_count then 'done' else 'partial' end)::occurrence_status,
             closed_at  = case when done_count + 1 >= target_count then now() else closed_at end
       where id = occ.id;
    elsif new.status = 'off_track' and occ.status = 'pending' and occ.target_count = 1 then
      update occurrences set status = 'missed', closed_at = now() where id = occ.id;
    end if;
  end if;

  if new.status in ('on_track','completed') then
    update setbacks set recovered_at = now()
     where commitment_id = new.commitment_id and recovered_at is null;
  end if;

  update partnerships set last_activity_a = now() where user_a = new.user_id and status <> 'ended';
  update partnerships set last_activity_b = now() where user_b = new.user_id and status <> 'ended';
  return null;
end $$;
create trigger check_ins_after after insert on check_ins for each row execute function check_ins_after();

-- ---------------------------------------------------------------------
-- Messages: membership, blocks, restrictions, contact sharing, content rules
-- ---------------------------------------------------------------------
create or replace function messages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare p partnerships; other uuid; t record; strict_rules boolean;
begin
  if new.partnership_id is not null then
    select * into p from partnerships where id = new.partnership_id;
    if p.id is null or new.sender_id not in (p.user_a, p.user_b) then raise exception 'not_a_member'; end if;
    if p.status = 'ended' then raise exception 'partnership_ended'; end if;
    other := case when new.sender_id = p.user_a then p.user_b else p.user_a end;
    if is_blocked_between(new.sender_id, other) then raise exception 'blocked'; end if;
  elsif not exists (select 1 from group_members where group_id = new.group_id and user_id = new.sender_id) then
    raise exception 'not_a_member';
  end if;

  if not can_message(new.sender_id) then raise exception 'messaging_restricted'; end if;

  -- Matched strangers and groups cannot share links or move off-platform.
  strict_rules := (p.id is not null and p.origin = 'matched') or new.group_id is not null;
  if strict_rules then
    if new.body ~* '(https?://|www\.|\m[a-z0-9-]+\.(com|ng|net|org|me|io|app|ly|co)\M)' then
      raise exception 'links_not_allowed';
    end if;
    if new.body ~ '\+?[0-9][0-9 ().-]{8,}[0-9]'
       or new.body ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}'
       or new.body ~* '\m(whatsapp|telegram|snapchat|instagram|insta|tiktok|facebook|my number)\M' then
      raise exception 'contact_sharing_not_allowed';
    end if;
  end if;

  for t in select * from moderation_terms loop
    if (t.scope = 'all' or strict_rules) and new.body ~* t.pattern then
      if t.action = 'block' then raise exception 'message_not_allowed'; end if;
      new.status := 'held';
      new.moderation := jsonb_build_object('rule', t.id, 'at', now());
    end if;
  end loop;
  return new;
end $$;
create trigger messages_guard before insert on messages for each row execute function messages_guard();

-- Blocking ends any live partnership between the two people.
create or replace function blocked_users_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update partnerships set status = 'ended', ended_at = now(), ended_by = new.blocker_id, end_reason = 'blocked'
   where status <> 'ended'
     and least(user_a, user_b) = least(new.blocker_id, new.blocked_id)
     and greatest(user_a, user_b) = greatest(new.blocker_id, new.blocked_id);
  return null;
end $$;
create trigger blocked_users_after after insert on blocked_users for each row execute function blocked_users_after();

-- Reports: force the reporter, snapshot evidence, set priority.
create or replace function reports_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare conv uuid; at timestamptz;
begin
  if not is_service_role() then new.reporter_id := auth.uid(); end if;
  new.status := 'open';
  if new.partnership_id is not null and not exists
     (select 1 from partnerships where id = new.partnership_id and new.reporter_id in (user_a, user_b)) then
    raise exception 'not_a_member';
  end if;
  if new.message_id is not null then
    select coalesce(partnership_id, group_id), created_at into conv, at from messages where id = new.message_id;
    select jsonb_agg(jsonb_build_object('id', m.id, 'sender', m.sender_id, 'body', m.body, 'at', m.created_at)
                     order by m.created_at)
      into new.evidence
      from (select * from messages
             where coalesce(partnership_id, group_id) = conv and created_at <= at
             order by created_at desc limit 20) m;
  end if;
  new.priority := case when new.reason in ('minor_safety','self_harm_concern','sexual_content') then 0
                       when new.reason in ('harassment','hate') then 1 else 2 end;
  return new;
end $$;
create trigger reports_before before insert on reports for each row execute function reports_before();

-- Reports: hide the reported message, auto-freeze on urgent reasons or on
-- three independent reports in seven days. A human reviews every freeze.
create or replace function reports_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if new.message_id is not null then
    update messages set status = 'hidden'
     where id = new.message_id and sender_id is distinct from new.reporter_id;
  end if;
  if new.reported_user_id is null then return null; end if;
  select count(distinct reporter_id) into n from reports
   where reported_user_id = new.reported_user_id and created_at > now() - interval '7 days';
  if new.priority = 0 or n >= 3 then
    insert into user_restrictions (user_id, messaging_frozen_until, matching_blocked, note)
    values (new.reported_user_id, now() + interval '7 days', true, 'auto: report ' || new.id)
    on conflict (user_id) do update
      set messaging_frozen_until = greatest(coalesce(user_restrictions.messaging_frozen_until, now()),
                                            excluded.messaging_frozen_until),
          matching_blocked = true, updated_at = now();
  end if;
  return null;
end $$;
create trigger reports_after after insert on reports for each row execute function reports_after();

-- ---------------------------------------------------------------------
-- Scheduler: occurrences ahead, missed periods closed (pg_cron, below)
-- ---------------------------------------------------------------------
create or replace function generate_occurrences(p_days int default 8) returns int
language plpgsql security definer set search_path = public as $$
declare s record; d date; local_today date; made int := 0; n int; wk_start date;
begin
  for s in
    select cs.*, c.start_date, c.end_date
      from commitment_schedules cs
      join commitments c on c.id = cs.commitment_id
     where cs.valid_to is null and c.status = 'active'
       and (c.paused_until is null or c.paused_until < current_date)
  loop
    local_today := (now() at time zone s.timezone)::date;
    if s.frequency = 'one_time' then
      insert into occurrences (commitment_id, user_id, period_start, period_end, due_at)
      values (s.commitment_id, s.user_id, greatest(s.start_date, s.valid_from), s.due_date,
              (s.due_date + s.check_in_time) at time zone s.timezone)
      on conflict do nothing;
      get diagnostics n = row_count; made := made + n;
      continue;
    end if;
    for i in 0 .. p_days - 1 loop
      d := local_today + i;
      continue when d < s.start_date or d < s.valid_from or (s.end_date is not null and d > s.end_date);
      if s.frequency = 'daily'
         or (s.frequency = 'specific_days' and extract(isodow from d)::smallint = any (s.days_of_week)) then
        insert into occurrences (commitment_id, user_id, period_start, period_end, due_at)
        values (s.commitment_id, s.user_id, d, d, (d + s.check_in_time) at time zone s.timezone)
        on conflict do nothing;
        get diagnostics n = row_count; made := made + n;
      elsif s.frequency = 'weekly' and (extract(isodow from d) = 1 or i = 0) then
        wk_start := d - (extract(isodow from d)::int - 1);
        insert into occurrences (commitment_id, user_id, period_start, period_end, due_at, target_count)
        values (s.commitment_id, s.user_id, wk_start, wk_start + 6,
                (wk_start + 6 + s.check_in_time) at time zone s.timezone, s.times_per_week)
        on conflict do nothing;
        get diagnostics n = row_count; made := made + n;
      end if;
    end loop;
  end loop;
  return made;
end $$;

-- A period with no check-in becomes "missed" the morning after it ends
-- (local time), never at midnight, so late check-ins still count.
create or replace function close_missed_occurrences() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update occurrences o
     set status = case when o.done_count > 0 then 'partial' else 'missed' end::occurrence_status,
         closed_at = now()
    from profiles p
   where p.id = o.user_id and o.status = 'pending'
     and now() > ((o.period_end + 1 + time '10:00') at time zone p.timezone);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- RPCs the app calls
-- ---------------------------------------------------------------------

-- Idempotent check-in, safe to retry from the offline queue.
create or replace function log_check_in(
  p_client_id uuid, p_commitment uuid, p_status check_in_status, p_local_date date,
  p_client_created_at timestamptz, p_value numeric default null,
  p_reasons text[] default '{}', p_note text default null)
returns check_ins
language plpgsql security invoker set search_path = public as $$
declare r check_ins;
begin
  if p_local_date > current_date + 1 or p_local_date < current_date - 7 then
    raise exception 'check_in_date_out_of_range';
  end if;
  insert into check_ins (user_id, commitment_id, client_id, status, value, reasons, note, local_date, client_created_at)
  values (auth.uid(), p_commitment, p_client_id, p_status, p_value, coalesce(p_reasons, '{}'), p_note,
          p_local_date, least(p_client_created_at, now()))
  on conflict (user_id, client_id) do nothing;
  select * into r from check_ins where user_id = auth.uid() and client_id = p_client_id;
  return r;
end $$;

-- Journey statistics (owner-only: the view runs with the caller's rights).
create or replace view commitment_stats with (security_invoker = true) as
with closed as (
  select o.commitment_id, o.period_start, (o.status in ('done','partial'))::int as ok
    from occurrences o where o.status in ('done','partial','missed')
), runs as (
  select commitment_id, period_start, ok,
         sum(1 - ok) over (partition by commitment_id order by period_start) as grp
    from closed
), lens as (
  select commitment_id, grp, sum(ok) as len from runs group by commitment_id, grp
)
select c.id as commitment_id, c.user_id,
       coalesce((select l.len from lens l where l.commitment_id = c.id order by l.grp desc limit 1), 0)::int as current_consistency,
       coalesce((select max(l.len) from lens l where l.commitment_id = c.id), 0)::int                        as longest_consistency,
       (select count(*) from closed x where x.commitment_id = c.id and x.ok = 1)::int                        as periods_done,
       (select count(*) from closed x where x.commitment_id = c.id)::int                                     as periods_due,
       (select round(100.0 * count(distinct ci.occurrence_id) / nullif(count(distinct o.id), 0))
          from occurrences o left join check_ins ci on ci.occurrence_id = o.id
         where o.commitment_id = c.id and o.status in ('done','partial','missed'))::int                    as check_in_rate,
       (select count(*) from setbacks s where s.commitment_id = c.id and s.recovered_at is not null)::int   as recovered_setbacks,
       (select count(*) from intervention_sessions i where i.commitment_id = c.id and i.helped)::int        as helpful_interventions
  from commitments c;

-- What a partner may see about the other person, built from permissions only.
create or replace function get_partner_overview(p_partnership uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p partnerships; me uuid := auth.uid(); other uuid; other_identity identity_mode; other_alias text;
        prof profiles; items jsonb; show_active boolean; show_time boolean;
begin
  select * into p from partnerships where id = p_partnership;
  if p.id is null or me is null or me not in (p.user_a, p.user_b) then raise exception 'not_a_member'; end if;
  if me = p.user_a then other := p.user_b; other_identity := p.identity_b; other_alias := p.alias_b;
  else                  other := p.user_a; other_identity := p.identity_a; other_alias := p.alias_a; end if;
  select * into prof from profiles where id = other;

  select coalesce(jsonb_agg(jsonb_build_object(
           'commitment_id', c.id,
           'title',     case when pp.show_title then c.title else 'Personal commitment' end,
           'category',  case when pp.show_category then cat.label end,
           'why',       case when pp.show_why then c.why end,
           'status',    case when pp.show_status then
                          (select ci.status from check_ins ci where ci.commitment_id = c.id
                            order by ci.created_at desc limit 1) end,
           'last_check_in', case when pp.show_status then
                          (select max(ci.created_at) from check_ins ci where ci.commitment_id = c.id) end,
           'progress',  case when pp.show_progress then
                          (select jsonb_build_object('done', count(*) filter (where o.status in ('done','partial')),
                                                     'due',  count(*) filter (where o.status <> 'pending'))
                             from occurrences o where o.commitment_id = c.id and o.period_start > current_date - 30) end,
           'consistency', case when pp.show_consistency then
                          (select s.current_consistency from commitment_stats s where s.commitment_id = c.id) end,
           'notes',     case when pp.show_check_in_notes then
                          (select jsonb_agg(x) from (select ci.local_date, ci.status, ci.note from check_ins ci
                             where ci.commitment_id = c.id and ci.note is not null
                             order by ci.created_at desc limit 5) x) end,
           'setbacks',  case pp.setbacks_detail
                          when 'count' then to_jsonb((select count(*) from setbacks s
                                     where s.commitment_id = c.id and s.occurred_on > current_date - 30))
                          when 'details' then (select jsonb_agg(x) from (
                                     select s.occurred_on, s.reasons, s.recovered_at is not null as recovered
                                       from setbacks s where s.commitment_id = c.id
                                      order by s.occurred_on desc limit 5) x)
                        end
         ) order by c.created_at), '[]'::jsonb),
         bool_or(pp.show_last_active), bool_or(pp.show_local_time)
    into items, show_active, show_time
    from partner_permissions pp
    join commitments c on c.id = pp.commitment_id and c.status in ('active','paused','completed')
    join categories cat on cat.slug = c.category_slug
   where pp.partnership_id = p.id and pp.owner_id = other;

  return jsonb_build_object(
    'partnership_id', p.id,
    'status',         p.status,
    'display_name',   case other_identity
                        when 'identified' then coalesce(prof.full_name, prof.nickname, other_alias)
                        when 'nickname'   then coalesce(prof.nickname, other_alias)
                        else other_alias end,
    'last_active',    case when show_active then
                        case when me = p.user_a then p.last_activity_b else p.last_activity_a end end,
    'local_time',     case when show_time then to_char(now() at time zone prof.timezone, 'HH24:MI') end,
    'commitments',    items);
end $$;

-- End a partnership: either person, any time, no reason required.
create or replace function end_partnership(p_partnership uuid, p_reason text default 'other')
returns void language plpgsql security definer set search_path = public as $$
declare p partnerships; other uuid;
begin
  select * into p from partnerships where id = p_partnership;
  if p.id is null or auth.uid() is null or auth.uid() not in (p.user_a, p.user_b) then raise exception 'not_a_member'; end if;
  if p.status = 'ended' then return; end if;
  update partnerships set status = 'ended', ended_at = now(), ended_by = auth.uid(),
         end_reason = coalesce(p_reason, 'other') where id = p.id;
  other := case when auth.uid() = p.user_a then p.user_b else p.user_a end;
  insert into notifications (user_id, kind, title, body, data)
  values (other, 'match', 'Your partnership has ended',
          'You can find a new partner whenever you are ready.', jsonb_build_object('partnership_id', p.id));
end $$;

-- Change how I appear to one partner (e.g. reveal a nickname after trust grows).
create or replace function set_partnership_identity(p_partnership uuid, p_mode identity_mode)
returns void language plpgsql security definer set search_path = public as $$
begin
  update partnerships set identity_a = p_mode where id = p_partnership and user_a = auth.uid();
  update partnerships set identity_b = p_mode where id = p_partnership and user_b = auth.uid();
end $$;

-- Accept an invite by its link token.
create or replace function accept_invite(p_token text) returns uuid
language plpgsql security definer set search_path = public as $$
declare i invites; pid uuid; me uuid := auth.uid();
begin
  select * into i from invites where token_hash = encode(digest(p_token, 'sha256'), 'hex') for update;
  if i.id is null or i.status <> 'pending' or i.expires_at < now() then raise exception 'invite_invalid'; end if;
  if me is null or i.inviter_id = me or is_blocked_between(i.inviter_id, me) then raise exception 'invite_invalid'; end if;
  if exists (select 1 from profiles where id in (me, i.inviter_id) and (age_band is null or age_band = 'under_18')) then
    raise exception 'age_not_supported';
  end if;
  update invites set status = 'accepted', accepted_by = me where id = i.id;

  if i.kind = 'partner' then
    insert into partnerships (user_a, user_b, origin, status, identity_a, identity_b, sensitivity)
    values (i.inviter_id, me, 'invite', 'active', 'nickname', 'nickname',
            coalesce((select sensitivity from commitments where id = i.commitment_id), 'standard'))
    returning id into pid;
    if i.commitment_id is not null then
      insert into partner_permissions (partnership_id, owner_id, commitment_id, show_title, show_category)
      select pid, i.inviter_id, c.id, c.sensitivity = 'standard', c.sensitivity = 'standard'
        from commitments c where c.id = i.commitment_id;
    end if;
    insert into notifications (user_id, kind, title, body, data)
    values (i.inviter_id, 'invite', 'Your invite was accepted', 'Your friend is now your accountability partner.',
            jsonb_build_object('partnership_id', pid));
    return pid;
  elsif i.kind = 'trusted' then
    update trusted_contacts set linked_user_id = me where id = i.trusted_contact_id and user_id = i.inviter_id;
    return i.trusted_contact_id;
  else
    if (select count(*) from group_members where group_id = i.group_id)
       >= (select max_members from groups where id = i.group_id) then raise exception 'group_full'; end if;
    insert into group_members (group_id, user_id) values (i.group_id, me) on conflict do nothing;
    return i.group_id;
  end if;
end $$;

-- What a linked trusted person sees: templated status lines, never content.
create or replace function get_trusted_updates() returns table (owner_label text, line text, at timestamptz)
language sql stable security definer set search_path = public as $$
  select coalesce(p.nickname, 'Your friend'),
         case ci.status when 'on_track' then 'checked in: on track today'
                        when 'completed' then 'completed today''s commitment'
                        else 'checked in today' end,
         ci.created_at
    from trusted_contacts t
    join profiles p on p.id = t.user_id
    join check_ins ci on ci.user_id = t.user_id and ci.commitment_id = any (t.commitment_ids)
   where t.linked_user_id = auth.uid() and t.share_completions
     and ci.status in ('on_track','completed') and ci.created_at > now() - interval '14 days'
   order by ci.created_at desc limit 50
$$;

-- ---------------------------------------------------------------------
-- Matching (pg_cron every 10 minutes, plus right after each request).
-- Hard filters never relax; soft factors score and loosen with waiting time.
-- ---------------------------------------------------------------------
create or replace function match_score(a partner_requests, b partner_requests) returns int
language sql immutable as $$
  select (case when a.category_slug = b.category_slug then 30 else 12 end)
       + (case when abs(a.utc_offset_minutes - b.utc_offset_minutes) <= 60  then 20
               when abs(a.utc_offset_minutes - b.utc_offset_minutes) <= 180 then 12
               when abs(a.utc_offset_minutes - b.utc_offset_minutes) <= 360 then 4 else 0 end)
       + (case when a.check_in_frequency = b.check_in_frequency then 15 else 0 end)
       + (case when a.availability && b.availability then 10 else 0 end)
       + (case when a.style = b.style then 10 else 3 end)
       + (case when a.age_band = b.age_band then 8 else 0 end)
       + (case when a.experience = b.experience then 4 when 'experienced' in (a.experience, b.experience) then 3 else 0 end)
       + (case when a.identity_mode = b.identity_mode then 3 else 0 end)
$$;

create or replace function live_partner_count(u uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from partnerships where u in (user_a, user_b) and status <> 'ended'
$$;

create or replace function run_matching() returns int
language plpgsql security definer set search_path = public as $$
declare r partner_requests; best partner_requests; made int := 0; pid uuid; min_score int;
begin
  update partner_requests set status = 'expired' where status = 'queued' and expires_at < now();
  update partner_requests
     set relax_level = case when created_at < now() - interval '72 hours' then 2
                            when created_at < now() - interval '24 hours' then 1 else 0 end
   where status = 'queued';

  for r in select * from partner_requests where status = 'queued' order by created_at loop
    continue when (select status from partner_requests where id = r.id) <> 'queued';
    min_score := case r.relax_level when 0 then 55 when 1 then 40 else 25 end;

    select c.* into best from partner_requests c
     where c.status = 'queued' and c.id <> r.id and c.user_id <> r.user_id
       -- hard filters ------------------------------------------------
       and r.age_band <> 'under_18' and c.age_band <> 'under_18'
       and abs(array_position(enum_range(null::age_band), r.age_band)
             - array_position(enum_range(null::age_band), c.age_band)) <= 1
       and c.family = r.family
       and c.sensitivity = r.sensitivity
       and (r.sensitivity <> 'sensitive' or c.category_slug = r.category_slug)
       and (case when r.gender_preference = 'same' or c.gender_preference = 'same'
                 then r.gender = c.gender and r.gender <> 'prefer_not' else true end)
       and r.languages && c.languages
       and not is_blocked_between(r.user_id, c.user_id)
       and not exists (select 1 from partnerships x
                        where least(x.user_a, x.user_b) = least(r.user_id, c.user_id)
                          and greatest(x.user_a, x.user_b) = greatest(r.user_id, c.user_id))
       and not exists (select 1 from user_restrictions u where u.user_id in (r.user_id, c.user_id)
                          and (u.matching_blocked or u.banned or coalesce(u.suspended_until, '-infinity') > now()))
       and live_partner_count(r.user_id) < 2 and live_partner_count(c.user_id) < 2
       -- soft factors ------------------------------------------------
       and match_score(r, c) >= least(min_score, case c.relax_level when 0 then 55 when 1 then 40 else 25 end)
     order by match_score(r, c) desc, c.created_at
     limit 1;

    if best.id is not null then
      insert into partnerships (user_a, user_b, origin, status, identity_a, identity_b, sensitivity)
      values (r.user_id, best.user_id, 'matched', 'trial', r.identity_mode, best.identity_mode, r.sensitivity)
      returning id into pid;
      update partner_requests set status = 'matched', partnership_id = pid where id in (r.id, best.id);
      insert into partner_permissions (partnership_id, owner_id, commitment_id)
      values (pid, r.user_id, r.commitment_id), (pid, best.user_id, best.commitment_id);
      insert into notifications (user_id, kind, title, body, data)
      select u, 'match', 'You have a partner',
             'Someone with a similar goal is ready to keep you accountable.', jsonb_build_object('partnership_id', pid)
        from unnest(array[r.user_id, best.user_id]) u;
      made := made + 1;
    end if;
    best := null;
  end loop;
  return made;
end $$;

-- ---------------------------------------------------------------------
-- Row Level Security: every table on, owner-only unless stated
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','app_roles','user_restrictions','categories','mission_templates',
    'interventions','crisis_resources','commitments','commitment_schedules','occurrences','check_ins',
    'progress_logs','milestones','setbacks','triggers','reflections','partner_requests','partnerships',
    'partner_permissions','groups','group_members','invites','trusted_contacts','messages',
    'support_requests','intervention_sessions','blocked_users','mutes','reports','moderation_actions',
    'moderation_terms','push_tokens','notifications','ai_insights','ai_usage']
  loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- profiles: yourself only. Others see you only through get_partner_overview and aliases.
create policy profiles_self_select on profiles for select to authenticated using (id = auth.uid() or is_moderator());
create policy profiles_self_update on profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- roles and restrictions: read your own; written by the service role only.
create policy app_roles_self    on app_roles         for select to authenticated using (user_id = auth.uid());
create policy restrictions_self on user_restrictions for select to authenticated using (user_id = auth.uid() or is_moderator());

-- reference data
create policy categories_read        on categories        for select to authenticated using (is_active);
create policy mission_templates_read on mission_templates for select to authenticated using (true);
create policy crisis_read            on crisis_resources  for select to anon, authenticated using (true);
create policy interventions_read     on interventions     for select to authenticated
  using (is_active and (owner_id is null or owner_id = auth.uid()));
create policy interventions_own_write on interventions    for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- owner-only personal tables
create policy commitments_owner on commitments           for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy schedules_owner   on commitment_schedules  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy check_ins_owner   on check_ins             for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy progress_owner    on progress_logs         for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy milestones_owner  on milestones            for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy setbacks_owner    on setbacks              for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy triggers_owner    on triggers              for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy reflections_owner on reflections           for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy trusted_owner     on trusted_contacts      for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy sessions_owner    on intervention_sessions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy support_owner     on support_requests      for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy push_tokens_owner on push_tokens           for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy mutes_owner       on mutes                 for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- occurrences: generated by the scheduler; the owner reads them and may excuse one (illness, travel).
create policy occurrences_read   on occurrences for select to authenticated using (user_id = auth.uid());
create policy occurrences_excuse on occurrences for update to authenticated
  using (user_id = auth.uid() and status in ('pending','missed')) with check (user_id = auth.uid() and status = 'excused');

-- partner requests: create, read and cancel your own; matching writes the rest.
create policy requests_read   on partner_requests for select to authenticated using (user_id = auth.uid());
create policy requests_insert on partner_requests for insert to authenticated with check (user_id = auth.uid() and status = 'queued');
create policy requests_cancel on partner_requests for update to authenticated
  using (user_id = auth.uid() and status = 'queued') with check (user_id = auth.uid() and status = 'cancelled');

-- partnerships: both members read; changes only via end_partnership / accept_invite / run_matching.
create policy partnerships_read on partnerships for select to authenticated using (auth.uid() in (user_a, user_b));

-- permissions: the owner controls; the partner can read which fields are shared.
create policy permissions_owner   on partner_permissions for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy permissions_partner on partner_permissions for select to authenticated using (is_partner_member(partnership_id));

-- invites: the inviter manages their own; acceptance goes through accept_invite().
create policy invites_owner on invites for all to authenticated using (inviter_id = auth.uid()) with check (inviter_id = auth.uid());

-- groups: members only.
create policy groups_read   on groups for select to authenticated using (is_group_member(id));
create policy groups_insert on groups for insert to authenticated with check (owner_id = auth.uid());
create policy groups_update on groups for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy group_members_read  on group_members for select to authenticated using (is_group_member(group_id));
create policy group_members_leave on group_members for delete to authenticated using (user_id = auth.uid());

-- messages: members read visible messages (a sender also sees their own held ones), minus blocked senders.
create policy messages_read on messages for select to authenticated using (
  ((partnership_id is not null and is_partner_member(partnership_id))
    or (group_id is not null and is_group_member(group_id)))
  and (status = 'visible' or sender_id = auth.uid())
  and not exists (select 1 from blocked_users b where b.blocker_id = auth.uid() and b.blocked_id = messages.sender_id));
create policy messages_send on messages for insert to authenticated with check (
  sender_id = auth.uid() and status = 'visible'
  and ((partnership_id is not null and is_partner_member(partnership_id))
       or (group_id is not null and is_group_member(group_id))));
create policy messages_mod on messages for select to authenticated using (is_moderator());

-- safety
create policy blocks_owner       on blocked_users      for all    to authenticated using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());
create policy reports_insert     on reports            for insert to authenticated with check (true);  -- reporter forced by trigger
create policy reports_read       on reports            for select to authenticated using (reporter_id = auth.uid() or is_moderator());
create policy reports_mod_update on reports            for update to authenticated using (is_moderator()) with check (is_moderator());
create policy mod_actions_mod    on moderation_actions for all    to authenticated using (is_moderator()) with check (is_moderator());
-- moderation_terms has no policy: only the service role reads or writes it.

-- notifications: read and mark-read your own; created by functions and Edge Functions.
create policy notifications_read on notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_mark on notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- AI: read and respond to your own insights; written by Edge Functions (service role).
create policy insights_read    on ai_insights for select to authenticated using (user_id = auth.uid());
create policy insights_respond on ai_insights for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy insights_delete  on ai_insights for delete to authenticated using (user_id = auth.uid());
create policy ai_usage_read    on ai_usage    for select to authenticated using (user_id = auth.uid());

-- Function execution rights: signed-in users get the app RPCs; scheduler and matching are service/cron only.
revoke execute on all functions in schema public from public, anon;
grant execute on function log_check_in(uuid, uuid, check_in_status, date, timestamptz, numeric, text[], text) to authenticated;
grant execute on function get_partner_overview(uuid)                to authenticated;
grant execute on function end_partnership(uuid, text)               to authenticated;
grant execute on function set_partnership_identity(uuid, identity_mode) to authenticated;
grant execute on function accept_invite(text)                       to authenticated;
grant execute on function get_trusted_updates()                     to authenticated;
grant execute on function is_moderator(), is_partner_member(uuid), is_group_member(uuid),
                          is_blocked_between(uuid, uuid), can_message(uuid), random_alias(),
                          is_service_role(), live_partner_count(uuid) to authenticated;
revoke execute on function run_matching(), generate_occurrences(int), close_missed_occurrences() from authenticated;

-- ---------------------------------------------------------------------
-- Seed data
-- ---------------------------------------------------------------------
insert into categories (slug, family, label, sensitivity, default_kind, faith, sort) values
  ('unwanted_habit','stop','An unwanted habit','personal','stop',false,10),
  ('pornography','stop','Pornography','sensitive','stop',false,11),
  ('masturbation','stop','Masturbation','sensitive','stop',false,12),
  ('social_media','stop','Excessive social media','standard','stop',false,13),
  ('gaming','stop','Gaming','standard','stop',false,14),
  ('gambling','stop','Gambling','sensitive','stop',false,15),
  ('substances','stop','Smoking or substances','sensitive','stop',false,16),
  ('procrastination','stop','Procrastination','standard','stop',false,17),
  ('exercise','start','Exercise','standard','start',false,20),
  ('reading','start','Reading','standard','start',false,21),
  ('prayer','start','Prayer','standard','start',true,22),
  ('studying','start','Studying','standard','start',false,23),
  ('journaling','start','Journaling','standard','start',false,24),
  ('creating','start','Creating','standard','start',false,25),
  ('healthy_routines','start','Healthy routines','standard','start',false,26),
  ('sleep','start','Sleep','standard','start',false,27),
  ('disciplined','become','More disciplined','standard','become',false,30),
  ('consistent','become','More consistent','standard','become',false,31),
  ('focused','become','More focused','standard','become',false,32),
  ('communicator','become','A better communicator','standard','become',false,33),
  ('professional','become','A better professional','standard','become',false,34),
  ('leader','become','A better leader','standard','become',false,35),
  ('exam','achieve','Pass an exam','standard','achieve',false,40),
  ('finish_book','achieve','Finish a book','standard','achieve',false,41),
  ('build_project','achieve','Build a project','standard','achieve',false,42),
  ('launch_business','achieve','Launch a business','standard','achieve',false,43),
  ('find_job','achieve','Find a job','standard','achieve',false,44),
  ('save_money','achieve','Save money','personal','achieve',false,45),
  ('complete_course','achieve','Complete a course','standard','achieve',false,46),
  ('relationships','become','Relationships','personal','become',false,36),
  ('custom','other','Something else','standard','start',false,90);

insert into mission_templates (slug, label, duration_days, description, is_comeback) values
  ('mission_7','7-Day Mission',7,'A short, focused start.',false),
  ('mission_30','30-Day Mission',30,'Long enough to build a rhythm.',false),
  ('mission_90','90-Day Mission',90,'A real change, one day at a time.',false),
  ('personal','Personal Mission',null,'Your own length, your own terms.',false),
  ('comeback','Comeback Mission',7,'A gentle restart after a setback.',true);

insert into crisis_resources (country_code, name, phone, url, hours, sort, verified_at) values
  ('NG','Emergency services (Nigeria)','112',null,'24 hours',1,'2026-10-05'),
  ('NG','SURPIN suicide prevention helpline (toll-free)','0800 078 7746','https://findahelpline.com/organizations/surpin-suicide-research-prevention-initiative','24 hours',2,'2026-10-05'),
  ('NG','Mentally Aware Nigeria Initiative (MANI)','0809 111 6264','https://mentallyaware.org','See website',3,'2026-10-05'),
  (null,'Find a free helpline in your country',null,'https://findahelpline.com','24 hours',10,'2026-10-05');

insert into interventions (slug, title, steps, duration_seconds, for_reasons) values
  ('step_away','Step away for two minutes',
   '[{"text":"Stand up and leave the room you are in.","seconds":20},{"text":"Drink a glass of water slowly.","seconds":40},{"text":"Breathe in for 4, hold for 4, out for 6. Five times.","seconds":60}]',
   120,'{tempted,stressed,overwhelmed}'),
  ('remember_why','Read your why',
   '[{"text":"Read the reason you wrote when you made this commitment.","seconds":30},{"text":"Picture tomorrow morning if you keep it today.","seconds":30},{"text":"Choose the next small step.","seconds":30}]',
   90,'{lost_motivation,tempted,bored}'),
  ('five_minutes','Just five minutes',
   '[{"text":"Set a five-minute timer.","seconds":10},{"text":"Do only the first, smallest part of the task.","seconds":300},{"text":"When it rings, decide if you will do five more.","seconds":10}]',
   320,'{distracted,tired,overwhelmed,bored}'),
  ('change_room','Change your environment',
   '[{"text":"Move to a public or shared space.","seconds":60},{"text":"Put your phone in another room or switch on focus mode.","seconds":30},{"text":"Tell yourself what you will do for the next 20 minutes.","seconds":30}]',
   120,'{tempted,distracted}');

-- ---------------------------------------------------------------------
-- Scheduled jobs (Supabase: Database > Extensions > enable pg_cron, then run)
-- ---------------------------------------------------------------------
-- select cron.schedule('occurrences-ahead', '15 * * * *',   $$select generate_occurrences(8)$$);
-- select cron.schedule('close-missed',      '5,35 * * * *', $$select close_missed_occurrences()$$);
-- select cron.schedule('matching',          '*/10 * * * *', $$select run_matching()$$);
-- Reminders, push delivery and the weekly review run in Edge Functions
-- (send-notifications every 5 min, weekly-review hourly for users whose
-- local time is Sunday 18:00), invoked by pg_cron + pg_net.
