// Server-side security audit logging. Writes to the security_events table with
// the service-role key — these are the tamper-proof signals (rate-limit hits,
// permission-denied, sensitive admin actions) that a client could never be
// trusted to report.
//
// Two hard rules:
//   1. NEVER throws — logging must not break the request it's observing.
//   2. NEVER stores secrets — any meta key matching the pattern is dropped.
const { createClient } = require('@supabase/supabase-js');

const SECRET_KEY = /(password|passwd|pwd|secret|token|jwt|api[_-]?key|authorization|bearer|otp|cvv|card|ssn|access[_-]?token|refresh[_-]?token|private[_-]?key)/i;

function sanitize(meta) {
  const out = {};
  if (meta && typeof meta === 'object') {
    for (const k of Object.keys(meta)) {
      if (SECRET_KEY.test(k)) continue;
      let v = meta[k];
      if (typeof v === 'string' && v.length > 300) v = v.slice(0, 300);
      out[k] = v;
    }
  }
  return out;
}

function clientIp(req) {
  return (((req.headers && req.headers['x-forwarded-for']) || '').split(',')[0] || '').trim() || null;
}

// audit(req, { type, severity, actor, target, meta })
async function audit(req, opts) {
  try {
    const o = opts || {};
    if (!o.type) return;
    const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!key) return;
    const sb = createClient(url, key, { auth: { persistSession: false } });
    await sb.from('security_events').insert({
      event_type: String(o.type).slice(0, 80),
      severity: ['info', 'warn', 'critical'].includes(o.severity) ? o.severity : 'info',
      actor_id: o.actor || null,
      target_id: o.target || null,
      ip: clientIp(req),
      user_agent: (((req.headers && req.headers['user-agent']) || '').slice(0, 300)) || null,
      meta: sanitize(o.meta || {}),
    });
  } catch (e) { /* swallow — never break the request because logging failed */ }
}

module.exports = { audit, sanitize };
