/* Accountability Partner V1 (MVP) by Olaoluwa Michael. Plain JS, no build step, made for low-end Android on slow networks. */
(function () {
'use strict';
var SUPABASE_URL = 'https://rlbrhpjljjgpqpqjrpkc.supabase.co';
// Google sign-in: flip to true once the Supabase callback URL is added to the Google OAuth client (see README).
var GOOGLE_READY = false;
var SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJsYnJocGpsampncHFwcWpycGtjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY5MTU1ODMsImV4cCI6MjEwMjQ5MTU4M30.xXD8zgxCQBUlZN4hy7T1lRN1QdiJkSQRGVPEP0yNjas';
var APP = { user: null, profile: null, cats: [], crisis: null, commitments: [], today: {}, partners: [], supporting: [], online: navigator.onLine };
var sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce', storageKey: 'ap-auth' } });
var $app = document.getElementById('app');

/* ---------------------------------------------------------------- helpers */
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
function toast(t) { var el = document.getElementById('toast'); el.textContent = t; el.className = 'on'; clearTimeout(toast._t); toast._t = setTimeout(function () { el.className = ''; }, 2600); }
function tz() { return (APP.profile && APP.profile.timezone) || (Intl.DateTimeFormat().resolvedOptions().timeZone) || 'Africa/Lagos'; }
function localDate(d) { try { return new Intl.DateTimeFormat('en-CA', { timeZone: tz(), year: 'numeric', month: '2-digit', day: '2-digit' }).format(d || new Date()); } catch (e) { return new Date().toISOString().slice(0, 10); } }
function niceDate(iso) { var d = new Date(iso + 'T12:00:00'); return d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' }); }
function ago(ts) { if (!ts) return 'not yet'; var s = (Date.now() - new Date(ts).getTime()) / 1000; if (s < 90) return 'just now'; if (s < 3600) return Math.round(s / 60) + ' min ago'; if (s < 86400) return Math.round(s / 3600) + ' h ago'; var d = Math.round(s / 86400); return d === 1 ? 'yesterday' : d + ' days ago'; }
function param(i) { return location.hash.replace(/^#\/?/, '').split('/')[i] || ''; }
function go(h) { if (location.hash === h) render(); else location.hash = h; }
function friendlyErr(e) {
  var m = (e && (e.message || e.error_description || e.msg)) || String(e || '');
  var map = { adults_only: 'Accountability Partner is for adults (18+) for now.', invite_invalid: 'This invite link has expired or was already used. Ask your friend for a new one.', own_invite: 'This is your own invite link. Send it to a friend instead.', rate_limited: 'That is a lot in a short time. Please try again a bit later.', partnership_not_active: 'Messaging is paused on this partnership.', 'Failed to fetch': 'No connection right now. We will keep trying.' };
  for (var k in map) if (m.indexOf(k) >= 0) return map[k];
  return 'Something did not go through. Please try again.';
}
async function rpc(fn, args) { var r = await sb.rpc(fn, args || {}); if (r.error) throw r.error; return r.data; }
function icon(name) {
  var p = { today: 'M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4M12 8a4 4 0 100 8 4 4 0 000-8z', journey: 'M4 19h16M6 16l4-5 3 3 5-7', partners: 'M9 11a3 3 0 100-6 3 3 0 000 6zM17 11a3 3 0 100-6 3 3 0 000 6zM3 20c0-3 3-5 6-5s6 2 6 5M14 15.2c.9-.1 1.9-.2 3-.2 3 0 6 2 6 5', me: 'M12 12a4 4 0 100-8 4 4 0 000 8zM4 21c0-4 4-6 8-6s8 2 8 6' }[name];
  return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="' + p + '"/></svg>';
}
var CRISIS_WORDS = ['kill myself', 'killing myself', 'suicide', 'suicidal', 'end my life', 'end it all', 'want to die', 'wanna die', 'self harm', 'self-harm', 'hurt myself', 'harm myself', 'cut myself', 'no reason to live', 'better off dead', 'i wan die', 'take my life', 'take my own life'];
function crisisMatch(t) { t = String(t || '').toLowerCase(); return CRISIS_WORDS.some(function (w) { return t.indexOf(w) >= 0; }); }
var CRISIS_FALLBACK = [
  { name: 'Emergency services (Nigeria)', phone: '112', hours: '24 hours, toll-free' },
  { name: 'Lagos State emergency line', phone: '767', hours: '24 hours, toll-free (or 112)' },
  { name: 'Mentally Aware Nigeria Initiative (MANI)', phone: '0809 111 6264', url: 'https://mentallyaware.org', hours: 'Also 0811 168 0686' },
  { name: 'SURPIN suicide prevention helpline', phone: '0800 078 7746', url: 'https://www.surpinng.com', hours: '24 hours, toll-free' },
  { name: 'Find a free helpline in your country', url: 'https://findahelpline.com', hours: '24 hours' }];

var FAMILIES = [
  { k: 'start', t: 'Start', d: 'Build a habit: reading, prayer, study' },
  { k: 'stop', t: 'Stop', d: 'Break a habit that holds you back' },
  { k: 'become', t: 'Become', d: 'Grow into who you want to be' },
  { k: 'achieve', t: 'Achieve', d: 'Reach a goal with a finish line' }];
var LABELS = {
  stop: { done: 'Kept it', partial: 'Partly', missed: 'Slipped', struggling: 'Struggling' },
  other: { done: 'Done', partial: 'Partly', missed: 'Missed', struggling: 'Struggling' } };
function L(c, s) { return (c && c.kind === 'stop' ? LABELS.stop : LABELS.other)[s] || s; }
var DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
var SUGGEST = {
  reading: 'Read 10 pages every day', prayer: 'Pray for 15 minutes every morning', studying: 'Study for 1 hour every day', bible_study: 'Read one Bible chapter a day',
  exercise: 'Walk for 20 minutes', journaling: 'Write 5 lines every night', sleep: 'Sleep by 11pm', social_media: 'No social media after 9pm',
  procrastination: 'Start my hardest task first', finish_book: 'Finish my book in 30 days', exam: 'Study for my exam every day', save_money: 'Save something every week' };

var VERSES = [
  ['And let us not be weary in well doing: for in due season we shall reap, if we faint not.', 'Galatians 6:9'],
  ['It is of the LORD\u2019s mercies that we are not consumed, because his compassions fail not. They are new every morning: great is thy faithfulness.', 'Lamentations 3:22\u201323'],
  ['I can do all things through Christ which strengtheneth me.', 'Philippians 4:13'],
  ['For a just man falleth seven times, and riseth up again.', 'Proverbs 24:16'],
  ['But they that wait upon the LORD shall renew their strength; they shall mount up with wings as eagles; they shall run, and not be weary; and they shall walk, and not faint.', 'Isaiah 40:31']];
var WORDS = ['Small steps still count. Showing up is the habit.', 'A hard day is part of the story, not the end of it.', 'You noticed. That is already the first step back.', 'Progress is not a straight line. Your history is still yours.', 'Be as kind to yourself as you would be to a friend.'];
function encouragement() {
  var i = new Date().getDate();
  if (APP.profile && APP.profile.faith_enabled) { var v = VERSES[i % VERSES.length]; return '<p class="verse">\u201c' + esc(v[0]) + '\u201d <span class="tiny">(' + esc(v[1]) + ', KJV)</span></p>'; }
  return '<p class="verse">' + esc(WORDS[i % WORDS.length]) + '</p>';
}

/* ---------------------------------------------------------------- offline check-in queue (idempotent: one row per commitment per day) */
var QK = 'ap-queue';
function queue() { try { return JSON.parse(localStorage.getItem(QK) || '[]'); } catch (e) { return []; } }
function setQueue(q) { localStorage.setItem(QK, JSON.stringify(q)); }
async function flushQueue() {
  var q = queue(); if (!q.length || !navigator.onLine) return;
  var left = [];
  for (var i = 0; i < q.length; i++) { try { await rpc('ap_check_in', q[i]); } catch (e) { if (/fetch|network/i.test(e.message || '')) left.push(q[i]); } }
  setQueue(left);
  if (q.length && !left.length) toast('Saved check-ins synced.');
}
window.addEventListener('online', function () { APP.online = true; flushQueue().then(render); });
window.addEventListener('offline', function () { APP.online = false; render(); });

/* ---------------------------------------------------------------- data */
async function loadProfile() {
  var r = await sb.from('ap_profiles').select('*').eq('id', APP.user.id).maybeSingle();
  APP.profile = r.data || null;
}
async function loadCats() {
  if (APP.cats.length) return;
  var r = await sb.from('ap_categories').select('*').order('sort');
  APP.cats = r.data || [];
}
function cat(slug) { for (var i = 0; i < APP.cats.length; i++) if (APP.cats[i].slug === slug) return APP.cats[i]; return { label: slug }; }
async function loadCommitments() {
  var r = await sb.from('ap_commitments').select('*').in('status', ['active', 'paused']).order('created_at');
  if (r.error) throw r.error;
  APP.commitments = r.data || [];
  var ids = APP.commitments.map(function (c) { return c.id; });
  APP.today = {};
  if (ids.length) {
    var t = localDate();
    var c = await sb.from('ap_check_ins').select('*').in('commitment_id', ids).eq('local_date', t);
    (c.data || []).forEach(function (x) { APP.today[x.commitment_id] = x; });
  }
  queue().forEach(function (q) { if (q.p_date === localDate()) APP.today[q.p_commitment] = { status: q.p_status, pending: true }; });
}
async function loadPartners() {
  var a = await Promise.all([rpc('ap_my_partners'), rpc('ap_partner_view')]);
  APP.partners = a[0] || []; APP.supporting = a[1] || [];
}
function unreadCount() { var n = 0; APP.partners.concat(APP.supporting).forEach(function (p) { n += p.unread || 0; }); return n; }

/* ---------------------------------------------------------------- shell */
function shell(active, body) {
  var u = unreadCount();
  var tabs = [['today', '#/', 'Today'], ['journey', '#/journey', 'Journey'], ['partners', '#/partners', 'Partners'], ['me', '#/me', 'Me']].map(function (t) {
    return '<a href="' + t[1] + '"' + (active === t[0] ? ' aria-current="page"' : '') + '>' + icon(t[0]) + t[2] + (t[0] === 'partners' && u ? '<span class="badge">' + u + '</span>' : '') + '</a>';
  }).join('');
  return (APP.online ? '' : '<div class="offline">You are offline. Check-ins are saved on this phone and sync later.</div>') +
    '<header class="top"><div class="logo-mark" aria-hidden="true"></div><div class="brand">Accountability Partner<small>Keep the promises you make to yourself</small></div><div class="sp"></div></header>' +
    '<main id="main">' + body + '<footer class="foot">Accountability Partner \u00b7 by Olaoluwa Michael</footer></main>' +
    '<button class="sos" data-go="#/sos">I need support</button>' +
    '<nav class="tabs" aria-label="Main"><div class="in">' + tabs + '</div></nav>';
}
function plain(body) { return '<main id="main" style="padding-bottom:30px">' + body + '<footer class="foot">Accountability Partner \u00b7 by Olaoluwa Michael</footer></main>'; }

/* ---------------------------------------------------------------- welcome and sign-in */
function viewWelcome() {
  var join = sessionStorage.getItem('ap-join');
  return plain('<div class="hero"><div class="logo-mark" aria-hidden="true"></div><h1 style="margin-top:16px">Accountability Partner</h1>' +
    '<p>Keep the promises you make to yourself, with a friend in your corner.</p></div>' +
    (join ? '<div class="card soft"><b>You were invited to be someone\u2019s partner.</b><p class="small" style="margin:4px 0 0">Start below and we will take you straight to the invite.</p></div>' : '') +
    '<ul class="bullets"><li>Pick one thing to start, stop, become or achieve.</li><li>Check in with one tap a day. Hard days lead to a plan, never a red screen.</li><li>Invite a friend. They see only what you choose to share.</li></ul>' +
    '<div class="stack"><button class="btn-block" data-act="anon">Start privately</button>' +
    (GOOGLE_READY ? '<button class="btn-block btn-ghost" data-act="google">I have an account: continue with Google</button>' : '') + '</div>' +
    '<p class="tiny muted" style="margin-top:14px">No email or phone needed to start. For adults 18+. Your notes stay private, and nothing is sent to any AI.</p>');
}
async function startAnon(btn) {
  btn.disabled = true; btn.textContent = 'Starting\u2026';
  var r = await sb.auth.signInAnonymously();
  if (r.error) { btn.disabled = false; btn.textContent = 'Start privately'; toast(friendlyErr(r.error)); return; }
  APP.user = r.data.user; APP.profile = null; route();
}
async function google() {
  var opts = { provider: 'google', options: { redirectTo: location.origin + '/' } };
  var r = (APP.user && APP.user.is_anonymous) ? await sb.auth.linkIdentity(opts) : await sb.auth.signInWithOAuth(opts);
  if (r.error) toast(/already|exists/i.test(r.error.message) ? 'That Google account already has a profile. Sign out, then continue with Google.' : friendlyErr(r.error));
}

/* ---------------------------------------------------------------- onboarding */
var OB = { step: 0 };
function viewUnder18() {
  return plain('<div class="hero"><div class="logo-mark"></div><h1 style="margin-top:16px">We\u2019re building a version for you</h1>' +
    '<p>Accountability Partner is for adults (18+) for now. A version for younger people, with a parent or guardian involved, is on the way.</p>' +
    '<p>If something feels heavy right now, please talk to someone you trust.</p></div>' + crisisList() +
    '<button class="btn-block btn-ghost" data-act="signout">Go back</button>');
}
function obSteps(n, total) { var s = '<div class="steps" aria-label="Step ' + (n + 1) + ' of ' + total + '">'; for (var i = 0; i < total; i++) s += '<i class="' + (i <= n ? 'on' : '') + '"></i>'; return s + '</div>'; }
function viewOnboard() {
  var joining = !!sessionStorage.getItem('ap-join');
  var total = joining ? 2 : 4, s = OB.step, y = new Date().getFullYear(), body = '';
  if (s === 0) {
    var opts = '<option value="">Choose your birth year</option>'; for (var i = y - 18; i >= y - 90; i--) opts += '<option>' + i + '</option>';
    body = '<h1>Welcome</h1><p class="muted">Two quick things about you. Your birth year is only used to keep this space for adults.</p>' +
      '<label for="by">Birth year</label><select id="by">' + opts + '<option value="young">' + (y - 17) + ' or later</option></select>' +
      '<label for="nm">What should your partner call you?</label><input id="nm" maxlength="40" autocomplete="nickname" placeholder="A first name or nickname" value="' + esc(OB.name || '') + '">' +
      '<div class="hint">Optional. You can stay anonymous.</div>' +
      '<div style="margin-top:18px"><button class="btn-block" data-act="ob-age">Continue</button></div>';
  } else if (s === 1) {
    body = '<h1>Include faith-based encouragement?</h1><p class="muted">If you say yes, hard moments come with a short Bible verse. You can change this any time in Me.</p>' +
      '<div class="stack"><button class="btn-block" data-act="ob-faith" data-v="1">Yes, include it</button><button class="btn-block btn-ghost" data-act="ob-faith" data-v="0">Not now</button></div>';
  } else if (s === 2) {
    body = '<h1>What do you want to change?</h1><p class="muted">Pick the closest one.</p><div class="grid2">' +
      FAMILIES.map(function (f) { return '<button class="family" data-act="ob-fam" data-v="' + f.k + '" aria-pressed="' + (OB.family === f.k) + '"><b>' + f.t + '</b><span>' + f.d + '</span></button>'; }).join('') + '</div>';
  } else if (s === 3) {
    var cs = APP.cats.filter(function (c) { return c.family === OB.family || c.family === 'other'; })
    cs.sort(function (a, b) { return (b.featured - a.featured) || (a.sort - b.sort); });
    body = '<h1>Which area?</h1><p class="muted">' + (OB.family === 'start' ? 'Reading, prayer and study are where our first members begin.' : 'Choose one. Sensitive areas stay private by default.') + '</p><div class="chips">' +
      cs.map(function (c) { return '<button class="chip" data-act="ob-cat" data-v="' + c.slug + '" aria-pressed="' + (OB.cat === c.slug) + '">' + esc(c.label) + '</button>'; }).join('') + '</div>';
  }
  return plain('<div style="padding-top:18px">' + obSteps(s, total) + body + (s > 0 ? '<button class="btn-quiet" style="margin-top:12px" data-act="ob-back">Back</button>' : '') + '</div>');
}
async function obAge() {
  var by = document.getElementById('by').value, nm = document.getElementById('nm').value.trim();
  if (!by) { toast('Please choose your birth year.'); return; }
  if (by === 'young') { go('#/under18'); return; }
  OB.name = nm;
  var row = { id: APP.user.id, birth_year: +by, display_name: nm || null, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'Africa/Lagos' };
  var r = await sb.from('ap_profiles').insert(row).select().single();
  if (r.error && r.error.code === '23505') r = await sb.from('ap_profiles').update({ display_name: row.display_name, timezone: row.timezone }).eq('id', APP.user.id).select().single();
  if (r.error) { if (/adults_only/.test(r.error.message)) go('#/under18'); else toast(friendlyErr(r.error)); return; }
  APP.profile = r.data;
  if (sessionStorage.getItem('ap-join')) { await sb.from('ap_profiles').update({ onboarded: true }).eq('id', APP.user.id); APP.profile.onboarded = true; go('#/join/' + sessionStorage.getItem('ap-join')); return; }
  OB.step = 1; render();
}
async function obFaith(v) {
  var r = await sb.from('ap_profiles').update({ faith_enabled: v }).eq('id', APP.user.id).select().single();
  if (!r.error) APP.profile = r.data; OB.step = 2; render();
}

/* ---------------------------------------------------------------- create commitment */
var NEW = {};
function viewNew() {
  var c = cat(NEW.cat || 'custom'), fam = NEW.family || c.family;
  var stop = fam === 'stop';
  if (NEW.title == null) NEW.title = SUGGEST[NEW.cat] || '';
  if (!NEW.days) NEW.days = [0, 1, 2, 3, 4, 5, 6];
  var dayChips = DAYS.map(function (d, i) { return '<button class="chip" data-act="nc-day" data-v="' + i + '" aria-pressed="' + (NEW.days.indexOf(i) >= 0) + '">' + d + '</button>'; }).join('');
  return plain('<div style="padding-top:14px"><button class="btn-quiet" data-act="nc-cancel" style="padding-left:0">\u2190 Back</button>' +
    '<h1>Make your commitment</h1><p class="muted">' + esc(c.label) + (c.sensitivity === 'sensitive' ? ' \u00b7 kept private: partners see \u201cA personal commitment\u201d' : '') + '</p>' +
    '<label for="t">' + (stop ? 'What will you stop?' : 'What will you do?') + '</label><input id="t" maxlength="120" value="' + esc(NEW.title) + '" placeholder="' + (stop ? 'No social media after 9pm' : 'Read 10 pages every day') + '">' +
    '<label for="w">Why does this matter to you?</label><textarea id="w" maxlength="1000" placeholder="We will show you this on hard days.">' + esc(NEW.why || '') + '</textarea>' +
    '<label>How will you measure it?</label><div class="chips">' +
    '<button class="chip" data-act="nc-meas" data-v="binary" aria-pressed="' + (NEW.measure !== 'quantity') + '">' + (stop ? 'Kept it or not' : 'Done or not') + '</button>' +
    '<button class="chip" data-act="nc-meas" data-v="quantity" aria-pressed="' + (NEW.measure === 'quantity') + '">An amount</button></div>' +
    (NEW.measure === 'quantity' ? '<div class="row" style="margin-top:10px"><input id="tv" type="number" inputmode="decimal" min="1" style="max-width:110px" value="' + esc(NEW.tv || 10) + '" aria-label="Target amount"><input id="tu" maxlength="24" value="' + esc(NEW.tu || 'pages') + '" aria-label="Unit"></div>' : '') +
    '<label>Which days?</label><div class="chips">' + dayChips + '</div>' +
    '<label for="ct">Check-in time</label><input id="ct" type="time" value="' + esc(NEW.time || '20:00') + '">' +
    '<div class="hint">Pick a time you are usually free. Reminders never show your goal on the lock screen.</div>' +
    '<div style="margin-top:20px"><button class="btn-block" data-act="nc-save">I commit</button></div></div>');
}
function ncRead() {
  var t = document.getElementById('t'); if (!t) return;
  NEW.title = t.value; NEW.why = document.getElementById('w').value; NEW.time = document.getElementById('ct').value;
  var tv = document.getElementById('tv'); if (tv) { NEW.tv = tv.value; NEW.tu = document.getElementById('tu').value; }
}
async function ncSave(btn) {
  ncRead();
  if (!NEW.title.trim()) { toast('Give your commitment a short title.'); return; }
  if (!NEW.days.length) { toast('Choose at least one day.'); return; }
  var c = cat(NEW.cat);
  var row = { title: NEW.title.trim(), why: NEW.why.trim() || null, category_slug: NEW.cat, kind: c.family === 'other' ? (NEW.family || 'start') : c.family,
    measure: NEW.measure === 'quantity' ? 'quantity' : 'binary', target_value: NEW.measure === 'quantity' ? Math.max(1, +NEW.tv || 1) : null,
    target_unit: NEW.measure === 'quantity' ? (NEW.tu || '').trim().slice(0, 24) || null : null, days: NEW.days.slice().sort(), checkin_time: NEW.time || '20:00',
    start_date: localDate(), user_id: APP.user.id };
  if (row.kind === 'other') row.kind = 'start';
  btn.disabled = true;
  var r = await sb.from('ap_commitments').insert(row).select().single();
  btn.disabled = false;
  if (r.error) { toast(friendlyErr(r.error)); return; }
  if (!APP.profile.onboarded) { await sb.from('ap_profiles').update({ onboarded: true }).eq('id', APP.user.id); APP.profile.onboarded = true; }
  NEW = {}; OB = { step: 0 };
  toast('Committed. Your first check-in is today.');
  await loadCommitments(); go('#/');
}

/* ---------------------------------------------------------------- today */
function statusPill(c, st) { if (!st) return '<span class="pill none">Not checked in yet</span>'; return '<span class="pill ' + st + '">' + esc(L(c, st)) + '</span>'; }
function scheduledToday(c) { var dow = new Date(localDate() + 'T12:00:00').getDay(); return c.days.indexOf(dow) >= 0; }
function viewToday() {
  var name = APP.profile.display_name ? ', ' + esc(APP.profile.display_name) : '';
  var h = '<h1 style="margin-top:4px">Today' + name + '</h1><p class="muted">' + niceDate(localDate()) + '</p>';
  var msgs = APP.partners.concat(APP.supporting).filter(function (p) { return p.unread; });
  if (msgs.length) h += '<div class="card soft"><b>' + (msgs.length === 1 ? 'New from your partner' : 'New from your partners') + '</b><p class="small" style="margin:4px 0 8px">Encouragement and messages are waiting.</p><button class="btn-sm" data-go="#/partners">Open</button></div>';
  var due7 = APP.partners.concat(APP.supporting).filter(function (p) { return p.day7_due; });
  if (due7.length) h += '<div class="card warm"><b>One week together. Keep going?</b><p class="small" style="margin:4px 0 8px">You and ' + esc(due7[0].alias) + ' have been partners for 7 days.</p><div class="row"><button class="btn-sm" data-act="keep" data-id="' + due7[0].partnership_id + '" data-v="1">Keep going</button><button class="btn-sm btn-ghost" data-act="keep" data-id="' + due7[0].partnership_id + '" data-v="0">End kindly</button></div></div>';
  if (!APP.commitments.length) {
    h += '<div class="card"><h2>Nothing yet</h2><p class="muted">Start with one small, honest promise.</p><button class="btn-block" data-go="#/new">Make a commitment</button></div>';
  }
  APP.commitments.forEach(function (c) {
    var ci = APP.today[c.id], st = ci && ci.status, sched = scheduledToday(c);
    h += '<section class="card" aria-label="' + esc(c.title) + '"><div class="row between"><h2 style="margin:0">' + esc(c.title) + '</h2></div>' +
      '<div class="row wrap small muted" style="margin:6px 0 2px">' + statusPill(c, st) + (c.measure === 'quantity' ? '<span>Goal: ' + esc(+c.target_value) + ' ' + esc(c.target_unit || '') + '</span>' : '') +
      (!sched ? '<span>Rest day</span>' : '') + (c.comeback_until && c.comeback_until >= localDate() ? '<span class="pill">Comeback Mission</span>' : '') + (ci && ci.pending ? '<span>Saved offline</span>' : '') + '</div>';
    if (!st) {
      h += '<p class="small muted" style="margin:10px 0 0">' + (c.kind === 'stop' ? 'How did it go today?' : 'Did you do it today?') + '</p><div class="ci">' +
        ['done', 'partial', 'missed', 'struggling'].map(function (s) { return '<button class="' + s + '" data-act="ci" data-id="' + c.id + '" data-v="' + s + '">' + esc(L(c, s)) + '</button>'; }).join('') + '</div>';
    } else {
      h += (st === 'done' || st === 'partial' ? '<p class="small" style="margin:10px 0 0">' + (st === 'done' ? 'Kept. That counts.' : 'Partly still counts. Showing up is the habit.') + '</p>' : '<p class="small" style="margin:10px 0 0">You were honest about today. That is how this works.</p>') +
        '<div class="row wrap" style="margin-top:8px"><button class="btn-sm btn-ghost" data-act="ci-change" data-id="' + c.id + '">Change</button>' +
        (st === 'missed' || st === 'struggling' ? '<button class="btn-sm" data-go="#/recover/' + c.id + '/' + st + '">Make a plan</button>' : '') + '</div>';
    }
    h += '</section>';
  });
  if (APP.commitments.length && APP.commitments.length < 3) h += '<button class="btn-block btn-ghost" data-go="#/new">Add another commitment</button>';
  return shell('today', h);
}
async function checkIn(cid, status, btn) {
  var c = APP.commitments.filter(function (x) { return x.id === cid; })[0];
  if (status === 'partial' && c.measure === 'quantity') {
    var v = prompt('How many ' + (c.target_unit || '') + ' did you do?', ''); var val = v ? +v : null;
  }
  var args = { p_commitment: cid, p_date: localDate(), p_status: status, p_value: status === 'done' && c.measure === 'quantity' ? +c.target_value : (typeof val === 'number' && !isNaN(val) ? val : null), p_note: null, p_client_id: cid + ':' + localDate() };
  if (btn) btn.disabled = true;
  try { await rpc('ap_check_in', args); APP.today[cid] = { status: status }; }
  catch (e) {
    if (!navigator.onLine || /fetch|network/i.test(e.message || '')) { var q = queue().filter(function (x) { return !(x.p_commitment === cid && x.p_date === args.p_date); }); q.push(args); setQueue(q); APP.today[cid] = { status: status, pending: true }; toast('Saved on this phone. It will sync when you are online.'); }
    else { toast(friendlyErr(e)); if (btn) btn.disabled = false; return; }
  }
  if (status === 'struggling') return go('#/struggle/' + cid);
  if (status === 'missed') return go('#/recover/' + cid + '/missed');
  toast(status === 'done' ? (c.kind === 'stop' ? 'Kept. Well done.' : 'Done. Well done.') : 'Partly counts. Well done for showing up.');
  render();
}

/* ---------------------------------------------------------------- struggle and recovery (rule-based, no AI) */
var INTERVENTIONS = {
  step_away: { t: 'Step away for two minutes', s: ['Stand up and leave the room you are in.', 'Drink a glass of water slowly.', 'Breathe in for 4, hold for 4, out for 6. Five times.'] },
  remember_why: { t: 'Read your why', s: ['Read the reason you wrote when you made this commitment.', 'Picture tomorrow morning if you keep it today.', 'Choose the next small step.'] },
  five_minutes: { t: 'Just five minutes', s: ['Set a five-minute timer.', 'Do only the first, smallest part of the task.', 'When it rings, decide if you will do five more.'] } };
function viewStruggle() {
  var c = commitment(param(1)); if (!c) return viewToday();
  return shell('today', '<h1>Let\u2019s take a breath</h1><p class="muted">Struggling is information, not failure. What would help right now?</p>' +
    '<div class="card"><b>' + esc(c.title) + '</b>' + (c.why ? '<p class="small" style="margin:8px 0 0">Your why: <i>' + esc(c.why) + '</i></p>' : '') + '</div>' +
    '<div class="stack">' +
    '<button class="btn-block btn-sand" data-act="iv" data-v="five_minutes" data-id="' + c.id + '">Break it into something smaller</button>' +
    '<button class="btn-block btn-sand" data-act="iv" data-v="step_away" data-id="' + c.id + '">Take a 2-minute reset</button>' +
    (APP.partners.some(function (p) { return p.commitment_id === c.id && p.status === 'active'; }) ? '<button class="btn-block btn-sand" data-act="ask-partner" data-id="' + c.id + '">Ask my partner to check on me</button>' : '<button class="btn-block btn-sand" data-go="#/invite/' + c.id + '">Invite a friend to support me</button>') +
    '<button class="btn-block" data-go="#/recover/' + c.id + '/struggling">Change my plan</button></div>' + encouragement());
}
function viewIntervention() {
  var c = commitment(param(1)), iv = INTERVENTIONS[param(2)] || INTERVENTIONS.step_away;
  var steps = iv.s.slice(); if (param(2) === 'remember_why' && c && c.why) steps[0] = 'Your why: \u201c' + c.why + '\u201d';
  return '<div class="full"><div class="in"><h1>' + esc(iv.t) + '</h1>' + (param(2) === 'step_away' ? '<div class="breathe">Breathe</div>' : '') +
    '<ol class="stack" style="padding-left:20px">' + steps.map(function (s) { return '<li>' + esc(s) + '</li>'; }).join('') + '</ol>' + encouragement() +
    '<div class="stack" style="margin-top:20px"><button class="btn-block" data-act="iv-done" data-id="' + (c ? c.id : '') + '" data-v="1">That helped</button>' +
    '<button class="btn-block btn-ghost" data-act="iv-done" data-id="' + (c ? c.id : '') + '" data-v="0">Not really, let\u2019s change the plan</button></div></div></div>';
}
var REASONS = [['stress', 'Stress'], ['fatigue', 'Tired'], ['distraction', 'Distracted'], ['forgot', 'Forgot'], ['planning', 'No plan for it'], ['temptation', 'Temptation'], ['environment', 'My surroundings'], ['unexpected', 'Something unexpected'], ['motivation', 'Lost motivation'], ['other', 'Something else']];
var CHANGES = {
  smaller_target: { t: 'Make it smaller for now', d: function (c) { return c.measure === 'quantity' ? 'From ' + (+c.target_value) + ' to ' + Math.max(1, Math.ceil(c.target_value / 2)) + ' ' + (c.target_unit || '') + ' a day.' : 'Do the 2-minute version on hard days. It still counts.'; } },
  earlier_time: { t: 'Check in earlier', d: function (c) { return 'Move your check-in from ' + c.checkin_time.slice(0, 5) + ' to ' + earlier(c.checkin_time) + '.'; } },
  rest_day: { t: 'Plan a rest day', d: function (c) { return c.days.length > 1 ? 'One planned day off a week, so a busy day is not a setback.' : 'Keep your one day; add a backup day instead.'; } },
  environment: { t: 'Change your surroundings', d: function (c) { return c.kind === 'stop' ? 'Make the trigger harder to reach (phone in another room, a different route).' : 'Put a visible cue where you will see it (book on your pillow, notes on the table).'; } },
  reset: { t: 'Use a 2-minute reset', d: function () { return 'When it gets hard, open \u201cI need support\u201d and do the reset first.'; } },
  partner: { t: 'Ask your partner to check on you', d: function (c) { return hasPartner(c.id) ? 'We will send them a gentle check-in request.' : 'Invite a friend to keep you company on this.'; } },
  why: { t: 'Read your why each morning', d: function (c) { return c.why ? '\u201c' + c.why.slice(0, 80) + (c.why.length > 80 ? '\u2026' : '') + '\u201d' : 'Write down why this matters, so hard days have an answer.'; } } };
var RULES = { fatigue: ['smaller_target', 'earlier_time', 'rest_day'], stress: ['smaller_target', 'reset', 'partner'], forgot: ['earlier_time', 'environment', 'partner'],
  planning: ['earlier_time', 'rest_day', 'smaller_target'], distraction: ['environment', 'reset', 'earlier_time'], temptation: ['environment', 'reset', 'partner'],
  environment: ['environment', 'partner', 'reset'], unexpected: ['rest_day', 'smaller_target', 'partner'], motivation: ['why', 'partner', 'smaller_target'], other: ['smaller_target', 'partner', 'why'] };
function earlier(t) { var h = +t.slice(0, 2), m = t.slice(3, 5); h = Math.max(6, h - 1); return (h < 10 ? '0' : '') + h + ':' + m; }
function hasPartner(cid) { return APP.partners.some(function (p) { return p.commitment_id === cid && p.status === 'active'; }); }
function commitment(id) { return APP.commitments.filter(function (c) { return c.id === id; })[0]; }
function suggest(c, reasons, history) {
  var score = {};
  reasons.forEach(function (r) { (RULES[r] || RULES.other).forEach(function (k, i) { score[k] = (score[k] || 0) + (3 - i); }); });
  (history || []).forEach(function (h) { if (h.recovered_at) (h.changes || []).forEach(function (k) { if (score[k] != null) score[k] += 1; }); });
  if (c.measure !== 'quantity' && c.kind === 'stop') delete score.smaller_target;
  if (c.days.length === 1) delete score.rest_day;
  return Object.keys(score).sort(function (a, b) { return score[b] - score[a]; }).slice(0, 3);
}
var REC = {};
function viewRecover() {
  var c = commitment(param(1)); if (!c) return viewToday();
  if (REC.cid !== c.id) REC = { cid: c.id, source: param(2) || 'missed', step: 0, reasons: [], note: '', picked: null };
  var h = '<div class="steps"><i class="on"></i><i class="' + (REC.step >= 1 ? 'on' : '') + '"></i><i class="' + (REC.step >= 2 ? 'on' : '') + '"></i></div>';
  if (REC.step === 0) {
    h += '<h1>Let\u2019s understand what happened</h1><p class="muted">No judgement. What got in the way? Choose up to three.</p><div class="chips">' +
      REASONS.map(function (r) { return '<button class="chip" data-act="rc-r" data-v="' + r[0] + '" aria-pressed="' + (REC.reasons.indexOf(r[0]) >= 0) + '">' + r[1] + '</button>'; }).join('') +
      '</div><div style="margin-top:18px"><button class="btn-block" data-act="rc-next">Next</button></div>';
  } else if (REC.step === 1) {
    h += '<h1>What happened just before?</h1><p class="muted">Optional. A few words help you spot the pattern.</p>' +
      '<textarea id="rn" maxlength="500" placeholder="I got home late and went straight to my phone\u2026">' + esc(REC.note) + '</textarea>' +
      '<div class="hint">\ud83d\udd12 Only you can see this. It is never shared with a partner or sent to any AI.</div>' +
      '<div style="margin-top:18px"><button class="btn-block" data-act="rc-next">Next</button></div>';
  } else {
    if (!REC.picked) REC.picked = suggest(c, REC.reasons, REC.history);
    var all = suggest(c, REC.reasons.length ? REC.reasons : ['other'], REC.history);
    h += '<h1>What should we change?</h1><p class="muted">Based on what you told us' + (REC.history && REC.history.some(function (x) { return x.recovered_at; }) ? ' and what helped you before' : '') + '. Untick anything that does not fit.</p>' +
      all.map(function (k) { var on = REC.picked.indexOf(k) >= 0; return '<div class="toggle"><span><b>' + CHANGES[k].t + '</b><span class="small muted">' + esc(CHANGES[k].d(c)) + '</span></span><input type="checkbox" class="switch" data-act="rc-pick" data-v="' + k + '"' + (on ? ' checked' : '') + ' aria-label="' + CHANGES[k].t + '"></div>'; }).join('') +
      '<div style="margin-top:18px" class="stack"><button class="btn-block" data-act="rc-apply">Update my plan</button><button class="btn-block btn-ghost" data-act="rc-apply" data-v="none">Keep my plan as it is</button></div>';
  }
  return shell('today', '<button class="btn-quiet" data-go="#/" style="padding-left:0">\u2190 Today</button>' + h);
}
async function recApply(keep) {
  var c = commitment(REC.cid), picks = keep ? [] : (REC.picked || []);
  if (crisisMatch(REC.note)) { sessionStorage.setItem('ap-crisis', '1'); }
  var r = await sb.from('ap_setbacks').insert({ commitment_id: c.id, local_date: localDate(), source: REC.source, reasons: REC.reasons, before_note: REC.note || null, changes: picks, user_id: APP.user.id });
  if (r.error) { toast(friendlyErr(r.error)); return; }
  var days = c.days.slice(), target = c.target_value, time = c.checkin_time.slice(0, 5), planChanged = false;
  if (picks.indexOf('smaller_target') >= 0 && c.measure === 'quantity') { target = Math.max(1, Math.ceil(c.target_value / 2)); planChanged = true; }
  if (picks.indexOf('earlier_time') >= 0) { time = earlier(c.checkin_time); planChanged = true; }
  if (picks.indexOf('rest_day') >= 0 && days.length > 1) { var drop = days.indexOf(0) >= 0 ? 0 : days[days.length - 1]; days = days.filter(function (d) { return d !== drop; }); planChanged = true; }
  try {
    if (planChanged) await rpc('ap_update_plan', { p_commitment: c.id, p_days: days, p_target: target, p_time: time, p_reason: 'recovery: ' + picks.join(', ') });
    if (picks.indexOf('partner') >= 0) { var p = APP.partners.filter(function (x) { return x.commitment_id === c.id && x.status === 'active'; }); for (var i = 0; i < p.length; i++) await rpc('ap_send', { p_partnership: p[i].partnership_id, p_kind: 'checkin_request', p_body: null }); }
  } catch (e) { toast(friendlyErr(e)); }
  REC.done = { picks: picks, planChanged: planChanged, partnerMissing: picks.indexOf('partner') >= 0 && !hasPartner(c.id) };
  await loadCommitments(); go('#/recovered/' + c.id);
}
function viewRecovered() {
  var c = commitment(param(1)); if (!c) return viewToday();
  var d = REC.done || { picks: [] }, crisis = sessionStorage.getItem('ap-crisis');
  sessionStorage.removeItem('ap-crisis');
  return shell('today', (crisis ? '<div class="card warm"><b>You don\u2019t have to carry this alone.</b><p class="small">If you are thinking about hurting yourself, please reach out now. These lines are free.</p>' + crisisList(true) + '</div>' : '') +
    '<h1>' + (d.planChanged ? 'Plan updated' : 'Noted, and you\u2019re still here') + '</h1>' +
    '<p class="muted">This setback is saved as part of your story. When you next check in on track, it becomes a recovered setback on your Journey. Your history is never erased.</p>' +
    (d.picks.length ? '<div class="card"><b>What changes now</b><ul class="small" style="padding-left:18px;margin:8px 0 0">' + d.picks.map(function (k) { return '<li>' + CHANGES[k].t + '</li>'; }).join('') + '</ul></div>' : '') +
    encouragement() +
    '<div class="card soft"><b>Start a Comeback Mission?</b><p class="small" style="margin:4px 0 10px">Seven gentle days to rebuild the rhythm. Same commitment, fresh start.</p><button class="btn-sm" data-act="comeback" data-id="' + c.id + '">Start my 7 days</button></div>' +
    (d.partnerMissing ? '<button class="btn-block btn-ghost" data-go="#/invite/' + c.id + '">Invite a friend to support me</button>' : '') +
    '<button class="btn-block" style="margin-top:10px" data-go="#/">Back to today</button>');
}

/* ---------------------------------------------------------------- journey */
var JOURNEY = {};
function viewJourney() {
  if (!APP.commitments.length) return shell('journey', '<h1>Journey</h1><div class="card"><p class="muted">Your journey starts with your first commitment.</p><button class="btn-block" data-go="#/new">Make a commitment</button></div>');
  var h = '<h1>Journey</h1><p class="muted">Every check-in counts. Setbacks never erase your history.</p>';
  APP.commitments.forEach(function (c) {
    var s = JOURNEY[c.id];
    h += '<section class="card"><h2>' + esc(c.title) + '</h2>';
    if (!s) { h += '<p class="muted small">Loading\u2026</p></section>'; return; }
    h += '<div class="stats"><div class="stat"><b>' + (s.checkin_rate == null ? '\u2013' : s.checkin_rate + '%') + '</b><span>Check-in rate</span></div>' +
      '<div class="stat"><b>' + s.current_run + '</b><span>Current run (days on track)</span></div>' +
      '<div class="stat"><b>' + s.best_run + '</b><span>Best run</span></div>' +
      '<div class="stat"><b>' + s.recovered + '</b><span>Recovered setbacks' + (s.setbacks > s.recovered ? ' \u00b7 ' + (s.setbacks - s.recovered) + ' in progress' : '') + '</span></div></div>' +
      '<p class="small muted" style="margin:0">' + s.on_track + (s.on_track === 1 ? ' day' : ' days') + ' on track out of ' + s.scheduled + ' planned since ' + niceDate(c.start_date) + '.</p>' +
      '<div class="strip" aria-label="Last 4 weeks">' + s.strip.map(function (x) { var cls = !x.s && !x.st ? 'off' : (x.st || ''); if (x.d === s.today) cls += ' today'; return '<div class="dot ' + cls + '" title="' + esc(x.d + (x.st ? ': ' + L(c, x.st) : '')) + '">' + (+x.d.slice(8)) + '</div>'; }).join('') + '</div>' +
      '<div class="legend"><span><i style="background:#0f4c4a"></i>' + L(c, 'done') + '</span><span><i style="background:#7fb3ad"></i>Partly</span><span><i style="background:#dfcfb4"></i>' + L(c, 'missed') + '</span><span><i style="background:#efc98e"></i>Struggling</span><span><i style="border:1px dashed #cdbfa9"></i>Rest day</span></div>' +
      '</section>';
  });
  return shell('journey', h);
}
async function loadJourney() {
  var res = await Promise.all(APP.commitments.map(function (c) { return rpc('ap_journey', { p_commitment: c.id }).catch(function () { return null; }); }));
  APP.commitments.forEach(function (c, i) { if (res[i]) JOURNEY[c.id] = res[i]; });
}

/* ---------------------------------------------------------------- partners */
function viewPartners() {
  var h = '<h1>Partners</h1><p class="muted">Support is chosen, never imposed. A partner sees your status, not your private details.</p>';
  h += '<h2 style="margin-top:18px">In your corner</h2>';
  if (!APP.partners.length) h += '<div class="card"><p class="muted small" style="margin-top:0">No partner yet. Invite one friend you trust. They will only see what you allow.</p>' + (APP.commitments.length ? '<button class="btn-block" data-go="#/invite/' + APP.commitments[0].id + '">Invite a friend</button>' : '<button class="btn-block btn-ghost" data-go="#/new">Start your own commitment</button>') + '</div>';
  APP.partners.forEach(function (p) {
    var c = commitment(p.commitment_id);
    h += '<div class="card"><div class="row between"><div><b>' + esc(p.alias) + '</b><div class="small muted">' + (c ? esc(c.title) : '') + ' \u00b7 since ' + niceDate(p.since.slice(0, 10)) + (p.status === 'frozen' ? ' \u00b7 paused for review' : '') + '</div></div>' + (p.unread ? '<span class="pill">' + p.unread + ' new</span>' : '') + '</div>' +
      (p.day7_due ? '<div class="card warm" style="margin:12px 0 0"><b>One week together. Keep going?</b><div class="row" style="margin-top:8px"><button class="btn-sm" data-act="keep" data-id="' + p.partnership_id + '" data-v="1">Keep going</button><button class="btn-sm btn-ghost" data-act="keep" data-id="' + p.partnership_id + '" data-v="0">End kindly</button></div></div>' : '') +
      '<div class="row wrap" style="margin-top:12px"><button class="btn-sm" data-go="#/thread/' + p.partnership_id + '">Messages</button><button class="btn-sm btn-ghost" data-go="#/share/' + p.partnership_id + '">What they see</button></div></div>';
  });
  if (APP.partners.length && APP.commitments.length) h += '<button class="btn-block btn-ghost" data-go="#/invite/' + APP.commitments[0].id + '">Invite another friend</button>';
  h += '<h2 style="margin-top:22px">You\u2019re supporting</h2>';
  if (!APP.supporting.length) h += '<p class="muted small">When a friend invites you, their check-ins appear here.</p>';
  APP.supporting.forEach(function (s) {
    var st = s.today_status;
    h += '<div class="card"><div class="row between"><div><b>' + esc(s.alias) + '</b><div class="small muted">' + esc(s.title) + (s.category ? ' \u00b7 ' + esc(s.category) : '') + '</div></div>' + (s.unread ? '<span class="pill">' + s.unread + ' new</span>' : '') + '</div>' +
      '<div class="row wrap small" style="margin-top:10px">' + (s.today_status !== undefined && s.today_status !== null ? '<span class="pill ' + st + '">Today: ' + esc(LABELS.other[st] || st) + '</span>' : (s.last_checkin_at !== undefined ? '<span class="pill none">Today: not yet</span>' : '')) +
      (s.last_checkin_at ? '<span class="muted">Last check-in ' + ago(s.last_checkin_at) + '</span>' : '') + '</div>' +
      '<div class="stats">' + (s.progress ? '<div class="stat"><b>' + s.progress.on_track + '/' + s.progress.due + '</b><span>On track, last 30 days</span></div>' : '') + (s.current_run != null ? '<div class="stat"><b>' + s.current_run + '</b><span>Current run</span></div>' : '') + (s.setbacks ? '<div class="stat"><b>' + s.setbacks.recovered + '/' + s.setbacks.total + '</b><span>Setbacks recovered</span></div>' : '') + '</div>' +
      (s.why ? '<p class="small">Their why: <i>' + esc(s.why) + '</i></p>' : '') + (s.today_note ? '<p class="small">Today\u2019s note: <i>' + esc(s.today_note) + '</i></p>' : '') +
      (s.day7_due ? '<div class="card warm" style="margin:6px 0 10px"><b>One week together. Keep going?</b><div class="row" style="margin-top:8px"><button class="btn-sm" data-act="keep" data-id="' + s.partnership_id + '" data-v="1">Keep going</button><button class="btn-sm btn-ghost" data-act="keep" data-id="' + s.partnership_id + '" data-v="0">End kindly</button></div></div>' : '') +
      (s.status === 'active' ? '<div class="row wrap"><button class="btn-sm" data-act="cheer" data-id="' + s.partnership_id + '">\ud83d\udc4f Encourage</button><button class="btn-sm btn-ghost" data-go="#/thread/' + s.partnership_id + '">Message</button></div>' : '<p class="small muted">Messaging is paused while a report is reviewed.</p>') + '</div>';
  });
  return shell('partners', h);
}
var INV = {};
function viewInvite() {
  var c = commitment(param(1)); if (!c) return viewPartners();
  var h = '<button class="btn-quiet" data-go="#/partners" style="padding-left:0">\u2190 Partners</button><h1>Invite a friend</h1><p class="muted">For \u201c' + esc(c.title) + '\u201d. The link works once and expires in 7 days.</p>';
  if (APP.commitments.length > 1) h += '<label for="ic">Commitment</label><select id="ic" data-act="inv-c">' + APP.commitments.map(function (x) { return '<option value="' + x.id + '"' + (x.id === c.id ? ' selected' : '') + '>' + esc(x.title) + '</option>'; }).join('') + '</select>';
  if (!INV.link || INV.cid !== c.id) {
    h += '<label for="il">Who is it? (only you see this)</label><input id="il" maxlength="40" placeholder="Tolu">' +
      '<div class="card soft" style="margin-top:14px"><b>What they will see</b><p class="small" style="margin:6px 0 0">Whether you checked in, your progress and your current run' + (c.sensitivity === 'sensitive' ? ', under \u201cA personal commitment\u201d' : ', and the title') + '. Never your notes, reasons or why, unless you switch them on.</p></div>' +
      '<button class="btn-block" data-act="inv-make" data-id="' + c.id + '">Create invite link</button>';
  } else {
    var text = 'I\u2019m working on something and I\u2019d like you to be my accountability partner. You will only see whether I checked in, nothing private. Accept here: ' + INV.link;
    h += '<div class="card"><b>Your link is ready</b><p class="small muted" style="word-break:break-all">' + esc(INV.link) + '</p>' +
      '<div class="stack"><a class="btn btn-block" href="https://wa.me/?text=' + encodeURIComponent(text) + '" target="_blank" rel="noopener">Send on WhatsApp</a>' +
      '<button class="btn-block btn-ghost" data-act="inv-share" data-v="' + esc(text) + '">Share another way</button>' +
      '<button class="btn-block btn-ghost" data-act="copy" data-v="' + esc(INV.link) + '">Copy link</button></div></div>';
  }
  return shell('partners', h);
}
async function viewJoinAsync() {
  var tok = param(1);
  sessionStorage.setItem('ap-join', tok);
  if (!APP.user) return viewWelcome();
  if (!APP.profile) { OB.step = 0; return viewOnboard(); }
  var pv; try { pv = await rpc('ap_invite_preview', { p_token: tok }); } catch (e) { pv = { valid: false }; }
  if (!pv.valid || pv.own) {
    sessionStorage.removeItem('ap-join');
    return shell('partners', '<h1>' + (pv.own ? 'This is your own invite' : 'This invite can\u2019t be used') + '</h1><p class="muted">' + (pv.own ? 'Send the link to the friend you want as your partner.' : (pv.reason === 'used' ? 'It was already accepted.' : 'It may have expired. Ask your friend to send a new link.')) + '</p><button class="btn-block" data-go="#/">Go to Today</button>');
  }
  return shell('partners', '<h1>' + esc(pv.owner) + ' invited you</h1><p class="muted">to be their accountability partner for:</p><div class="card"><b>' + esc(pv.title) + '</b></div>' +
    '<div class="card soft"><b>What you will see</b><p class="small" style="margin:6px 0 0">Whether they checked in, their progress and their current run. Never their private notes or reasons unless they choose to share.</p>' +
    '<b style="display:block;margin-top:10px">What you can do</b><p class="small" style="margin:6px 0 0">Send one-tap encouragement or a short message. You can end the partnership at any time.</p></div>' +
    '<label for="ja">Your name for them</label><input id="ja" maxlength="40" value="' + esc(APP.profile.display_name || '') + '" placeholder="Your first name">' +
    '<div class="stack" style="margin-top:16px"><button class="btn-block" data-act="join" data-v="' + esc(tok) + '">Accept and support ' + esc(pv.owner) + '</button><button class="btn-block btn-ghost" data-act="join-no">Not now</button></div>');
}
var FIELDS = [['show_status', 'Check-in status', 'Done, partly, missed or struggling, each day'], ['show_progress', 'Progress', 'Days on track out of days planned, last 30 days'], ['show_consistency', 'Current run', 'How many days on track in a row'], ['show_last_active', 'Last check-in time', 'When you last checked in'], ['show_title', 'Commitment title', 'Otherwise shown as \u201cA personal commitment\u201d'], ['show_category', 'Category', 'For example Reading or Prayer'], ['show_why', 'Your why', 'The reason you wrote down'], ['show_notes', 'Check-in notes', 'Any note you add to a check-in']];
function viewShare(perm, p) {
  var h = '<button class="btn-quiet" data-go="#/partners" style="padding-left:0">\u2190 Partners</button><h1>What ' + esc(p.alias) + ' sees</h1><p class="muted">Changes apply right away. Private notes from hard days are never shared.</p><div class="card">' +
    FIELDS.map(function (f) { return '<div class="toggle"><span><b>' + f[1] + '</b><span class="small muted">' + f[2] + '</span></span><input type="checkbox" class="switch" data-act="perm" data-v="' + f[0] + '" data-id="' + p.partnership_id + '"' + (perm[f[0]] ? ' checked' : '') + ' aria-label="' + f[1] + '"></div>'; }).join('') +
    '<div class="toggle"><span><b>Setbacks</b><span class="small muted">Only a count (for example \u201c2 of 3 recovered\u201d), never the reasons</span></span><input type="checkbox" class="switch" data-act="perm" data-v="setbacks" data-id="' + p.partnership_id + '"' + (perm.setbacks === 'count' ? ' checked' : '') + ' aria-label="Setbacks"></div></div>' +
    '<div class="card soft small"><b>Never shared:</b> reflections, the private notes from hard days, your email, phone or location, and your other commitments.</div>' +
    '<button class="btn-block btn-ghost" data-act="end" data-id="' + p.partnership_id + '">End this partnership</button>';
  return shell('partners', h);
}
function viewThread(p, msgs, isOwner) {
  var cheers = isOwner ? ['Thank you!', 'Checked in \ud83d\udc4d', 'Rough day, but I\u2019m on it'] : ['You\u2019ve got this!', 'Proud of you', 'One step at a time', 'Thinking of you'];
  var lab = { cheer: '\ud83d\udc4f sent you encouragement', checkin_request: 'asked you to check in on them', sos: '' };
  var h = '<button class="btn-quiet" data-go="#/partners" style="padding-left:0">\u2190 Partners</button><h1>' + esc(p.alias) + '</h1>' +
    '<div>' + (msgs.length ? msgs.map(function (m) {
      var me = m.sender_id === APP.user.id, cls = m.kind === 'system' ? 'system' : (m.kind === 'sos' ? 'help' : (me ? 'me' : ''));
      var body = m.kind === 'message' || m.kind === 'system' || m.kind === 'sos' ? esc(m.body) : (me ? 'You ' : esc(p.alias) + ' ') + (m.kind === 'cheer' ? (me ? 'sent encouragement \ud83d\udc4f' : 'sent you encouragement \ud83d\udc4f') : (me ? 'asked for a check-in' : 'asked you to check in on them'));
      if (m.kind === 'sos' && !me) body = '<b>Support request.</b> ' + body + '<div class="tiny muted" style="margin-top:4px">A short message or a call from you could help.</div>';
      return '<div class="msg ' + cls + '">' + body + '<div class="tiny muted" style="margin-top:3px">' + ago(m.created_at) + '</div></div>';
    }).join('') : '<p class="muted small">No messages yet. Start with a small encouragement.</p>') + '</div>' +
    (p.status === 'active' ? '<div class="chips" style="margin:14px 0 8px">' + cheers.map(function (t) { return '<button class="chip" data-act="quick" data-id="' + p.partnership_id + '" data-v="' + esc(t) + '">' + esc(t) + '</button>'; }).join('') + '</div>' +
      '<div class="row"><input id="mt" maxlength="280" placeholder="A short message" aria-label="Message"><button data-act="send" data-id="' + p.partnership_id + '" style="min-width:76px">Send</button></div><div class="hint">Short and kind. Up to 280 characters.</div>' : '<div class="card soft small">Messaging is paused on this partnership while a report is reviewed.</div>') +
    '<div class="row wrap" style="margin-top:22px"><button class="btn-quiet" data-act="report" data-id="' + p.partnership_id + '">Report a problem</button><button class="btn-quiet" data-act="end" data-id="' + p.partnership_id + '">End partnership</button></div>';
  return shell('partners', h);
}

/* ---------------------------------------------------------------- SOS (deterministic, works offline) */
function crisisList(compact) {
  var list = APP.crisis || CRISIS_FALLBACK;
  return '<div class="' + (compact ? '' : 'card') + '">' + (compact ? '' : '<b>Free help, any time</b>') + list.map(function (r) {
    return '<div class="line-item"><span class="small"><b>' + esc(r.name) + '</b><br><span class="muted">' + esc(r.hours || '') + (r.region ? ' \u00b7 ' + esc(r.region) : '') + '</span></span>' +
      (r.phone ? '<a class="tel" href="tel:' + esc(r.phone.replace(/\s/g, '')) + '">' + esc(r.phone) + '</a>' : '<a class="small" href="' + esc(r.url) + '" target="_blank" rel="noopener">Open</a>') + '</div>';
  }).join('') + '</div>';
}
var SOS = { step: 0 };
function viewSOS() {
  var c = APP.commitments[0], partnered = APP.partners.some(function (p) { return p.status === 'active'; });
  var trusted = 'https://wa.me/?text=' + encodeURIComponent('I\u2019m having a hard moment with something I\u2019m working on. Could you check in with me?');
  var h = '<div class="full"><div class="in"><button class="btn-quiet" data-act="sos-close" style="padding-left:0">\u2190 Close</button>';
  if (SOS.step === 0) {
    h += '<h1>You reached out. That was the right move.</h1><p class="muted">Let\u2019s slow down together for one minute.</p><div class="breathe">Breathe</div>' +
      '<ol class="small" style="padding-left:20px"><li>Breathe in for 4, hold for 4, out for 6.</li><li>If you can, step into another room or outside.</li><li>Drink some water.</li></ol>' +
      (c && c.why ? '<div class="card soft"><b>Your why</b><p class="small" style="margin:6px 0 0">' + esc(c.why) + '</p></div>' : '') + encouragement() +
      '<button class="btn-block" data-act="sos-next">I\u2019m a little calmer. What next?</button>';
  } else {
    h += '<h1>More support</h1>' +
      '<div class="stack">' + (partnered ? '<button class="btn-block" data-act="sos-notify">Let my partner know</button>' : '') +
      '<a class="btn btn-block btn-ghost" href="' + trusted + '" target="_blank" rel="noopener">Message someone I trust (WhatsApp)</a>' +
      '<button class="btn-block btn-ghost" data-act="sos-iv">Do another 2-minute reset</button></div>' +
      '<p class="small muted" style="margin-top:16px">If you might hurt yourself or you are in danger, please call now. Accountability Partner is not an emergency service.</p>' + crisisList() +
      '<button class="btn-block btn-sand" data-act="sos-close">I\u2019m okay for now</button>';
  }
  return h + '<footer class="foot">Accountability Partner \u00b7 by Olaoluwa Michael</footer></div></div>';
}

/* ---------------------------------------------------------------- me */
function viewMe() {
  var anon = APP.user.is_anonymous;
  return shell('me', '<h1>Me</h1><div class="card"><label for="mn" style="margin-top:0">Name your partners see</label><input id="mn" maxlength="40" value="' + esc(APP.profile.display_name || '') + '" placeholder="Anonymous">' +
    '<div class="toggle" style="margin-top:8px"><span><b>Faith-based encouragement</b><span class="small muted">A short Bible verse on hard days</span></span><input type="checkbox" class="switch" id="mf"' + (APP.profile.faith_enabled ? ' checked' : '') + ' aria-label="Faith-based encouragement"></div>' +
    '<label for="mz">Time zone</label><input id="mz" value="' + esc(APP.profile.timezone) + '"><button class="btn-block" style="margin-top:14px" data-act="me-save">Save</button></div>' +
    '<div class="card"><b>Your account</b>' + (anon ? (GOOGLE_READY ? '<p class="small muted">You started privately on this phone. Save your account with Google so you can sign in on another phone and never lose your history.</p><button class="btn-block btn-ghost" data-act="google">Save with Google</button>' : '<p class="small muted">You started privately on this phone. Keep using this phone (and this browser) to keep your history. Saving your account with Google is coming soon.</p>') : '<p class="small muted">Signed in' + (APP.user.email ? ' as ' + esc(APP.user.email) : '') + '.</p>') +
    '<div class="sep"></div><button class="btn-block btn-ghost" data-act="signout">Sign out</button>' + (anon ? '<div class="hint">Signing out of a private account on this phone removes access to it.</div>' : '') + '</div>' +
    '<div class="card"><b>Commitments</b>' + APP.commitments.map(function (c) { return '<div class="line-item"><span class="small">' + esc(c.title) + '<br><span class="muted">' + c.days.map(function (d) { return DAYS[d]; }).join(' ') + ' \u00b7 ' + c.checkin_time.slice(0, 5) + '</span></span><button class="btn-sm btn-ghost" data-act="pause" data-id="' + c.id + '" data-v="' + (c.status === 'active' ? 'paused' : 'active') + '">' + (c.status === 'active' ? 'Pause' : 'Resume') + '</button></div>'; }).join('') + '<button class="btn-block btn-ghost" style="margin-top:10px" data-go="#/new">New commitment</button></div>' +
    '<div class="card"><b>Privacy</b><p class="small muted">Your rows are readable only by you, enforced by the database. Partners see a summary you control. Nothing you write is sent to any AI.</p><button class="btn-quiet" data-act="report" data-id="">Report a problem</button><button class="btn-quiet" data-act="delete">Delete my data</button></div>' +
    '<p class="tiny muted">Accountability Partner V1 \u00b7 closed beta</p>');
}

/* ---------------------------------------------------------------- router */
var rendering = 0;
async function render() {
  var my = ++rendering, r = param(0), html;
  try {
    if (r === 'join' && param(1)) html = await viewJoinAsync();
    else if (!APP.user) html = viewWelcome();
    else if (r === 'under18') html = viewUnder18();
    else if (!APP.profile) { html = viewOnboard(); }
    else if (!APP.profile.onboarded && r !== 'new') { if (OB.step < 1) OB.step = 1; html = viewOnboard(); }
    else if (r === 'new') html = viewNew();
    else if (r === 'struggle') html = viewStruggle();
    else if (r === 'iv') html = viewIntervention();
    else if (r === 'recover') html = viewRecover();
    else if (r === 'recovered') html = viewRecovered();
    else if (r === 'journey') { html = viewJourney(); if (!Object.keys(JOURNEY).length || render.jstale) { render.jstale = false; loadJourney().then(function () { if (param(0) === 'journey') paint(viewJourney()); }); } }
    else if (r === 'partners') html = viewPartners();
    else if (r === 'invite') html = viewInvite();
    else if (r === 'share') { var p = APP.partners.filter(function (x) { return x.partnership_id === param(1); })[0]; var pr = await sb.from('ap_partner_permissions').select('*').eq('partnership_id', param(1)).maybeSingle(); html = p && pr.data ? viewShare(pr.data, p) : viewPartners(); }
    else if (r === 'thread') html = await threadHtml(param(1));
    else if (r === 'sos') html = viewSOS();
    else if (r === 'me') html = viewMe();
    else html = viewToday();
  } catch (e) { console.error(e); html = shell('today', '<div class="card warm"><b>We couldn\u2019t load this just now.</b><p class="small">' + esc(friendlyErr(e)) + '</p><button class="btn-sm" data-act="reload">Try again</button></div>'); }
  if (my === rendering) paint(html);
}
function paint(html) { $app.innerHTML = html; window.scrollTo(0, 0); var h1 = $app.querySelector('h1'); if (h1) h1.setAttribute('tabindex', '-1'); }
async function threadHtml(pid) {
  var p = APP.partners.filter(function (x) { return x.partnership_id === pid; })[0], owner = true;
  if (!p) { p = APP.supporting.filter(function (x) { return x.partnership_id === pid; })[0]; owner = false; }
  if (!p) return viewPartners();
  var r = await sb.from('ap_messages').select('*').eq('partnership_id', pid).order('created_at', { ascending: true }).limit(100);
  if (p.unread) { rpc('ap_mark_read', { p_partnership: pid }).catch(function () {}); p.unread = 0; }
  return viewThread(p, r.data || [], owner);
}
async function refreshAll() {
  await Promise.all([loadCommitments(), loadPartners().catch(function () {})]);
}
async function route() {
  var s = await sb.auth.getSession();
  APP.user = s.data.session ? s.data.session.user : null;
  if (APP.user) {
    await Promise.all([loadProfile(), loadCats()]);
    if (APP.profile) { await refreshAll(); flushQueue(); }
  }
  if (!APP.crisis) sb.from('ap_crisis_resources').select('*').order('sort').then(function (r) { if (r.data && r.data.length) { APP.crisis = r.data; try { localStorage.setItem('ap-crisis-list', JSON.stringify(r.data)); } catch (e) {} } });
  render();
}
try { APP.crisis = JSON.parse(localStorage.getItem('ap-crisis-list') || 'null'); } catch (e) {}
window.addEventListener('hashchange', function () { if (param(0) === 'journey') render.jstale = true; render(); });
sb.auth.onAuthStateChange(function (ev) { if (ev === 'SIGNED_OUT') { APP.user = null; APP.profile = null; render(); } });

/* ---------------------------------------------------------------- events */
document.addEventListener('click', async function (e) {
  var g = e.target.closest('[data-go]'); if (g) { e.preventDefault(); go(g.getAttribute('data-go')); return; }
  var b = e.target.closest('[data-act]'); if (!b) return;
  var a = b.getAttribute('data-act'), v = b.getAttribute('data-v'), id = b.getAttribute('data-id');
  try {
    if (a === 'anon') await startAnon(b);
    else if (a === 'google') await google();
    else if (a === 'signout') { if (APP.user && APP.user.is_anonymous && APP.profile && !confirm('This private account lives only on this phone. Sign out anyway?')) return; await sb.auth.signOut(); localStorage.removeItem(QK); go('#/'); }
    else if (a === 'reload') route();
    else if (a === 'ob-age') await obAge();
    else if (a === 'ob-faith') await obFaith(v === '1');
    else if (a === 'ob-fam') { OB.family = v; OB.step = 3; render(); }
    else if (a === 'ob-cat') { OB.cat = v; NEW = { cat: v, family: OB.family }; go('#/new'); }
    else if (a === 'ob-back') { OB.step = Math.max(0, OB.step - 1); render(); }
    else if (a === 'nc-day') { ncRead(); var d = +v, i = NEW.days.indexOf(d); if (i >= 0) NEW.days.splice(i, 1); else NEW.days.push(d); render(); }
    else if (a === 'nc-meas') { ncRead(); NEW.measure = v; render(); }
    else if (a === 'nc-cancel') { if (!APP.profile.onboarded) { OB.step = 3; } NEW = {}; go(APP.profile.onboarded ? '#/' : '#/'); }
    else if (a === 'nc-save') await ncSave(b);
    else if (a === 'ci') await checkIn(id, v, b);
    else if (a === 'ci-change') { delete APP.today[id]; render(); }
    else if (a === 'iv') go('#/iv/' + id + '/' + v);
    else if (a === 'iv-done') { if (v === '1') { toast('Good. One small step now.'); go('#/'); } else go('#/recover/' + id + '/struggling'); }
    else if (a === 'ask-partner') { var ps = APP.partners.filter(function (p) { return p.commitment_id === id && p.status === 'active'; }); for (var k = 0; k < ps.length; k++) await rpc('ap_send', { p_partnership: ps[k].partnership_id, p_kind: 'checkin_request', p_body: null }); toast('Your partner was asked to check on you.'); }
    else if (a === 'rc-r') { var ri = REC.reasons.indexOf(v); if (ri >= 0) REC.reasons.splice(ri, 1); else if (REC.reasons.length < 3) REC.reasons.push(v); else toast('Up to three is plenty.'); render(); }
    else if (a === 'rc-next') {
      if (REC.step === 0 && !REC.reasons.length) { toast('Choose at least one, or \u201cSomething else\u201d.'); return; }
      if (REC.step === 1) { REC.note = document.getElementById('rn').value; var hs = await sb.from('ap_setbacks').select('changes,recovered_at').eq('commitment_id', REC.cid); REC.history = hs.data || []; REC.picked = null; }
      REC.step++; render();
    }
    else if (a === 'rc-pick') { var pi = REC.picked.indexOf(v); if (b.checked && pi < 0) REC.picked.push(v); if (!b.checked && pi >= 0) REC.picked.splice(pi, 1); }
    else if (a === 'rc-apply') { b.disabled = true; await recApply(v === 'none'); }
    else if (a === 'comeback') { await rpc('ap_start_comeback', { p_commitment: id }); await loadCommitments(); toast('Comeback Mission started: 7 gentle days.'); go('#/'); }
    else if (a === 'keep') { var res = await rpc('ap_keep_going', { p_partnership: id, p_keep: v === '1' }); toast(res === 'kept' ? 'Great. Keep going together.' : 'Partnership ended kindly. Your history stays.'); await loadPartners(); render(); }
    else if (a === 'cheer') { await rpc('ap_send', { p_partnership: id, p_kind: 'cheer', p_body: null }); toast('Encouragement sent \ud83d\udc4f'); }
    else if (a === 'quick') { await rpc('ap_send', { p_partnership: id, p_kind: 'message', p_body: v }); render(); }
    else if (a === 'send') { var mt = document.getElementById('mt'), t = mt.value.trim(); if (!t) return; if (crisisMatch(t)) toast('If you or your partner might be in danger, the support lines are under \u201cI need support\u201d.'); b.disabled = true; await rpc('ap_send', { p_partnership: id, p_kind: 'message', p_body: t }); render(); }
    else if (a === 'inv-make') { var lab = document.getElementById('il').value.trim(); b.disabled = true; var tok = await rpc('ap_create_invite', { p_commitment: id, p_label: lab || null }); INV = { cid: id, link: location.origin + '/#/join/' + tok }; render(); }
    else if (a === 'inv-share') { if (navigator.share) navigator.share({ text: v }).catch(function () {}); else { copy(v); } }
    else if (a === 'copy') copy(v);
    else if (a === 'join') { b.disabled = true; var alias = document.getElementById('ja').value.trim(); await rpc('ap_accept_invite', { p_token: v, p_alias: alias || null }); sessionStorage.removeItem('ap-join'); await loadPartners(); toast('You\u2019re now a partner. Thank you for showing up.'); go('#/partners'); }
    else if (a === 'join-no') { sessionStorage.removeItem('ap-join'); go('#/'); }
    else if (a === 'perm') { var patch = {}; patch[v] = v === 'setbacks' ? (b.checked ? 'count' : 'none') : b.checked; var pr = await sb.from('ap_partner_permissions').update(patch).eq('partnership_id', id); if (pr.error) throw pr.error; toast('Saved'); }
    else if (a === 'end') { if (!confirm('End this partnership? Your own history stays.')) return; await rpc('ap_end_partnership', { p_partnership: id }); await loadPartners(); go('#/partners'); }
    else if (a === 'report') await report(id);
    else if (a === 'sos-next') { SOS.step = 1; render(); }
    else if (a === 'sos-iv') { SOS.step = 0; render(); }
    else if (a === 'sos-close') { SOS.step = 0; go('#/'); }
    else if (a === 'sos-notify') { b.disabled = true; var sr = await rpc('ap_sos', { p_commitment: null }); toast(sr.notified ? 'Your partner was told you asked for support.' : 'We already let your partners know recently.'); }
    else if (a === 'me-save') { var up = { display_name: document.getElementById('mn').value.trim() || null, faith_enabled: document.getElementById('mf').checked, timezone: document.getElementById('mz').value.trim() || 'Africa/Lagos' }; var mr = await sb.from('ap_profiles').update(up).eq('id', APP.user.id).select().single(); if (mr.error) throw mr.error; APP.profile = mr.data; toast('Saved'); }
    else if (a === 'pause') { var cr = await sb.from('ap_commitments').update({ status: v }).eq('id', id); if (cr.error) throw cr.error; await loadCommitments(); render(); }
    else if (a === 'delete') { if (!confirm('Delete all your commitments, check-ins and partnerships? This cannot be undone.')) return; await rpc('ap_delete_me'); await sb.auth.signOut(); localStorage.removeItem(QK); go('#/'); }
  } catch (err) { console.error(err); toast(friendlyErr(err)); b.disabled = false; }
});
document.addEventListener('change', function (e) { var s = e.target.closest('[data-act="inv-c"]'); if (s) { INV = {}; go('#/invite/' + s.value); } });
function copy(t) { if (navigator.clipboard) navigator.clipboard.writeText(t).then(function () { toast('Copied'); }); else { var i = document.createElement('textarea'); i.value = t; document.body.appendChild(i); i.select(); document.execCommand('copy'); i.remove(); toast('Copied'); } }
async function report(pid) {
  var reason = prompt('What happened? Type one: harassment, sexual, spam, unsafe, other', 'other'); if (!reason) return;
  reason = String(reason).trim().toLowerCase(); if (['harassment', 'sexual', 'spam', 'unsafe', 'other'].indexOf(reason) < 0) reason = 'other';
  var details = prompt('Anything else we should know? (optional)', '') || null;
  var r = await sb.from('ap_reports').insert({ partnership_id: pid || null, reason: reason, details: details, reporter_id: APP.user.id }).select('id').single();
  if (r.error) throw r.error;
  var s = await sb.auth.getSession();
  fetch('/api/report', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + s.data.session.access_token }, body: JSON.stringify({ report_id: r.data.id }) }).catch(function () {});
  toast('Thank you. A person will review this within 24 hours.' + (pid ? ' Messaging is paused meanwhile.' : ''));
  if (pid) { await loadPartners(); go('#/partners'); }
}

if ('serviceWorker' in navigator) window.addEventListener('load', function () { navigator.serviceWorker.register('/sw.js').catch(function () {}); });
route();
})();
