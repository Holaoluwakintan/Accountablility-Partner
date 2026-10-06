
-- Accountability Partner V1 (MVP) schema. Lives in the Blossom Supabase project, public schema, every object prefixed ap_.
-- Subset of docs/schema.sql (Phase 0). RLS on every table. Partners never read owner tables; they read ap_partner_view().

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- profiles
create table if not exists ap_profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  display_name   text check (display_name is null or char_length(display_name) between 1 and 40),
  birth_year     smallint not null,
  faith_enabled  boolean not null default false,
  timezone       text not null default 'Africa/Lagos',
  onboarded      boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create or replace function ap__profile_guard() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.birth_year <> old.birth_year then
    raise exception 'birth_year_locked';
  end if;
  if new.birth_year > extract(year from now())::int - 18 or new.birth_year < 1900 then
    raise exception 'adults_only';
  end if;
  if new.timezone is null or not exists (select 1 from pg_timezone_names where name = new.timezone) then
    new.timezone := 'Africa/Lagos';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists ap_profiles_guard on ap_profiles;
create trigger ap_profiles_guard before insert or update on ap_profiles for each row execute function ap__profile_guard();

-- ---------------------------------------------------------------- reference data
create table if not exists ap_categories (
  slug         text primary key,
  family       text not null check (family in ('stop','start','become','achieve','other')),
  label        text not null,
  sensitivity  text not null default 'standard' check (sensitivity in ('standard','personal','sensitive')),
  faith        boolean not null default false,
  featured     boolean not null default false,
  sort         smallint not null default 100
);

create table if not exists ap_crisis_resources (
  id            uuid primary key default gen_random_uuid(),
  country_code  char(2),
  region        text,
  name          text not null,
  phone         text,
  url           text,
  hours         text,
  sort          smallint not null default 100,
  verified_at   date not null
);

-- ---------------------------------------------------------------- commitments
create table if not exists ap_commitments (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references ap_profiles(id) on delete cascade,
  title          text not null check (char_length(btrim(title)) between 1 and 120),
  why            text check (why is null or char_length(why) <= 1000),
  category_slug  text not null references ap_categories(slug),
  kind           text not null check (kind in ('stop','start','become','achieve')),
  measure        text not null default 'binary' check (measure in ('binary','quantity','duration')),
  target_value   numeric check (target_value is null or target_value > 0),
  target_unit    text check (target_unit is null or char_length(target_unit) <= 24),
  days           smallint[] not null default '{0,1,2,3,4,5,6}',
  checkin_time   time not null default '20:00',
  start_date     date not null,
  status         text not null default 'active' check (status in ('active','paused','completed','ended')),
  sensitivity    text not null default 'standard' check (sensitivity in ('standard','personal','sensitive')),
  comeback_until date,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint ap_days_valid check (array_length(days,1) between 1 and 7 and days <@ '{0,1,2,3,4,5,6}'::smallint[])
);
create index if not exists ap_commitments_user on ap_commitments(user_id);

-- Versioned plan: a plan change closes the old row so past rates stay true.
create table if not exists ap_schedules (
  id             uuid primary key default gen_random_uuid(),
  commitment_id  uuid not null references ap_commitments(id) on delete cascade,
  user_id        uuid not null references ap_profiles(id) on delete cascade,
  days           smallint[] not null,
  target_value   numeric,
  checkin_time   time not null,
  valid_from     date not null,
  valid_to       date,
  reason         text,
  created_at     timestamptz not null default now()
);
create index if not exists ap_schedules_c on ap_schedules(commitment_id, valid_from);

create or replace function ap__local_today(p_user uuid) returns date language sql stable security definer set search_path = public as $$
  select (now() at time zone coalesce((select timezone from ap_profiles where id = p_user), 'Africa/Lagos'))::date
$$;

