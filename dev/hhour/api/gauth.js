// Google Identity Services "redirect" landing point — runs on appiehour.com so the
// Google account chooser shows "Appie Hour" (your domain) instead of the supabase.co
// auth host. GIS POSTs the signed ID token (credential) + a CSRF token here; we verify
// the CSRF (double-submit cookie) and bounce back to the app with the token in the URL
// fragment, where the client finishes sign-in via supabase.auth.signInWithIdToken.
//
// No secrets needed (GIS already returns a verified ID token). No Vercel env required.
module.exports = async function handler(req, res) {
  if (req.method !== 'POST') { res.statusCode = 405; res.setHeader('Allow', 'POST'); return res.end('Method not allowed'); }

  let body = req.body;
  if (typeof body === 'string') { try { body = Object.fromEntries(new URLSearchParams(body)); } catch (e) { body = {}; } }
  if (!body || typeof body !== 'object') body = {};

  const credential = body.credential;
  const csrfBody = body.g_csrf_token;
  const cookie = req.headers.cookie || '';
  const m = cookie.match(/(?:^|;\s*)g_csrf_token=([^;]+)/);
  const csrfCookie = m ? decodeURIComponent(m[1]) : '';

  const host = (req.headers.host || 'www.appiehour.com').replace(/[^a-z0-9.\-:]/gi, '');
  const base = 'https://' + host;

  // Double-submit-cookie CSRF check (per Google's GIS redirect-mode guidance).
  if (!credential || !csrfBody || !csrfCookie || csrfBody !== csrfCookie) {
    res.statusCode = 303;
    res.setHeader('Location', base + '/?gauth_error=1');
    return res.end();
  }

  // Hand the ID token to the SPA via the fragment (fragments aren't sent to servers/logs);
  // the client reads #_gid, calls signInWithIdToken, then strips it from the URL.
  res.statusCode = 303;
  res.setHeader('Location', base + '/#_gid=' + encodeURIComponent(credential));
  res.end();
};
