# Security hardening — close the remaining gaps

The code-side defenses are done (RLS, server-side authz on every `/api` route,
per-route rate limiting, CORS lockdown, 3-pass XSS escaping, image-upload
validation, audit log + Security page, edge-cached feed). The remaining gaps are
**platform settings** that can only be flipped in your Supabase / Vercel / Cloudflare
dashboards. Each step below is turnkey — ~15 minutes total.

Priority order: **1 → 2 → 3 → 4** (1 and 4 give the most protection per minute).

---

## 1. CAPTCHA on signup/login/reset  (stops bot account creation & brute force) 🔴
The client is **already wired** — it just needs a key + the Supabase toggle.

1. **Cloudflare Turnstile** → https://dash.cloudflare.com → Turnstile → *Add site*
   (domain `appiehour.com`). Copy the **Site key** and **Secret key**.
2. In `happyhourly-complete.html`, set the site key:
   `var _CAPTCHA_SITE_KEY = '0x4AAA...';`  (search for `_CAPTCHA_SITE_KEY`)
   then redeploy with `./deploy.sh`.
3. **Supabase → Authentication → Settings → Bot & Abuse Protection / CAPTCHA**:
   enable it, provider **Turnstile**, paste the **Secret key**, Save.
4. **Verify:** open the login screen → the Turnstile widget appears → sign in works.
   Try signup from a script with no token → rejected.

> ⚠️ Order matters: do step 2 (client key) **before/with** step 3 (Supabase), or
> logins will fail (Supabase would require a token the client isn't sending yet).
> Until both are done, everything stays exactly as it is now (inert).

## 2. Strong + non-breached passwords 🟠
**Supabase → Authentication → Settings → Password:**
- **Minimum length → 12** (matches the client check).
- Enable **Leaked password protection** (checks HaveIBeenPwned, rejects breached).
- **Verify:** try signing up with `Password123!` → rejected server-side.

## 3. Required email verification 🟠
**Supabase → Authentication → Providers → Email:** enable **Confirm email**.
(The client already guards sensitive writes behind `email_confirmed_at` via
`requireVerifiedEmail()`.) **Verify:** new email/password user can't act until they
click the link.

## 4. Auth rate limits + edge firewall  (stops floods / brute force / scrapers) 🔴
- **Supabase → Authentication → Rate Limits:** lower sign-in / sign-up / token /
  recovery to sane values (e.g. ~10–30/hr/IP for sign-in, tighter for recovery).
- **Vercel → your project → Firewall:** turn on **Attack Challenge Mode** (or add
  rules) to challenge bot/flood traffic at the edge before it reaches the app.

## 5. (Optional) Durable, multi-instance API rate limiting 🟢
Today `api/_ratelimit.js` is in-memory (per warm instance, resets on cold start) —
fine for the low-volume admin/stripe routes, but not a hard guarantee. For durable
limits, back it with **Upstash Redis** (`UPSTASH_REDIS_REST_URL` / `_TOKEN` env vars)
and swap the limiter to `@upstash/ratelimit`. Ask me to wire this if you want it.

---

## What this does NOT (and can't) stop
- **Scraping of genuinely public data** (the approved deal feed). The browser uses
  the public anon key, so the feed is public by design — RLS guarantees scrapers
  get **nothing private**, and the edge cache absorbs the load. The Vercel firewall
  (step 4) is the lever to throttle abusive scrapers.
- Reminder: **rotate the Supabase service-role key** (Settings → API) — it appeared
  in chat earlier.