create or replace function ap__commitment_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare cat_sens text;
begin
  select sensitivity into cat_sens from ap_categories where slug = new.category_slug;
  if tg_op = 'INSERT' then
    new.user_id := auth.uid();
    -- start date is the owner's local today (never backdated by the client), so rates stay honest
    if new.start_date is null or new.start_date < ap__local_today(new.user_id) - 1 or new.start_date > ap__local_today(new.user_id) + 1 then
      new.start_date := ap__local_today(new.user_id);
    end if;
    -- sensitivity is inherited from the category; it can be raised, never lowered
    if array_position(array['standard','personal','sensitive'], new.sensitivity) < array_position(array['standard','personal','sensitive'], cat_sens) then
      new.sensitivity := cat_sens;
    end if;
  else
    new.user_id := old.user_id; new.start_date := old.start_date; new.created_at := old.created_at;
    if array_position(array['standard','personal','sensitive'], new.sensitivity) < array_position(array['standard','personal','sensitive'], old.sensitivity) then
      new.sensitivity := old.sensitivity;
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists ap_commitments_guard on ap_commitments;
create trigger ap_commitments_guard before insert or update on ap_commitments for each row execute function ap__commitment_guard();

create or replace function ap__commitment_first_schedule() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into ap_schedules (commitment_id, user_id, days, target_value, checkin_time, valid_from, reason)
  values (new.id, new.user_id, new.days, new.target_value, new.checkin_time, new.start_date, 'created');
  return new;
end $$;
drop trigger if exists ap_commitments_first_schedule on ap_commitments;
create trigger ap_commitments_first_schedule after insert on ap_commitments for each row execute function ap__commitment_first_schedule();

-- ---------------------------------------------------------------- check-ins and setbacks (history is never deleted by the app)
create table if not exists ap_check_ins (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references ap_profiles(id) on delete cascade,
  commitment_id  uuid not null references ap_commitments(id) on delete cascade,
  local_date     date not null,
  status         text not null check (status in ('done','partial','missed','struggling')),
  value          numeric check (value is null or value >= 0),
  note           text check (note is null or char_length(note) <= 500),
  client_id      text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (commitment_id, local_date)
);
create index if not exists ap_check_ins_user on ap_check_ins(user_id, local_date);

create or replace function ap__checkin_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare t date;
begin
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id; new.commitment_id := old.commitment_id; new.local_date := old.local_date; new.created_at := old.created_at;
  else
    new.user_id := auth.uid();
  end if;
  if not exists (select 1 from ap_commitments where id = new.commitment_id and user_id = new.user_id) then
    raise exception 'not_your_commitment';
  end if;
  t := ap__local_today(new.user_id);
  if tg_op = 'INSERT' and (new.local_date > t + 1 or new.local_date < t - 3) then
    raise exception 'date_out_of_range';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists ap_check_ins_guard on ap_check_ins;
create trigger ap_check_ins_guard before insert or update on ap_check_ins for each row execute function ap__checkin_guard();

