// Rate limiter for serverless functions — durable when configured, best-effort
// otherwise.
//
// • If UPSTASH_REDIS_REST_URL + UPSTASH_REDIS_REST_TOKEN are set, counts live in
//   Upstash Redis: shared across ALL instances/regions and surviving cold starts
//   (a hard, global limit).
// • Otherwise it falls back to a per-instance in-memory counter (resets on cold
//   start, not shared) — a meaningful first layer with zero setup.
//
// rateLimit() is async; callers should `await` it. On any Upstash error it falls
// back to in-memory rather than blocking the request.
const buckets = new Map();

function memRateLimit(key, max, windowMs) {
  const now = Date.now();
  let b = buckets.get(key);
  if (!b || now > b.reset) { b = { count: 0, reset: now + windowMs }; buckets.set(key, b); }
  b.count++;
  if (buckets.size > 5000) { // opportunistic cleanup
    for (const [k, v] of buckets) { if (now > v.reset) buckets.delete(k); }
  }
  return {
    allowed: b.count <= max,
    retryAfter: Math.max(1, Math.ceil((b.reset - now) / 1000)),
    remaining: Math.max(0, max - b.count)
  };
}

async function upstashPipeline(url, token, commands) {
  const r = await fetch(url.replace(/\/+$/, '') + '/pipeline', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: JSON.stringify(commands)
  });
  if (!r.ok) throw new Error('upstash ' + r.status);
  return r.json(); // [{ result }, { result }, ...]
}

async function rateLimit(key, max, windowMs) {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (url && token) {
    try {
      const ttl = Math.max(1, Math.ceil(windowMs / 1000));
      const k = 'rl:' + key;
      // Fixed window: INCR the counter, set TTL only on first hit (NX), read TTL.
      const res = await upstashPipeline(url, token, [
        ['INCR', k],
        ['EXPIRE', k, ttl, 'NX'],
        ['TTL', k]
      ]);
      const count = (res && res[0] && typeof res[0].result === 'number') ? res[0].result : 1;
      const ttlLeft = (res && res[2] && typeof res[2].result === 'number' && res[2].result > 0) ? res[2].result : ttl;
      return { allowed: count <= max, retryAfter: ttlLeft, remaining: Math.max(0, max - count) };
    } catch (e) {
      // Never block a request because the rate-limit store hiccuped.
      return memRateLimit(key, max, windowMs);
    }
  }
  return memRateLimit(key, max, windowMs);
}

function clientIp(req) {
  const xff = ((req.headers && req.headers['x-forwarded-for']) || '').split(',')[0].trim();
  return xff || (req.socket && req.socket.remoteAddress) || 'unknown';
}

module.exports = { rateLimit, clientIp };
