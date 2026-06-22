const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
// Scheduled job (Vercel Cron): permanently erase accounts whose 30-day deletion
// grace period has elapsed. For each profile with deleted_at older than 30 days
// we delete the auth.users record, which cascades to the profiles row (and any
// data with an ON DELETE CASCADE FK to it) and frees the email for reuse.
//
// Triggered daily by the cron entry in vercel.json. Vercel sends the cron request
// with an "Authorization: Bearer <CRON_SECRET>" header, so we require that secret.
// A super_admin may also trigger it manually with their own bearer token.
//
// Requires Vercel env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, CRON_SECRET
const { createClient } = require('@supabase/supabase-js');

const GRACE_DAYS = 30;

// Extract storage object paths (within the 'photos' bucket) from an image_url
// value, which may be a single public URL or a JSON array of URLs. base64 and
// external URLs are ignored so we only ever delete our own storage blobs.
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

  const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const cronSecret = process.env.CRON_SECRET;
  if (!key) return res.status(500).json({ error: 'Server missing SUPABASE_SERVICE_ROLE_KEY' });

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');

  try {
    const admin = createClient(url, key, { auth: { persistSession: false } });

    // AuthZ: either the Vercel cron secret, or a super_admin's token.
    let authorized = false;
    if (cronSecret && token && token === cronSecret) {
      authorized = true;
    } else if (token) {
      let callerId = null;
      const { data: who } = await admin.auth.getUser(token);
      if (who && who.user) callerId = who.user.id;
      else {
        try {
          const payload = JSON.parse(Buffer.from(token.split('.')[1] || '', 'base64').toString('utf8'));
          if (payload && payload.sub) {
            const { data: byId } = await admin.auth.admin.getUserById(payload.sub);
            if (byId && byId.user) callerId = byId.user.id;
          }
        } catch (e) {}
      }
      if (callerId) {
        const { data: prof } = await admin.from('profiles').select('role').eq('id', callerId).single();
        if (prof && prof.role === 'super_admin') authorized = true;
      }
    }
    if (!authorized) return res.status(401).json({ error: 'Unauthorized' });

    // Find accounts whose grace period has elapsed.
    const cutoff = new Date(Date.now() - GRACE_DAYS * 24 * 60 * 60 * 1000).toISOString();
    const { data: due, error: qErr } = await admin
      .from('profiles')
      .select('id')
      .not('deleted_at', 'is', null)
      .lt('deleted_at', cutoff)
      .limit(500);
    if (qErr) return res.status(500).json({ error: qErr.message });

    // User-owned tables keyed by the column holding the user id. We delete these
    // explicitly so erasure is complete even if an ON DELETE CASCADE FK is missing.
    const ownedTables = [
      ['saved_deals','user_id'], ['reviews','user_id'], ['voucher_purchases','user_id'],
      ['voucher_bookings','user_id'], ['credits_ledger','user_id'], ['wallet_ledger','user_id'],
      ['notifications','user_id'], ['event_rsvps','user_id'], ['deal_reports','user_id'],
      ['deal_mistake_reports','user_id'], ['deal_arrival_times','user_id'],
      ['screening_reports','user_id'], ['community_deals','user_id'],
      ['match_screenings','user_id'], ['community_events','user_id'],
      ['merchant_applications','user_id']
    ];

    let purged = 0; const errors = [];
    const blobPaths = []; // storage objects to delete once their rows are gone
    for (const row of (due || [])) {
      try {
        // 0) Collect this user's storage images BEFORE the rows vanish.
        try {
          const { data: pr } = await admin.from('profiles').select('avatar_url').eq('id', row.id).single();
          if (pr) blobPaths.push(...storagePathsFromImageUrl(pr.avatar_url));
        } catch (e) {}
        for (const t of ['community_deals', 'match_screenings', 'community_events']) {
          try {
            const { data: imgs } = await admin.from(t).select('image_url').eq('user_id', row.id);
            for (const ir of (imgs || [])) blobPaths.push(...storagePathsFromImageUrl(ir.image_url));
          } catch (e) {}
        }
        // 1) Remove the user's own data rows first (best-effort per table).
        for (const [tbl, col] of ownedTables) {
          try { await admin.from(tbl).delete().eq(col, row.id); } catch (e) { /* table may not exist */ }
        }
        // 2) Delete the auth user (frees the email; cascades to FK-linked rows).
        const { error: delErr } = await admin.auth.admin.deleteUser(row.id);
        if (delErr && !/not\s*found/i.test(delErr.message || '')) {
          errors.push({ id: row.id, error: delErr.message });
        }
        // 3) Safety net in case the auth→profiles cascade FK isn't in place.
        await admin.from('profiles').delete().eq('id', row.id);
        purged++;
      } catch (e) {
        errors.push({ id: row.id, error: e.message || 'delete failed' });
      }
    }

    // Venues (merchants) are soft-deleted with deleted_at too. Erase those past
    // the grace period, removing their deals first (deals.venue_id).
    let venuesPurged = 0;
    try {
      const { data: dueVenues } = await admin
        .from('venues').select('id')
        .not('deleted_at', 'is', null).lt('deleted_at', cutoff).limit(500);
      for (const v of (dueVenues || [])) {
        try {
          try {
            const { data: dimgs } = await admin.from('deals').select('image_url').eq('venue_id', v.id);
            for (const ir of (dimgs || [])) blobPaths.push(...storagePathsFromImageUrl(ir.image_url));
          } catch (e) {}
          try { await admin.from('deals').delete().eq('venue_id', v.id); } catch (e) {}
          await admin.from('venues').delete().eq('id', v.id);
          venuesPurged++;
        } catch (e) { errors.push({ venue: v.id, error: e.message || 'venue delete failed' }); }
      }
    } catch (e) { errors.push({ stage: 'venues', error: e.message || 'venue query failed' }); }

    // Admin "Delete permanently" on rejected community deals: a 30-day grace,
    // then the ROW and its PHOTOS are erased. This is the ONE place we delete
    // storage blobs — and ONLY for deals an admin explicitly flagged (deleted_at
    // set via admin_delete_community_deal). The account/venue paths above still
    // RETAIN photos; that policy is unchanged.
    let dealsPurged = 0; let dealBlobsDeleted = 0;
    try {
      const { data: dueDeals } = await admin
        .from('community_deals').select('id, image_url')
        .not('deleted_at', 'is', null).lt('deleted_at', cutoff).limit(500);
      const dealBlobPaths = [];
      for (const d of (dueDeals || [])) {
        try {
          dealBlobPaths.push(...storagePathsFromImageUrl(d.image_url));
          await admin.from('community_deals').delete().eq('id', d.id);
          dealsPurged++;
        } catch (e) { errors.push({ deal: d.id, error: e.message || 'deal purge failed' }); }
      }
      const uniqueDealBlobs = Array.from(new Set(dealBlobPaths));
      if (uniqueDealBlobs.length) {
        try {
          const { error: rmErr } = await admin.storage.from('photos').remove(uniqueDealBlobs);
          if (rmErr) errors.push({ stage: 'deal-blobs', error: rmErr.message });
          else dealBlobsDeleted = uniqueDealBlobs.length;
        } catch (e) { errors.push({ stage: 'deal-blobs', error: e.message }); }
      }
    } catch (e) { errors.push({ stage: 'community_deals_purge', error: e.message || 'deal query failed' }); }

    // POLICY: account/venue purges NEVER auto-delete contributor photos — they
    // are irreplaceable and orphaned blobs are harmless. We RETAIN every image
    // from those paths. (The only exception is the admin-flagged community-deal
    // purge directly above, which an admin explicitly opted into.)
    var blobsRetained = Array.from(new Set(blobPaths)).length;

    return res.json({ ok: true, cutoff, candidates: (due || []).length, purged, venuesPurged, dealsPurged, dealBlobsDeleted, blobsRetained, errors });
  } catch (e) {
    return res.status(500).json({ error: e.message || 'Unknown error' });
  }
};
