# Auth hardening — audit + dashboard checklist

This app is a **static single-file PWA** using the Supabase JS client in the browser
(anon key) plus stateless Vercel functions in `api/`. There is **no SSR server**, so
some "best-practice" items map to Supabase **dashboard settings** rather than code.

---

## #2 — Server-side authorization audit (CODE — ✅ complete)

Every API route re-verifies the caller from the Bearer token server-side (never trusts
the browser). RLS + the privileged-column guard trigger + admin-only RPCs back this at
the database layer.

| Route | Server-side check | Status |
|-------|-------------------|--------|
| `api/stripe.js` | `getCaller` (token→uid→role); `create_payout`/`list_accounts` require admin; `onboarding_link`/`account_status` require account ownership; rate-limited | ✅ |
| `api/admin-create-user.js` | Bearer token → admin role required; rate-limited | ✅ |
| `api/admin-delete-user.js` | Bearer token → admin role required; rate-limited *(rate limit added this session)* | ✅ |
| `api/admin-reset-password.js` | Bearer token → admin role required; rate-limited | ✅ |
| `api/delete-my-account.js` | Verifies caller; only deletes the caller's OWN account; rate-limited | ✅ |
| `api/notify.js` | Bearer token → admin role required (service-role insert only after admin proven) | ✅ |
| `api/send-email.js` | Verifies caller; non-admins may email only their OWN address; rate-limited | ✅ |
| `api/purge-deleted.js` | Vercel `CRON_SECRET` **or** super_admin token | ✅ |

**Result: 0 unprotected routes.** Matching RLS policies and the guard trigger were added
in the earlier hardening pass (`apply_security_fix.sql`, `lock_profile_privileged_columns.sql`,
`lock_event_rsvps.sql`, `trim_*` files).

---

## #3 — Require email verification

**Code (✅ done):** `requireVerifiedEmail(action)` blocks unverified email/password accounts
from sensitive writes (OAuth/Google accounts are pre-verified). Wired into: buy voucher,
submit deal, submit review, post event, share watch-spot. Offers to resend the link.

**You flip (Supabase dashboard):**
1. **Authentication → Providers → Email →** enable **"Confirm email"**.
2. (Optional) **Authentication → URL Configuration →** set the redirect/confirmation URL to
   `https://www.appiehour.com`.

With "Confirm email" ON, new email/password users get **no session until they click the
link**, so they can't even reach the guarded actions — the client guard is belt-and-suspenders.

---

## #4 — Rate-limit login / signup / reset

These flows go **straight to Supabase Auth (GoTrue)**, not through `api/`, so our in-memory
limiter doesn't apply and there's no middleware layer to add Upstash to. Use Supabase's
**built-in auth rate limits**:

**You flip (Supabase dashboard):** **Authentication → Rate Limits**
- **Sign in / Sign up:** lower to a sane value (e.g. ~10–30 / hour / IP).
- **Token verifications / OTP / password recovery:** keep tight (e.g. ~5–10 / hour).
- Email send rate: keep low to prevent email bombing.

Supabase enforces these server-side per IP; the 6th rapid attempt returns HTTP 429.
*(Hard, multi-instance limits on the `api/` routes would need Upstash/Vercel KV — separate task.)*

---

## #5 — Strong + non-breached passwords

**Code (✅ done):** `passwordStrengthError(pw)` enforces **min length 12 + ≥3 character classes**,
with a clear inline error. Wired into: customer sign-up, merchant sign-up, password change,
password reset, merchant settings password change.

**You flip (Supabase dashboard):** **Authentication → Providers → Email** (or **Policies**)
1. **Minimum password length →** set to **12** (matches the client).
2. Enable **"Leaked password protection"** (checks HaveIBeenPwned and rejects breached passwords).

**Verify:** try to sign up with a known-breached password like `Password123!` — Supabase
rejects it server-side; a weak/short one is rejected client-side before submit.

---

## #1 — Session in httpOnly cookies — NOT done (architecture)

`@supabase/ssr` requires a server that renders each request and owns the session cookie.
A static PWA using `supabase-js` in the browser **must** keep its session in localStorage.
Moving to httpOnly cookies = **rewriting the app onto an SSR framework (Next.js/SvelteKit)** —
a separate project, not a migration. Current mitigation: the **3-pass stored-XSS lockdown**
(the real threat to a localStorage token).
