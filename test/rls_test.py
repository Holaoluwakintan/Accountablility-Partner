"""RLS and privacy checks for Accountability Partner, against the live Supabase project via the public REST API.
Run: SUPABASE_URL=... SUPABASE_ANON_KEY=... python3 test/rls_test.py   (creates throwaway anonymous users)
"""
import os, sys, requests
SB = os.environ['SUPABASE_URL']; ANON = os.environ['SUPABASE_ANON_KEY']
results = []
def check(name, ok, extra=''):
    results.append(ok); print(('PASS ' if ok else 'FAIL ') + name, extra)
def user():
    r = requests.post(SB + '/auth/v1/signup', headers={'apikey': ANON}, json={}, timeout=30); j = r.json()
    return {'id': j['user']['id'], 'tok': j['access_token']}
def api(u, m, path, body=None, params=None, prefer=None):
    h = {'apikey': ANON, 'Authorization': 'Bearer ' + (u['tok'] if u else ANON)}
    if prefer: h['Prefer'] = prefer
    r = requests.request(m, SB + '/rest/v1/' + path, headers=h, json=body, params=params, timeout=30)
    try: return r.status_code, r.json()
    except Exception: return r.status_code, r.text
A, B, C = user(), user(), user()
check('under-18 profile rejected', api(C, 'POST', 'ap_profiles', {'id': C['id'], 'birth_year': 2012})[1].get('message') == 'adults_only')
check('profile id spoofing blocked', api(C, 'POST', 'ap_profiles', {'id': A['id'], 'birth_year': 1990})[0] == 403)
for u, n, y in ((A, 'Owner', 1994), (B, 'Partner', 1990), (C, 'Stranger', 1985)):
    api(u, 'POST', 'ap_profiles', {'id': u['id'], 'birth_year': y, 'display_name': n, 'onboarded': True})
s, c = api(A, 'POST', 'ap_commitments', {'title': 'Read 10 pages', 'why': 'SECRET-WHY', 'category_slug': 'reading', 'kind': 'start', 'start_date': '2000-01-01'}, prefer='return=representation')
cid = c[0]['id']; today = api(A, 'POST', 'rpc/ap_journey', {'p_commitment': cid})[1]['today']
check('start_date cannot be backdated by the client', c[0]['start_date'] == today, c[0]['start_date'])
api(A, 'POST', 'rpc/ap_check_in', {'p_commitment': cid, 'p_date': today, 'p_status': 'struggling', 'p_note': 'SECRET-NOTE'})
api(A, 'POST', 'ap_setbacks', {'commitment_id': cid, 'local_date': today, 'source': 'struggling', 'reasons': ['fatigue'], 'before_note': 'SECRET-BEFORE'})
for t in ('ap_commitments', 'ap_check_ins', 'ap_setbacks', 'ap_schedules', 'ap_invites', 'ap_partner_permissions'):
    check(f'B cannot read A rows in {t}', api(B, 'GET', t, params={'select': '*'})[1] == [])
check('anon role cannot read commitments', api(None, 'GET', 'ap_commitments', params={'select': 'id'})[0] in (401, 403))
check('B cannot check in on A commitment', api(B, 'POST', 'rpc/ap_check_in', {'p_commitment': cid, 'p_date': today, 'p_status': 'done'})[0] == 400)
check('B cannot read A journey', api(B, 'POST', 'rpc/ap_journey', {'p_commitment': cid})[0] == 400)
check('A cannot delete history', api(A, 'DELETE', 'ap_check_ins', params={'commitment_id': 'eq.' + cid})[0] == 403)
s, tok = api(A, 'POST', 'rpc/ap_create_invite', {'p_commitment': cid, 'p_label': 'Partner'})
check('owner cannot accept own invite', api(A, 'POST', 'rpc/ap_accept_invite', {'p_token': tok, 'p_alias': 'x'})[1].get('message') == 'own_invite')
s, pid = api(B, 'POST', 'rpc/ap_accept_invite', {'p_token': tok, 'p_alias': 'Partner'})
check('partner accepts invite', s == 200)
check('invite is single-use', api(C, 'POST', 'rpc/ap_accept_invite', {'p_token': tok, 'p_alias': 'c'})[1].get('message') == 'invite_invalid')
v = api(B, 'POST', 'rpc/ap_partner_view', {})[1]
blob = str(v)
check('partner sees status projection', len(v) == 1 and v[0]['today_status'] == 'struggling')
check('partner does not see why/note/setback detail by default', 'SECRET' not in blob and v[0]['why'] is None and v[0]['setbacks'] is None)
check('partner cannot read permissions or change them', api(B, 'PATCH', 'ap_partner_permissions', {'show_why': True}, params={'partnership_id': 'eq.' + pid}, prefer='return=representation')[1] == [])
check('stranger sees no projection', api(C, 'POST', 'rpc/ap_partner_view', {})[1] == [])
api(A, 'PATCH', 'ap_partner_permissions', {'show_why': True, 'setbacks': 'count'}, params={'partnership_id': 'eq.' + pid})
v = api(B, 'POST', 'rpc/ap_partner_view', {})[1][0]
check('owner can share why + setback count', v['why'] == 'SECRET-WHY' and v['setbacks']['total'] == 1)
check('private before-note never in projection', 'SECRET-BEFORE' not in str(v))
check('stranger cannot message the partnership', api(C, 'POST', 'rpc/ap_send', {'p_partnership': pid, 'p_kind': 'cheer'})[0] == 400)
check('partner can encourage', api(B, 'POST', 'rpc/ap_send', {'p_partnership': pid, 'p_kind': 'cheer'})[0] == 200)
check('SOS notifies partner', api(A, 'POST', 'rpc/ap_sos', {'p_commitment': cid})[1].get('notified') == 1)
check('stranger cannot read messages', api(C, 'GET', 'ap_messages', params={'select': '*'})[1] == [])
api(A, 'POST', 'rpc/ap_check_in', {'p_commitment': cid, 'p_date': today, 'p_status': 'done'})
j = api(A, 'POST', 'rpc/ap_journey', {'p_commitment': cid})[1]
check('setback marked recovered after on-track check-in', j['recovered'] == 1, str({k: j[k] for k in ('recovered', 'setbacks', 'current_run')}))
check('owner cannot edit recovered_at', api(A, 'PATCH', 'ap_setbacks', {'recovered_at': None}, params={'commitment_id': 'eq.' + cid})[0] == 403)
check('report freezes messaging', api(B, 'POST', 'ap_reports', {'partnership_id': pid, 'reason': 'other', 'details': 'automated test'})[0] == 201
      and api(B, 'POST', 'rpc/ap_send', {'p_partnership': pid, 'p_kind': 'cheer'})[1].get('message') == 'partnership_not_active')
check('stranger cannot report others partnership', api(C, 'POST', 'ap_reports', {'partnership_id': pid, 'reason': 'spam'})[0] == 400)
for u in (A, B, C): api(u, 'POST', 'rpc/ap_delete_me', {})
check('delete my data removes rows', api(A, 'GET', 'ap_commitments', params={'select': 'id'})[1] == [])
print(f'{sum(results)}/{len(results)} passed'); sys.exit(0 if all(results) else 1)
