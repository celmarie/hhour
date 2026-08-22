// Public deal feed — edge-cached. The community feed is identical for everyone,
// so we serve it from Vercel's CDN: during a rush (e.g. 5pm happy hour) the cache
// absorbs the load and Supabase is queried at most ~once per 30s, instead of every
// browser hammering PostgREST directly (which collapsed under load — see the k6
// feed-spike test). Reads only public, approved, non-deleted deals via the anon key.
const { createClient } = require('@supabase/supabase-js');

// Public anon key (already shipped in the client; safe here). Prefer env if set.
const ANON = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhqenlxaGZ1dmNzd2Zjdmtqc3l2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk4OTk2MzIsImV4cCI6MjA5NTQ3NTYzMn0.lh16PE4S2LA2vxvA31tuxiSTV_1s8DBRDXhJYwBTdoU';

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') return res.status(204).end();
  try {
    const url = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
    const sb = createClient(url, ANON, { auth: { persistSession: false } });
    const { data, error } = await sb
      .from('community_deals')
      .select('*')
      .eq('status', 'approved')
      .is('deleted_at', null)
      .order('created_at', { ascending: false })
      .limit(2000);  // Contract with the client: fetchCommunityFeed treats a payload
                     // of >= 2000 rows as truncated and re-pages the full set from
                     // Supabase directly, so deals can never silently vanish again
                     // (bit us at 400 when approved deals hit 404). If you raise this
                     // limit, raise the client's check too — never lower either one.
    if (error) {
      res.setHeader('Cache-Control', 'no-store');
      return res.status(500).json({ error: error.message });
    }
    // Shared edge cache: 30s fresh, then serve stale up to 60s while revalidating.
    res.setHeader('Cache-Control', 'public, s-maxage=30, stale-while-revalidate=60');
    res.setHeader('Content-Type', 'application/json');
    return res.status(200).json(data || []);
  } catch (e) {
    res.setHeader('Cache-Control', 'no-store');
    return res.status(500).json({ error: (e && e.message) || 'feed error' });
  }
};
