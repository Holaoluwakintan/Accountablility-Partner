// POST /api/report  { report_id }  with the reporter's Supabase access token.
// Emails Michael (moderator) about a new report. Keys live in Vercel env, never in the client.
const SB = process.env.SUPABASE_URL;
const SECRET = process.env.SUPABASE_SECRET_KEY;
const ANON = process.env.SUPABASE_ANON_KEY;
const BREVO = process.env.BREVO_API_KEY;
const TO = process.env.REPORT_TO || 'michaelolaoluwagab@gmail.com';
const FROM = process.env.REPORT_FROM || 'michaelolaoluwagab@gmail.com';
// REPORT_SANDBOX=1 (preview deployments only) validates with Brevo without delivering.
const SANDBOX = process.env.REPORT_SANDBOX === '1';
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method' });
  try {
    const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    if (!token || !/^[0-9a-f-]{36}$/.test(body.report_id || '')) return res.status(400).json({ error: 'bad_request' });
    const u = await fetch(`${SB}/auth/v1/user`, { headers: { apikey: ANON, Authorization: `Bearer ${token}` } });
    if (!u.ok) return res.status(401).json({ error: 'auth' });
    const user = await u.json();
    const h = { apikey: SECRET, Authorization: `Bearer ${SECRET}`, 'Content-Type': 'application/json' };
    const r = await fetch(`${SB}/rest/v1/ap_reports?id=eq.${body.report_id}&reporter_id=eq.${user.id}&emailed_at=is.null&select=*`, { headers: h });
    const rows = await r.json();
    if (!Array.isArray(rows) || !rows.length) return res.status(200).json({ ok: true, emailed: false });
    const rep = rows[0];
    const html = `<p>A new report was filed in Accountability Partner. Messaging on that partnership is already paused.</p>
      <ul><li><b>Reason:</b> ${esc(rep.reason)}</li><li><b>Details:</b> ${esc(rep.details || '(none)')}</li>
      <li><b>Partnership:</b> ${esc(rep.partnership_id || '(general)')}</li><li><b>Report id:</b> ${esc(rep.id)}</li><li><b>When:</b> ${esc(rep.created_at)}</li></ul>
      <p>Review it in Supabase (table ap_reports). Promise: a human decision within 24 hours.</p>`;
    const m = await fetch('https://api.brevo.com/v3/smtp/email', { method: 'POST', headers: { 'api-key': BREVO, 'Content-Type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ sender: { name: 'Accountability Partner', email: FROM }, to: [{ email: TO }], subject: `Report: ${rep.reason} (Accountability Partner)`, htmlContent: html, ...(SANDBOX ? { headers: { 'X-Sib-Sandbox': 'drop' } } : {}) }) });
    if (m.ok) await fetch(`${SB}/rest/v1/ap_reports?id=eq.${rep.id}`, { method: 'PATCH', headers: h, body: JSON.stringify({ emailed_at: new Date().toISOString() }) });
    return res.status(200).json({ ok: true, emailed: m.ok });
  } catch (e) {
    return res.status(200).json({ ok: false });
  }
};
