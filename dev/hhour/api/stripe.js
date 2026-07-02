const { applyCors } = require('./_cors');
const { rateLimit, clientIp } = require('./_ratelimit');
const { audit } = require('./_audit');
const Stripe = require('stripe');
const { createClient } = require('@supabase/supabase-js');

const SB_URL = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';

// Constrain a client-supplied redirect (Stripe return/refresh URL) to our own
// hosts over https. Prevents this endpoint being used to bounce users to an
// attacker-controlled site after onboarding (open-redirect / phishing aid).
// Anything not on the allowlist falls back to a safe default.
function safeAppUrl(u, fallback) {
  try {
    if (!u) return fallback;
    const p = new URL(String(u));
    if (p.protocol !== 'https:') return fallback;
    const h = p.hostname.toLowerCase();
    const ok = h === 'appiehour.com' || h === 'www.appiehour.com' || h.endsWith('.vercel.app');
    return ok ? p.toString() : fallback;
  } catch (e) { return fallback; }
}

async function getCaller(req) {
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return { error: 'Not signed in', status: 401 };
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return { error: 'Server missing SUPABASE_SERVICE_ROLE_KEY', status: 500 };
  try {
    const sb = createClient(SB_URL, key, { auth: { persistSession: false } });
    let uid = null;
    const { data: who } = await sb.auth.getUser(token);
    if (who && who.user) {
      uid = who.user.id;
    } else {
      // getUser can reject valid sb_secret_-era tokens — fall back to the JWT sub.
      try {
        const payload = JSON.parse(Buffer.from(token.split('.')[1] || '', 'base64').toString('utf8'));
        if (payload && payload.sub) {
          const { data: byId } = await sb.auth.admin.getUserById(payload.sub);
          if (byId && byId.user) uid = byId.user.id;
        }
      } catch (e) {}
      if (!uid) return { error: 'Invalid session', status: 401 };
    }
    const { data: prof } = await sb.from('profiles').select('role').eq('id', uid).single();
    return { user: { id: uid }, isAdmin: !!prof && ['admin', 'super_admin'].includes(prof.role) };
  } catch (e) { return { error: 'Auth check failed', status: 401 }; }
}
// True if the caller owns a venue linked to this Stripe connected account.
async function callerOwnsAccount(userId, accountId) {
  try {
    const sb = createClient(SB_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const { data } = await sb.from('venues').select('id').eq('owner_id', userId).eq('stripe_account_id', accountId).limit(1);
    return !!(data && data.length);
  } catch (e) { return false; }
}

module.exports = async function handler(req, res) {
  const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();

  // Throttle per IP — payment-intent / Connect-account creation is costly to spam.
  const _rl = await rateLimit('stripe:' + clientIp(req), 40, 10 * 60 * 1000);
  if (!_rl.allowed) { audit(req, { type: 'rate_limit', severity: 'warn', meta: { route: 'stripe', action: req.query && req.query.action } }); res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests — please try again later' }); }

  const { action } = req.query;

  // AuthZ: every action requires a signed-in user; moving money or listing all
  // connected accounts requires an admin.
  const caller = await getCaller(req);
  if (caller.error) return res.status(caller.status).json({ error: caller.error });
  if ((action === 'create_payout' || action === 'list_accounts') && !caller.isAdmin) {
    audit(req, { type: 'permission_denied', severity: 'warn', actor: caller.user && caller.user.id, meta: { route: 'stripe', action: action, need: 'admin' } });
    return res.status(403).json({ error: 'Admins only' });
  }

  try {
    // ── Create a Stripe Connect Express account for a merchant ──────────────
    if (action === 'create_account') {
      const { email, name, venue_name, country = 'ES' } = req.body || {};
      if (!email) return res.status(400).json({ error: 'Email required' });

      const account = await stripe.accounts.create({
        type: 'express',
        country,
        email,
        capabilities: { transfers: { requested: true } },
        business_type: 'company',
        company: { name: venue_name || name },
        metadata: { owner_name: name || '', venue_name: venue_name || '' },
      });

      return res.json({ account_id: account.id });
    }

    // ── Generate onboarding link so merchant can enter their bank details ───
    if (action === 'onboarding_link') {
      const { account_id, return_url, refresh_url } = req.body || {};
      if (!account_id) return res.status(400).json({ error: 'account_id required' });
      if (!caller.isAdmin && !(await callerOwnsAccount(caller.user.id, account_id))) {
        { audit(req, { type: 'permission_denied', severity: 'warn', actor: caller.user && caller.user.id, meta: { route: 'stripe', action: action, reason: 'not_account_owner' } }); return res.status(403).json({ error: 'Not your account' }); }
      }

      // Validate the client-supplied redirects against our own hosts; never
      // reflect an arbitrary URL into Stripe's redirect.
      const link = await stripe.accountLinks.create({
        account: account_id,
        return_url:  safeAppUrl(return_url,  'https://appiehour.com/?stripe=return'),
        refresh_url: safeAppUrl(refresh_url, 'https://appiehour.com/?stripe=refresh'),
        type: 'account_onboarding',
      });

      return res.json({ url: link.url });
    }

    // ── Check account status (has the merchant completed onboarding?) ───────
    if (action === 'account_status') {
      const { account_id } = req.body || req.query;
      if (!account_id) return res.status(400).json({ error: 'account_id required' });
      if (!caller.isAdmin && !(await callerOwnsAccount(caller.user.id, account_id))) {
        { audit(req, { type: 'permission_denied', severity: 'warn', actor: caller.user && caller.user.id, meta: { route: 'stripe', action: action, reason: 'not_account_owner' } }); return res.status(403).json({ error: 'Not your account' }); }
      }

      const account = await stripe.accounts.retrieve(account_id);
      return res.json({
        id: account.id,
        charges_enabled: account.charges_enabled,
        payouts_enabled: account.payouts_enabled,
        details_submitted: account.details_submitted,
        requirements: account.requirements,
      });
    }

    // ── Create a manual payout to a merchant's connected account ────────────
    if (action === 'create_payout') {
      const { account_id, amount_cents, currency = 'eur', description } = req.body || {};
      if (!account_id || !amount_cents)
        return res.status(400).json({ error: 'account_id and amount_cents required' });

      // Transfer from platform to connected account
      const transfer = await stripe.transfers.create({
        amount: Math.round(amount_cents),
        currency,
        destination: account_id,
        description: description || 'HappyHourly payout',
      });

      audit(req, { type: 'stripe_payout', severity: 'warn', actor: caller.user && caller.user.id, meta: { route: 'stripe', account_id: account_id, amount_cents: transfer.amount, currency: currency } });
      return res.json({ transfer_id: transfer.id, amount: transfer.amount, status: 'created' });
    }

    // ── List all connected accounts (admin overview) ─────────────────────────
    if (action === 'list_accounts') {
      const accounts = await stripe.accounts.list({ limit: 100 });
      return res.json({
        accounts: accounts.data.map(function(a) {
          return {
            id: a.id,
            email: a.email,
            payouts_enabled: a.payouts_enabled,
            details_submitted: a.details_submitted,
            created: a.created,
          };
        })
      });
    }

    // ── Create a Payment Intent for a voucher purchase ──────────────────────
    if (action === 'create_payment_intent') {
      const { amount_cents, currency = 'eur', deal_name, venue_name, user_email } = req.body || {};
      if (!amount_cents || amount_cents < 50)
        return res.status(400).json({ error: 'amount_cents must be at least 50' });

      const paymentIntent = await stripe.paymentIntents.create({
        amount: Math.round(amount_cents),
        currency,
        automatic_payment_methods: { enabled: true },
        description: deal_name ? (deal_name + ' @ ' + (venue_name || '')) : 'HappyHourly Voucher',
        receipt_email: user_email || undefined,
        metadata: { deal_name: deal_name || '', venue_name: venue_name || '' },
      });

      return res.json({ client_secret: paymentIntent.client_secret, payment_intent_id: paymentIntent.id });
    }

    // ── Refund a voucher purchase (merchant refuses a prepaid/card order) ────
    if (action === 'refund_purchase') {
      const { purchase_id } = req.body || {};
      if (!purchase_id) return res.status(400).json({ error: 'purchase_id required' });
      const sb = createClient(SB_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

      const { data: pur, error: pErr } = await sb.from('voucher_purchases')
        .select('id, deal_id, status, payment_method, stripe_payment_intent_id, refunded_at')
        .eq('id', purchase_id).single();
      if (pErr || !pur) return res.status(404).json({ error: 'Purchase not found' });

      // AuthZ: the caller must own the venue for this deal (or be an admin).
      let owns = caller.isAdmin;
      if (!owns) {
        const { data: deal } = await sb.from('deals').select('venue_id').eq('id', pur.deal_id).single();
        if (deal && deal.venue_id) {
          const { data: ven } = await sb.from('venues').select('owner_id').eq('id', deal.venue_id).single();
          owns = !!(ven && ven.owner_id === caller.user.id);
        }
      }
      if (!owns) { audit(req, { type: 'permission_denied', severity: 'warn', actor: caller.user && caller.user.id, meta: { route: 'stripe', action: action, reason: 'not_purchase_owner' } }); return res.status(403).json({ error: 'Not your purchase' }); }

      // Pay-at-venue or never-paid orders have nothing to refund.
      if (pur.payment_method === 'onsite' || !pur.stripe_payment_intent_id) {
        return res.json({ refunded: false, reason: 'no_online_payment' });
      }
      if (pur.refunded_at) return res.json({ refunded: false, reason: 'already_refunded' });

      const refund = await stripe.refunds.create({ payment_intent: pur.stripe_payment_intent_id });
      try { await sb.from('voucher_purchases').update({ refunded_at: new Date().toISOString() }).eq('id', purchase_id); } catch (e) {}
      audit(req, { type: 'stripe_refund', severity: 'warn', actor: caller.user && caller.user.id, meta: { route: 'stripe', purchase_id: purchase_id, refund_id: refund.id, amount: refund.amount } });
      return res.json({ refunded: true, refund_id: refund.id, amount: refund.amount });
    }

    return res.status(400).json({ error: 'Unknown action: ' + action });

  } catch (err) {
    console.error('[stripe api]', err.message);
    return res.status(500).json({ error: err.message });
  }
}