create table if not exists ap_setbacks (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references ap_profiles(id) on delete cascade,
  commitment_id  uuid not null references ap_commitments(id) on delete cascade,
  local_date     date not null,
  source         text not null check (source in ('struggling','missed')),
  reasons        text[] not null default '{}',
  before_note    text check (before_note is null or char_length(before_note) <= 500),  -- private, never shared, never sent to AI
  changes        text[] not null default '{}',
  recovered_at   timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists ap_setbacks_c on ap_setbacks(commitment_id, local_date);

create or replace function ap__setback_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id; new.commitment_id := old.commitment_id; new.local_date := old.local_date;
    new.created_at := old.created_at;   -- recovered_at is not user-writable (column privileges); the system trigger sets it
  else
    new.user_id := auth.uid(); new.recovered_at := null;
    if not exists (select 1 from ap_commitments where id = new.commitment_id and user_id = new.user_id) then
      raise exception 'not_your_commitment';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ap_setbacks_guard on ap_setbacks;
create trigger ap_setbacks_guard before insert or update on ap_setbacks for each row execute function ap__setback_guard();

-- A setback is recovered at the next on-track check-in (same day counts if the day turns around).
create or replace function ap__mark_recovered() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('done','partial') then
    update ap_setbacks set recovered_at = now()
     where commitment_id = new.commitment_id and recovered_at is null and local_date <= new.local_date
       and created_at < now();
  end if;
  return new;
end $$;
drop trigger if exists ap_check_ins_recover on ap_check_ins;
create trigger ap_check_ins_recover after insert or update on ap_check_ins for each row execute function ap__mark_recovered();

-- ---------------------------------------------------------------- partners (invited friends in V1)
create table if not exists ap_invites (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references ap_profiles(id) on delete cascade,
  commitment_id  uuid not null references ap_commitments(id) on delete cascade,
  label          text check (label is null or char_length(label) <= 40),
  token_hash     text not null unique,
  expires_at     timestamptz not null default now() + interval '7 days',
  used_by        uuid references ap_profiles(id) on delete set null,
  used_at        timestamptz,
  created_at     timestamptz not null default now()
);

create table if not exists ap_partnerships (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references ap_profiles(id) on delete cascade,
  partner_id     uuid not null references ap_profiles(id) on delete cascade,
  commitment_id  uuid not null references ap_commitments(id) on delete cascade,
  owner_label    text,          -- the owner's private name for the partner ("Tolu")
  owner_alias    text not null, -- what the partner sees for the owner
  partner_alias  text not null, -- what the owner sees for the partner
  status         text not null default 'active' check (status in ('active','frozen','ended')),
  keep_owner     boolean,
  keep_partner   boolean,
  created_at     timestamptz not null default now(),
  ended_at       timestamptz,
  constraint ap_not_self check (owner_id <> partner_id)
);
create unique index if not exists ap_partnerships_one_live on ap_partnerships(commitment_id, partner_id) where status <> 'ended';

create table if not exists ap_partner_permissions (
  partnership_id     uuid primary key references ap_partnerships(id) on delete cascade,
  owner_id           uuid not null references ap_profiles(id) on delete cascade,
  show_status        boolean not null default true,
  show_progress      boolean not null default true,
  show_consistency   boolean not null default true,
  show_last_active   boolean not null default true,
  show_title         boolean not null default true,
  show_category      boolean not null default true,
  show_why           boolean not null default false,
  show_notes         boolean not null default false,
  setbacks           text not null default 'none' check (setbacks in ('none','count')),
  updated_at         timestamptz not null default now()
);

create or replace function ap__perm_guard() returns trigger language plpgsql set search_path = public as $$
begin
  new.partnership_id := old.partnership_id; new.owner_id := old.owner_id; new.updated_at := now();
  return new;
end $$;
drop trigger if exists ap_perm_guard on ap_partner_permissions;
create trigger ap_perm_guard before update on ap_partner_permissions for each row execute function ap__perm_guard();

create table if not exists ap_messages (
  id              uuid primary key default gen_random_uuid(),
  partnership_id  uuid not null references ap_partnerships(id) on delete cascade,
  sender_id       uuid references ap_profiles(id) on delete set null,
  recipient_id    uuid not null references ap_profiles(id) on delete cascade,
  kind            text not null check (kind in ('cheer','message','sos','checkin_request','system')),
  body            text check (body is null or char_length(body) <= 280),
  created_at      timestamptz not null default now(),
  read_at         timestamptz
);
create index if not exists ap_messages_r on ap_messages(recipient_id, created_at desc);
create index if not exists ap_messages_p on ap_messages(partnership_id, created_at desc);

create table if not exists ap_support_requests (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references ap_profiles(id) on delete cascade,
  commitment_id      uuid references ap_commitments(id) on delete set null,
  partners_notified  int not null default 0,
  created_at         timestamptz not null default now()
);

create table if not exists ap_reports (
  id              uuid primary key default gen_random_uuid(),
  reporter_id     uuid not null default auth.uid() references ap_profiles(id) on delete cascade,
  partnership_id  uuid references ap_partnerships(id) on delete set null,
  reason          text not null check (reason in ('harassment','sexual','spam','unsafe','other')),
  details         text check (details is null or char_length(details) <= 1000),
  status          text not null default 'open' check (status in ('open','reviewed','actioned','dismissed')),
  emailed_at      timestamptz,
  created_at      timestamptz not null default now()
);

create or replace function ap__report_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.reporter_id := auth.uid(); new.status := 'open'; new.emailed_at := null;
  if new.partnership_id is not null and not exists (
    select 1 from ap_partnerships where id = new.partnership_id and auth.uid() in (owner_id, partner_id)) then
    raise exception 'not_your_partnership';
  end if;
  return new;
end $$;
drop trigger if exists ap_reports_guard on ap_reports;
create trigger ap_reports_guard before insert on ap_reports for each row execute function ap__report_guard();

-- Reports freeze messaging on that partnership instantly; a human decides what happens next.
create or replace function ap__report_freeze() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.partnership_id is not null then
    update ap_partnerships set status = 'frozen' where id = new.partnership_id and status = 'active';
  end if;
  return new;
end $$;
drop trigger if exists ap_reports_freeze on ap_reports;
create trigger ap_reports_freeze after insert on ap_reports for each row execute function ap__report_freeze();

-- ---------------------------------------------------------------- RLS
alter table ap_profiles enable row level security;
alter table ap_categories enable row level security;
alter table ap_crisis_resources enable row level security;
alter table ap_commitments enable row level security;
alter table ap_schedules enable row level security;
alter table ap_check_ins enable row level security;
alter table ap_setbacks enable row level security;
alter table ap_invites enable row level security;
alter table ap_partnerships enable row level security;
alter table ap_partner_permissions enable row level security;
alter table ap_messages enable row level security;
alter table ap_support_requests enable row level security;
alter table ap_reports enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies where schemaname='public' and tablename like 'ap\_%' loop
    execute format('drop policy %I on %I', r.policyname, r.tablename);
  end loop;
end $$;

create policy ap_profiles_own_select on ap_profiles for select to authenticated using (id = auth.uid());
create policy ap_profiles_own_insert on ap_profiles for insert to authenticated with check (id = auth.uid());
create policy ap_profiles_own_update on ap_profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy ap_profiles_own_delete on ap_profiles for delete to authenticated using (id = auth.uid());

create policy ap_categories_read on ap_categories for select to anon, authenticated using (true);
create policy ap_crisis_read on ap_crisis_resources for select to anon, authenticated using (true);

create policy ap_commitments_own_select on ap_commitments for select to authenticated using (user_id = auth.uid());
create policy ap_commitments_own_insert on ap_commitments for insert to authenticated with check (user_id = auth.uid());
create policy ap_commitments_own_update on ap_commitments for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy ap_schedules_own_select on ap_schedules for select to authenticated using (user_id = auth.uid());

create policy ap_check_ins_own_select on ap_check_ins for select to authenticated using (user_id = auth.uid());
create policy ap_check_ins_own_insert on ap_check_ins for insert to authenticated with check (user_id = auth.uid());
create policy ap_check_ins_own_update on ap_check_ins for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy ap_setbacks_own_select on ap_setbacks for select to authenticated using (user_id = auth.uid());
create policy ap_setbacks_own_insert on ap_setbacks for insert to authenticated with check (user_id = auth.uid());
create policy ap_setbacks_own_update on ap_setbacks for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy ap_invites_own_select on ap_invites for select to authenticated using (owner_id = auth.uid());

create policy ap_partnerships_member_select on ap_partnerships for select to authenticated using (auth.uid() in (owner_id, partner_id));

create policy ap_perms_owner_select on ap_partner_permissions for select to authenticated using (owner_id = auth.uid());
create policy ap_perms_owner_update on ap_partner_permissions for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy ap_messages_member_select on ap_messages for select to authenticated using (auth.uid() in (sender_id, recipient_id));

create policy ap_support_own_select on ap_support_requests for select to authenticated using (user_id = auth.uid());

create policy ap_reports_own_insert on ap_reports for insert to authenticated with check (reporter_id = auth.uid());
create policy ap_reports_own_select on ap_reports for select to authenticated using (reporter_id = auth.uid());

-- column-level hardening: only harmless columns are writable directly
revoke all on ap_profiles, ap_categories, ap_crisis_resources, ap_commitments, ap_schedules, ap_check_ins, ap_setbacks,
  ap_invites, ap_partnerships, ap_partner_permissions, ap_messages, ap_support_requests, ap_reports from anon, authenticated;
grant select on ap_categories, ap_crisis_resources to anon, authenticated;
grant select, insert, delete on ap_profiles to authenticated;
grant update (display_name, faith_enabled, timezone, onboarded) on ap_profiles to authenticated;
grant select, insert on ap_commitments to authenticated;
grant update (title, why, status, sensitivity, target_unit, measure) on ap_commitments to authenticated;
grant select on ap_schedules to authenticated;
grant select, insert on ap_check_ins to authenticated;
grant update (status, value, note, client_id) on ap_check_ins to authenticated;
grant select, insert on ap_setbacks to authenticated;
grant update (reasons, before_note, changes) on ap_setbacks to authenticated;
grant select on ap_invites, ap_partnerships, ap_messages, ap_support_requests to authenticated;
grant select on ap_partner_permissions to authenticated;
grant update (show_status, show_progress, show_consistency, show_last_active, show_title, show_category, show_why, show_notes, setbacks) on ap_partner_permissions to authenticated;
grant select, insert on ap_reports to authenticated;
