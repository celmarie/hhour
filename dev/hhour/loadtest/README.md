# Load tests

[k6](https://k6.io) load tests for HappyHourly.

## `feed-spike.js` — 5pm happy-hour feed rush

Simulates everyone opening the app at happy hour and hammering the public deal
feed. Ramps **0 → ~200 VUs over 30s**, holds **1 min**, then ramps down. Each
virtual user runs the same Supabase REST query the browser does for the feed:
`community_deals` — `status=approved`, `deleted_at is null`, newest first.

### Install k6

| Platform | Command |
|----------|---------|
| macOS | `brew install k6` |
| Windows | `choco install k6` (or `winget install k6 --source winget`) |
| Linux | see the [apt/yum guide](https://grafana.com/docs/k6/latest/set-up/install-k6/) |
| Docker | `docker pull grafana/k6` |

### Configure

Set your project URL + anon key either by editing the placeholders at the top of
`feed-spike.js`, or by passing them at run time with `-e`:

```bash
k6 run -e SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
       -e SUPABASE_ANON_KEY=eyJhbGci... \
       loadtest/feed-spike.js
```

> ⚠️ This hits your **real** Supabase project. Run against a staging project or
> in a quiet window, and watch your plan's rate/egress limits.

### Run

```bash
k6 run loadtest/feed-spike.js
# Docker:
docker run --rm -i -e SUPABASE_URL=... -e SUPABASE_ANON_KEY=... \
  grafana/k6 run - < loadtest/feed-spike.js
```

### Pass / fail thresholds

The run **fails** (non-zero exit) if any threshold is breached:

- `http_req_duration p(95) < 800ms` — 95% of feed reads under 800 ms
- `http_req_failed   rate < 1%` — transport/HTTP errors
- `errors            rate < 1%` — our own checks (HTTP 200 + JSON-array body)

### Reading the output

- **`http_req_duration`** — focus on `p(95)` (and `p(99)`); `avg` hides tail latency.
- **`http_reqs`** — total requests + req/s achieved at peak (~200/s here).
- **`vus` / `vus_max`** — concurrency reached.
- A green ✓ next to each threshold = passed; red ✗ = breached.

The feed query is served by the
`community_deals (status, created_at desc) WHERE deleted_at IS NULL` index
(see `supabase/migrations/…_lookup_indexes_and_postgis_geo.sql`), so this
exercises the optimized path.
