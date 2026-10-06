
-- ---------------------------------------------------------------- stats (internal; never granted)
create or replace function ap__stats(c uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare tz text; sd date; today date; d date; sched boolean; st text;
  scheduled_n int := 0; checked_n int := 0; ontrack_n int := 0;
  scheduled30 int := 0; checked30 int := 0; ontrack30 int := 0;
  run int := 0; best int := 0; cur int := 0; cur_open boolean := true;
  strip jsonb := '[]'::jsonb; last_at timestamptz; today_status text; rec int; sb int;
begin
  select coalesce(p.timezone,'Africa/Lagos'), cm.start_date into tz, sd
    from ap_commitments cm join ap_profiles p on p.id = cm.user_id where cm.id = c;
  if sd is null then return null; end if;
  today := (now() at time zone tz)::date;
  d := sd;
  while d <= today loop
    select exists (select 1 from ap_schedules s where s.commitment_id = c and s.valid_from <= d
                     and (s.valid_to is null or d < s.valid_to) and extract(dow from d)::smallint = any(s.days)) into sched;
    select status into st from ap_check_ins where commitment_id = c and local_date = d;
    if sched and (d < today or st is not null) then
      scheduled_n := scheduled_n + 1;
      if st is not null then checked_n := checked_n + 1; end if;
      if st in ('done','partial') then ontrack_n := ontrack_n + 1; run := run + 1; if run > best then best := run; end if;
      else run := 0; end if;
      if d > today - 30 then
        scheduled30 := scheduled30 + 1;
        if st is not null then checked30 := checked30 + 1; end if;
        if st in ('done','partial') then ontrack30 := ontrack30 + 1; end if;
      end if;
    elsif st in ('done','partial') then
      run := run + 1; if run > best then best := run; end if;   -- extra day counts toward the run
    end if;
    if d > today - 28 then
      strip := strip || jsonb_build_object('d', d, 's', sched, 'st', st);
    end if;
    d := d + 1;
  end loop;
  select max(updated_at) into last_at from ap_check_ins where commitment_id = c;
  select status into today_status from ap_check_ins where commitment_id = c and local_date = today;
  select count(*) filter (where recovered_at is not null), count(*) into rec, sb from ap_setbacks where commitment_id = c;
  return jsonb_build_object(
    'today', today, 'today_status', today_status, 'last_checkin_at', last_at,
    'scheduled', scheduled_n, 'checked', checked_n, 'on_track', ontrack_n,
    'checkin_rate', case when scheduled_n = 0 then null else round(100.0 * checked_n / scheduled_n) end,
    'scheduled_30', scheduled30, 'checked_30', checked30, 'on_track_30', ontrack30,
    'current_run', run, 'best_run', best,
    'setbacks', sb, 'recovered', rec, 'strip', strip);
end $$;

-- ---------------------------------------------------------------- owner RPCs
create or replace function ap_journey(p_commitment uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from ap_commitments where id = p_commitment and user_id = auth.uid()) then
    raise exception 'not_found';
  end if;
  return ap__stats(p_commitment);
end $$;

create or replace function ap_check_in(p_commitment uuid, p_date date, p_status text, p_value numeric default null,
  p_note text default null, p_client_id text default null) returns ap_check_ins
language plpgsql security definer set search_path = public as $$
declare r ap_check_ins;
begin
  if auth.uid() is null then raise exception 'auth_required'; end if;
  if not exists (select 1 from ap_commitments where id = p_commitment and user_id = auth.uid()) then
    raise exception 'not_your_commitment';
  end if;
  if p_date > ap__local_today(auth.uid()) + 1 or p_date < ap__local_today(auth.uid()) - 3 then raise exception 'date_out_of_range'; end if;
  insert into ap_check_ins as ci (user_id, commitment_id, local_date, status, value, note, client_id)
  values (auth.uid(), p_commitment, p_date, p_status, p_value, nullif(btrim(p_note),''), p_client_id)
  on conflict (commitment_id, local_date) do update
    set status = excluded.status, value = coalesce(excluded.value, ci.value),
        note = coalesce(excluded.note, ci.note), client_id = excluded.client_id, updated_at = now()
  returning * into r;
  return r;
end $$;

-- "Update my plan": closes the current schedule version and opens a new one from today.
create or replace function ap_update_plan(p_commitment uuid, p_days smallint[], p_target numeric, p_time time, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare t date; cm ap_commitments;
begin
  select * into cm from ap_commitments where id = p_commitment and user_id = auth.uid();
  if cm.id is null then raise exception 'not_your_commitment'; end if;
  t := ap__local_today(auth.uid());
  -- a version that started today is replaced in place; older ones are closed
  delete from ap_schedules where commitment_id = p_commitment and valid_from = t and valid_to is null and valid_from > cm.start_date;
  update ap_schedules set valid_to = t where commitment_id = p_commitment and valid_to is null and valid_from < t;
  if exists (select 1 from ap_schedules where commitment_id = p_commitment and valid_to is null) then
    update ap_schedules set days = coalesce(p_days, days), target_value = p_target, checkin_time = coalesce(p_time, checkin_time), reason = left(p_reason, 200)
      where commitment_id = p_commitment and valid_to is null;
  else
    insert into ap_schedules (commitment_id, user_id, days, target_value, checkin_time, valid_from, reason)
    values (p_commitment, auth.uid(), coalesce(p_days, cm.days), p_target, coalesce(p_time, cm.checkin_time), t, left(p_reason, 200));
  end if;
  update ap_commitments set days = coalesce(p_days, days), target_value = p_target, checkin_time = coalesce(p_time, checkin_time)
   where id = p_commitment;
end $$;

create or replace function ap_start_comeback(p_commitment uuid) returns date language plpgsql security definer set search_path = public as $$
declare d date;
begin
  d := ap__local_today(auth.uid()) + 7;
  update ap_commitments set comeback_until = d where id = p_commitment and user_id = auth.uid();
  if not found then raise exception 'not_your_commitment'; end if;
  return d;
end $$;

-- ---------------------------------------------------------------- invites
create or replace function ap_create_invite(p_commitment uuid, p_label text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare tok text; n int;
begin
  if not exists (select 1 from ap_commitments where id = p_commitment and user_id = auth.uid()) then
    raise exception 'not_your_commitment';
  end if;
  select count(*) into n from ap_invites where owner_id = auth.uid() and created_at > now() - interval '1 day';
  if n >= 10 then raise exception 'rate_limited'; end if;
  tok := encode(gen_random_bytes(12), 'hex');
  insert into ap_invites (owner_id, commitment_id, label, token_hash)
  values (auth.uid(), p_commitment, left(nullif(btrim(p_label),''), 40), encode(digest(tok, 'sha256'), 'hex'));
  return tok;
end $$;

create or replace function ap_invite_preview(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare i ap_invites; cm ap_commitments; pr ap_profiles;
begin
  select * into i from ap_invites where token_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex');
  if i.id is null then return jsonb_build_object('valid', false, 'reason', 'not_found'); end if;
  if i.used_at is not null then return jsonb_build_object('valid', false, 'reason', 'used'); end if;
  if i.expires_at < now() then return jsonb_build_object('valid', false, 'reason', 'expired'); end if;
  select * into cm from ap_commitments where id = i.commitment_id;
  select * into pr from ap_profiles where id = i.owner_id;
  return jsonb_build_object('valid', true,
    'owner', coalesce(pr.display_name, 'A friend'),
    'title', case when cm.sensitivity = 'sensitive' then 'A personal commitment' else cm.title end,
    'own', i.owner_id = auth.uid());
end $$;

create or replace function ap_accept_invite(p_token text, p_alias text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare i ap_invites; cm ap_commitments; pr ap_profiles; me ap_profiles; pid uuid;
begin
  if auth.uid() is null then raise exception 'auth_required'; end if;
  select * into me from ap_profiles where id = auth.uid();
  if me.id is null then raise exception 'profile_required'; end if;
  select * into i from ap_invites where token_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex') for update;
  if i.id is null or i.used_at is not null or i.expires_at < now() then raise exception 'invite_invalid'; end if;
  if i.owner_id = auth.uid() then raise exception 'own_invite'; end if;
  select * into cm from ap_commitments where id = i.commitment_id;
  select * into pr from ap_profiles where id = i.owner_id;
  insert into ap_partnerships (owner_id, partner_id, commitment_id, owner_label, owner_alias, partner_alias)
  values (i.owner_id, auth.uid(), i.commitment_id, i.label, coalesce(pr.display_name, 'Your friend'),
          coalesce(nullif(btrim(p_alias),''), me.display_name, i.label, 'Your partner'))
  returning id into pid;
  -- safe defaults: status, progress, consistency, last active; title only if not sensitive; never why, notes or setbacks
  insert into ap_partner_permissions (partnership_id, owner_id, show_title, show_category)
  values (pid, i.owner_id, cm.sensitivity <> 'sensitive', cm.sensitivity = 'standard');
  update ap_invites set used_by = auth.uid(), used_at = now() where id = i.id;
  insert into ap_messages (partnership_id, sender_id, recipient_id, kind, body)
  values (pid, null, i.owner_id, 'system', coalesce(nullif(btrim(p_alias),''), me.display_name, 'Your partner') || ' accepted your invite.');
  return pid;
end $$;

-- ---------------------------------------------------------------- partner projection (the only thing a partner can read)
create or replace function ap_partner_view() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; p record; perm ap_partner_permissions; cm ap_commitments; cat ap_categories; s jsonb; item jsonb;
begin
  for p in select * from ap_partnerships where partner_id = auth.uid() and status <> 'ended' order by created_at loop
    select * into perm from ap_partner_permissions where partnership_id = p.id;
    select * into cm from ap_commitments where id = p.commitment_id;
    select * into cat from ap_categories where slug = cm.category_slug;
    s := ap__stats(cm.id);
    item := jsonb_build_object(
      'partnership_id', p.id, 'alias', p.owner_alias, 'status', p.status, 'since', p.created_at,
      'commitment_status', cm.status,
      'title', case when perm.show_title then cm.title else 'A personal commitment' end,
      'category', case when perm.show_category then cat.label else null end,
      'why', case when perm.show_why then cm.why else null end,
      'today_status', case when perm.show_status then s->'today_status' else null end,
      'last_checkin_at', case when perm.show_last_active then s->'last_checkin_at' else null end,
      'progress', case when perm.show_progress then jsonb_build_object('on_track', s->'on_track_30', 'due', s->'scheduled_30') else null end,
      'current_run', case when perm.show_consistency then s->'current_run' else null end,
      'setbacks', case when perm.setbacks = 'count' then jsonb_build_object('total', s->'setbacks', 'recovered', s->'recovered') else null end,
      'today_note', case when perm.show_notes then (select note from ap_check_ins where commitment_id = cm.id and local_date = (s->>'today')::date) else null end,
      'day7_due', (p.created_at < now() - interval '7 days' and p.keep_partner is null),
      'keep_partner', p.keep_partner,
      'unread', (select count(*) from ap_messages m where m.partnership_id = p.id and m.recipient_id = auth.uid() and m.read_at is null));
    out := out || item;
  end loop;
  return out;
end $$;

-- the owner's list of their partners (labels are theirs)
create or replace function ap_my_partners() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'partnership_id', p.id, 'commitment_id', p.commitment_id, 'alias', coalesce(p.owner_label, p.partner_alias),
    'partner_alias', p.partner_alias, 'status', p.status, 'since', p.created_at,
    'day7_due', (p.created_at < now() - interval '7 days' and p.keep_owner is null), 'keep_owner', p.keep_owner,
    'unread', (select count(*) from ap_messages m where m.partnership_id = p.id and m.recipient_id = auth.uid() and m.read_at is null))
    order by p.created_at), '[]'::jsonb)
  from ap_partnerships p where p.owner_id = auth.uid() and p.status <> 'ended'
$$;

-- ---------------------------------------------------------------- messages, encouragement, SOS
create or replace function ap_send(p_partnership uuid, p_kind text, p_body text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare p ap_partnerships; rcpt uuid; n int; mid uuid; b text;
begin
  select * into p from ap_partnerships where id = p_partnership and auth.uid() in (owner_id, partner_id);
  if p.id is null then raise exception 'not_found'; end if;
  if p.status <> 'active' then raise exception 'partnership_not_active'; end if;
  if p_kind not in ('cheer','message','checkin_request') then raise exception 'bad_kind'; end if;
  b := nullif(btrim(p_body), '');
  if p_kind = 'message' and (b is null or char_length(b) > 280) then raise exception 'bad_body'; end if;
  select count(*) into n from ap_messages where sender_id = auth.uid() and created_at > now() - interval '1 day';
  if n >= 50 then raise exception 'rate_limited'; end if;
  rcpt := case when p.owner_id = auth.uid() then p.partner_id else p.owner_id end;
  insert into ap_messages (partnership_id, sender_id, recipient_id, kind, body)
  values (p.id, auth.uid(), rcpt, p_kind, left(b, 280)) returning id into mid;
  return mid;
end $$;

-- SOS: notify every active partner on this commitment (or all, if none given). Capped at 6 partner notifications an hour.
create or replace function ap_sos(p_commitment uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare n int; sent int := 0; p record;
begin
  if auth.uid() is null then raise exception 'auth_required'; end if;
  select coalesce(sum(partners_notified),0) into n from ap_support_requests where user_id = auth.uid() and created_at > now() - interval '1 hour';
  for p in select * from ap_partnerships where owner_id = auth.uid() and status = 'active'
             and (p_commitment is null or commitment_id = p_commitment) loop
    exit when n + sent >= 6;
    insert into ap_messages (partnership_id, sender_id, recipient_id, kind, body)
    values (p.id, auth.uid(), p.partner_id, 'sos', 'Your accountability partner needs support. They have requested an accountability check-in.');
    sent := sent + 1;
  end loop;
  insert into ap_support_requests (user_id, commitment_id, partners_notified) values (auth.uid(), p_commitment, sent);
  return jsonb_build_object('notified', sent, 'capped', n + sent >= 6);
end $$;

create or replace function ap_mark_read(p_partnership uuid) returns void language sql security definer set search_path = public as $$
  update ap_messages set read_at = now() where partnership_id = p_partnership and recipient_id = auth.uid() and read_at is null
$$;

create or replace function ap_keep_going(p_partnership uuid, p_keep boolean) returns text language plpgsql security definer set search_path = public as $$
declare p ap_partnerships;
begin
  select * into p from ap_partnerships where id = p_partnership and auth.uid() in (owner_id, partner_id) for update;
  if p.id is null then raise exception 'not_found'; end if;
  if p.owner_id = auth.uid() then update ap_partnerships set keep_owner = p_keep where id = p.id;
  else update ap_partnerships set keep_partner = p_keep where id = p.id; end if;
  if not p_keep then
    update ap_partnerships set status = 'ended', ended_at = now() where id = p.id;
    return 'ended';
  end if;
  return 'kept';
end $$;

create or replace function ap_end_partnership(p_partnership uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update ap_partnerships set status = 'ended', ended_at = now()
   where id = p_partnership and auth.uid() in (owner_id, partner_id) and status <> 'ended';
  if not found then raise exception 'not_found'; end if;
end $$;

create or replace function ap_delete_me() returns void language plpgsql security definer set search_path = public as $$
begin
  delete from ap_profiles where id = auth.uid();
end $$;

-- ---------------------------------------------------------------- grants on functions
revoke execute on function ap__stats(uuid), ap__local_today(uuid) from public, anon, authenticated;
revoke execute on function ap_journey(uuid), ap_check_in(uuid,date,text,numeric,text,text), ap_update_plan(uuid,smallint[],numeric,time,text),
  ap_start_comeback(uuid), ap_create_invite(uuid,text), ap_invite_preview(text), ap_accept_invite(text,text), ap_partner_view(),
  ap_my_partners(), ap_send(uuid,text,text), ap_sos(uuid), ap_mark_read(uuid), ap_keep_going(uuid,boolean), ap_end_partnership(uuid),
  ap_delete_me() from public, anon;
grant execute on function ap_journey(uuid), ap_check_in(uuid,date,text,numeric,text,text), ap_update_plan(uuid,smallint[],numeric,time,text),
  ap_start_comeback(uuid), ap_create_invite(uuid,text), ap_invite_preview(text), ap_accept_invite(text,text), ap_partner_view(),
  ap_my_partners(), ap_send(uuid,text,text), ap_sos(uuid), ap_mark_read(uuid), ap_keep_going(uuid,boolean), ap_end_partnership(uuid),
  ap_delete_me() to authenticated;
grant execute on function ap_invite_preview(text) to anon;
revoke execute on function ap__profile_guard(), ap__commitment_guard(), ap__commitment_first_schedule(), ap__checkin_guard(),
  ap__setback_guard(), ap__mark_recovered(), ap__perm_guard(), ap__report_guard(), ap__report_freeze() from public, anon, authenticated;
