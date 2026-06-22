const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { audit } = require('./_audit');
// Serverless endpoint: an ADMIN permanently deletes a user ("Delete forever").
// This removes the auth.users record (service-role only), which cascades to the
// profiles row (profiles.id references auth.users on delete cascade). Once gone,
// the email is free to sign up again.
//
// Requires Vercel env vars:
//   SUPABASE_URL                — project URL (defaults below)
//   SUPABASE_SERVICE_ROLE_KEY   — service_role key (Supabase → Settings → API)
const { createClient } = require('@supabase/supabase-js');

// Extract storage object paths (within the 'photos' bucket) from an image_url
// value (single URL or JSON array). base64/external links are ignored.
function storagePathsFromImageUrl(val) {
  if (!val || typeof val !== 'string') return [];
  let urls = [];
  if (val.trim().startsWith('[')) { try { urls = JSON.parse(val) || []; } catch (e) { urls = []; } }
  else urls = [val];
  const paths = [];
  for (const u of urls) {
    if (typeof u === 'string' && u.indexOf('/storage/v1/object/') !== -1 && u.indexOf('/photos/') !== -1) {
      paths.push(u.split('/photos/')[1].split('?')[0]);
    }
  }
  return paths;
}

module.exports = async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const _rl = rateLimit('admin-delete-user:' + clientIp(req), 20, 10 * 60 * 1000);
  if (!_rl.allowed) { audit(req, { type: 'rate_limit', severity: 'warn', meta: { route: 'admin-delete-user' } }); res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests — please try again later' }); }

  const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY — add it in Vercel env vars' });

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const { user_id } = body || {};
  if (!user_id) return res.status(400).json({ error: 'user_id required' });

  // The caller must prove they're an admin: read their JWT, look up their role.
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Not signed in' });

  try {
    const admin = createClient(url, key, { auth: { persistSession: false } });

    // 1) Who is calling? Verify the JWT. (getUser validates the token signature.)
    let callerId = null;
    const { data: who, error: whoErr } = await admin.auth.getUser(token);
    if (who && who.user) {
      callerId = who.user.id;
    } else {
      // Fallback for the new sb_secret_ keys, where getUser(token) can reject the
      // apikey: decode the JWT payload to read the user id, then confirm that user
      // actually exists via the trusted service client (getUserById).
      try {
        const payload = JSON.parse(Buffer.from(token.split('.')[1] || '', 'base64').toString('utf8'));
        const sub = payload && payload.sub;
        if (sub) {
          const { data: byId } = await admin.auth.admin.getUserById(sub);
          if (byId && byId.user) callerId = byId.user.id;
        }
      } catch (e) {}
      if (!callerId) return res.status(401).json({ error: 'Invalid session' + (whoErr && whoErr.message ? ' (' + whoErr.message + ')' : '') });
    }

    // 2) Permanently deleting a user is restricted to SUPER ADMINS.
    const { data: prof, error: profErr } = await admin
      .from('profiles').select('role').eq('id', callerId).single();
    if (profErr || !prof || prof.role !== 'super_admin') {
      { audit(req, { type: 'permission_denied', severity: 'warn', actor: callerId, target: user_id, meta: { route: 'admin-delete-user', need: 'super_admin' } }); return res.status(403).json({ error: 'Super admins only' }); }
    }

    // 3) Don't let an admin delete their own account by accident.
    if (callerId === user_id) return res.status(400).json({ error: "You can't permanently delete your own account here" });

    // 4) Collect the user's storage images BEFORE deleting, so we can remove the
    //    blobs afterwards (the cascade frees the rows but not the storage objects).
    const blobPaths = [];
    try {
      const { data: pr } = await admin.from('profiles').select('avatar_url').eq('id', user_id).single();
      if (pr) blobPaths.push(...storagePathsFromImageUrl(pr.avatar_url));
    } catch (e) {}
    for (const t of ['community_deals', 'match_screenings', 'community_events']) {
      try {
        const { data: imgs } = await admin.from(t).select('image_url').eq('user_id', user_id);
        for (const ir of (imgs || [])) blobPaths.push(...storagePathsFromImageUrl(ir.image_url));
      } catch (e) {}
    }
    // Venues this user owns → their deals' images.
    try {
      const { data: vens } = await admin.from('venues').select('id').eq('owner_id', user_id);
      for (const v of (vens || [])) {
        const { data: dimgs } = await admin.from('deals').select('image_url').eq('venue_id', v.id);
        for (const ir of (dimgs || [])) blobPaths.push(...storagePathsFromImageUrl(ir.image_url));
      }
    } catch (e) {}

    // 5) Permanently delete the auth user (cascades to the profiles row).
    const { error: delErr } = await admin.auth.admin.deleteUser(user_id);
    if (delErr) {
      // If the auth user is already gone, still clear any orphaned profile row.
      await admin.from('profiles').delete().eq('id', user_id);
      if (!/not\s*found/i.test(delErr.message || '')) return res.status(400).json({ error: delErr.message });
    }

    // Safety net in case the FK cascade isn't in place on this project.
    await admin.from('profiles').delete().eq('id', user_id);

    // 6) POLICY: NEVER auto-delete contributor photos — they're irreplaceable.
    // We RETAIN the user's uploaded images even when the account is deleted.
    // (Their personal profile row + data rows are removed above for erasure.)
    // Do not re-add a storage .remove() call here.
    var blobsRetained = Array.from(new Set(blobPaths)).length;

    audit(req, { type: 'admin_delete_user', severity: 'warn', actor: callerId, target: user_id, meta: { route: 'admin-delete-user' } });
    return res.json({ ok: true, blobsRetained });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
