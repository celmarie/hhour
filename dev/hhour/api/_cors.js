// Shared CORS policy. Files prefixed with "_" are NOT treated as routes by Vercel,
// only imported. Access-Control-Allow-Origin is locked to an explicit allowlist
// (never the wildcard "*", never a blindly-reflected Origin).
//
// Credentials: this API authenticates with a Bearer token in the Authorization
// header, NOT cookies — so Access-Control-Allow-Credentials is intentionally
// NEVER set. The dangerous "wildcard + credentials" combination cannot occur,
// and no ambient credentials are exposed cross-origin.
const ALLOWED = [
  'https://www.appiehour.com',
  'https://appiehour.com'
];
const CANONICAL = 'https://www.appiehour.com';

// Preview deployments are allowed ONLY under our own Vercel account scope
// ("…-fcc-s-projects.vercel.app"). The previous /[a-z0-9-]+\.vercel\.app/ trusted
// ANY vercel.app site (an attacker could deploy evil-xyz.vercel.app and be a
// trusted origin); pinning the account scope closes that — nobody else can
// deploy under our scope slug.
const PREVIEW_RE = /^https:\/\/[a-z0-9-]+-fcc-s-projects\.vercel\.app$/i;

function isAllowedOrigin(origin) {
  return ALLOWED.includes(origin) || PREVIEW_RE.test(origin);
}

function applyCors(req, res) {
  const origin = (req.headers && req.headers.origin) || '';
  // Reflect the Origin ONLY after validating it against the allowlist; otherwise
  // fall back to the canonical origin (a disallowed origin then gets an ACAO that
  // doesn't match it, so the browser blocks the cross-origin read).
  const allow = isAllowedOrigin(origin) ? origin : CANONICAL;
  res.setHeader('Access-Control-Allow-Origin', allow);
  res.setHeader('Vary', 'Origin');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Max-Age', '86400');
}

module.exports = { applyCors };
