/*
 * HappyHourly — 5pm happy-hour "feed spike" load test (k6)
 * ----------------------------------------------------------------------------
 * Simulates the rush when everyone opens the app at happy hour: ramp 0 → ~200
 * virtual users over 30s, hold for 1 minute, then ramp down. Each VU hits the
 * SAME public deal-feed read the browser makes against Supabase REST:
 * community_deals — active (status=approved), non-deleted, newest first.
 *
 * ⚠️  This hits your REAL Supabase project. Run it against a staging project, or
 *     during a quiet window, and mind your plan's rate/egress limits.
 *
 * Install k6:
 *   macOS:    brew install k6
 *   Linux:    sudo gpg -k && \
 *             sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
 *               --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69 && \
 *             echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
 *               | sudo tee /etc/apt/sources.list.d/k6.list && sudo apt update && sudo apt install k6
 *   Windows:  choco install k6   (or winget install k6 --source winget)
 *   Docker:   docker pull grafana/k6
 *   Docs:     https://grafana.com/docs/k6/latest/set-up/install-k6/
 *
 * Run:
 *   # 1) fill in SUPABASE_URL + SUPABASE_ANON_KEY below, then:
 *   k6 run loadtest/feed-spike.js
 *
 *   # …or pass them as env vars instead of editing the file:
 *   k6 run -e SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
 *          -e SUPABASE_ANON_KEY=eyJhbGci... \
 *          loadtest/feed-spike.js
 *
 *   # …or via Docker (env still passed with -e):
 *   docker run --rm -i -e SUPABASE_URL=... -e SUPABASE_ANON_KEY=... \
 *          grafana/k6 run - < loadtest/feed-spike.js
 * ----------------------------------------------------------------------------
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

// ── .env-style config — fill these in (or override with `k6 run -e KEY=val`) ──
const SUPABASE_URL      = __ENV.SUPABASE_URL      || 'https://YOUR-PROJECT.supabase.co';
const SUPABASE_ANON_KEY = __ENV.SUPABASE_ANON_KEY || 'YOUR_SUPABASE_ANON_KEY';
// ──────────────────────────────────────────────────────────────────────────────

const errorRate = new Rate('errors');

export const options = {
  // 0 → 200 VUs over 30s, hold 200 for 1 min, ramp back to 0 over 30s.
  stages: [
    { duration: '30s', target: 200 },
    { duration: '1m',  target: 200 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<800'], // 95th-percentile latency under 800ms
    http_req_failed:   ['rate<0.01'], // transport/HTTP errors under 1%
    errors:            ['rate<0.01'], // our own check failures under 1%
  },
};

// Same query the browser runs: select=* from community_deals,
// status=approved, deleted_at is null, ordered by created_at desc.
const FEED_URL =
  `${SUPABASE_URL}/rest/v1/community_deals` +
  `?select=*&status=eq.approved&deleted_at=is.null&order=created_at.desc`;

const params = {
  headers: {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    Accept: 'application/json',
  },
  tags: { name: 'community_deals_feed' }, // groups these requests in the summary
};

export default function () {
  const res = http.get(FEED_URL, params);

  const ok = check(res, {
    'status is 200':       (r) => r.status === 200,
    'body is a JSON array': (r) => {
      try { return Array.isArray(r.json()); } catch (e) { return false; }
    },
  });
  errorRate.add(!ok);

  // ~1s think-time between feed refreshes, so 200 VUs ≈ 200 req/s at peak.
  sleep(1);
}
