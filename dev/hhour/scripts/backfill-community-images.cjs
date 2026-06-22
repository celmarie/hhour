#!/usr/bin/env node
/*
 * Backfill: move base64 images in community_deals.image_url → Supabase Storage,
 * replacing the inline base64 with public Storage URLs. Shrinks the feed payload
 * ~100× (≈5 MB → ≈50 KB) so it loads fast and the /api/feed cache is cheap.
 *
 * SAFE BY DESIGN:
 *   • DRY-RUN by default — prints what it WOULD do and writes nothing.
 *     Pass --apply to actually upload + update rows.
 *   • Before modifying a row it appends the ORIGINAL image_url to a local backup
 *     file (scripts/backfill-backup-<timestamp>.jsonl). Nothing is ever deleted.
 *   • Idempotent: rows already migrated (no base64 left) are skipped, so it's safe
 *     to re-run.
 *   • --restore <backupfile> writes every row's image_url back to its original.
 *
 * Requires Node 18+ (global fetch). No npm install needed.
 *
 * Usage:
 *   SUPABASE_SERVICE_ROLE_KEY=eyJ... node scripts/backfill-community-images.cjs            # dry run
 *   SUPABASE_SERVICE_ROLE_KEY=eyJ... node scripts/backfill-community-images.cjs --apply    # do it
 *   SUPABASE_SERVICE_ROLE_KEY=eyJ... node scripts/backfill-community-images.cjs --restore scripts/backfill-backup-XXXX.jsonl
 *
 * (SUPABASE_URL defaults to the project URL; override via env if needed.)
 */
const fs = require('fs');
const path = require('path');

const URL = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const BUCKET = 'photos';
const APPLY = process.argv.includes('--apply');
const RESTORE_IDX = process.argv.indexOf('--restore');
const RESTORE_FILE = RESTORE_IDX !== -1 ? process.argv[RESTORE_IDX + 1] : null;

const H = { Authorization: `Bearer ${KEY}`, apikey: KEY };
const ALLOWED = { 'image/jpeg': 'jpg', 'image/jpg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif' };

function die(msg) { console.error('✗ ' + msg); process.exit(1); }
if (!KEY) die('Set SUPABASE_SERVICE_ROLE_KEY (Supabase → Settings → API → service_role).');

// image_url may be a single string or a JSON array of strings.
function splitImages(val) {
  if (typeof val !== 'string' || !val) return { isArray: false, items: [] };
  const t = val.trim();
  if (t.startsWith('[')) { try { const a = JSON.parse(t); if (Array.isArray(a)) return { isArray: true, items: a }; } catch (e) {} }
  return { isArray: false, items: [val] };
}
function parseDataUrl(s) {
  const m = /^data:([^;]+);base64,(.*)$/s.exec(s);
  if (!m) return null;
  const mime = m[1].toLowerCase();
  const ext = ALLOWED[mime];
  if (!ext) return null; // unsupported type → leave original untouched
  return { mime: mime === 'image/jpg' ? 'image/jpeg' : mime, ext, buffer: Buffer.from(m[2], 'base64') };
}

async function fetchAllRows() {
  const r = await fetch(`${URL}/rest/v1/community_deals?select=id,image_url&limit=100000`, { headers: H });
  if (!r.ok) die(`fetch rows failed: ${r.status} ${await r.text()}`);
  return r.json();
}
async function uploadToStorage(p, buffer, mime) {
  const r = await fetch(`${URL}/storage/v1/object/${BUCKET}/${p}`, {
    method: 'POST',
    headers: { ...H, 'Content-Type': mime, 'x-upsert': 'false' },
    body: buffer,
  });
  if (!r.ok) throw new Error(`upload ${p} → ${r.status} ${await r.text()}`);
  return `${URL}/storage/v1/object/public/${BUCKET}/${p}`;
}
async function updateImageUrl(id, value) {
  const r = await fetch(`${URL}/rest/v1/community_deals?id=eq.${id}`, {
    method: 'PATCH',
    headers: { ...H, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify({ image_url: value }),
  });
  if (!r.ok) throw new Error(`update ${id} → ${r.status} ${await r.text()}`);
}

async function restore() {
  if (!fs.existsSync(RESTORE_FILE)) die(`backup file not found: ${RESTORE_FILE}`);
  const lines = fs.readFileSync(RESTORE_FILE, 'utf8').split('\n').filter(Boolean);
  const seen = new Set();
  let n = 0;
  for (const line of lines) {
    const { id, image_url } = JSON.parse(line);
    if (seen.has(id)) continue; // first occurrence = true original
    seen.add(id);
    await updateImageUrl(id, image_url);
    n++;
    process.stdout.write(`  restored ${id}\r`);
  }
  console.log(`\n✓ Restored ${n} row(s) from ${RESTORE_FILE}`);
}

async function main() {
  if (RESTORE_FILE) return restore();

  console.log(APPLY ? '── APPLY mode: will upload + update rows ──' : '── DRY RUN (no writes). Pass --apply to perform. ──');
  const rows = await fetchAllRows();
  const toMigrate = rows.filter((r) => splitImages(r.image_url).items.some((it) => typeof it === 'string' && it.startsWith('data:')));
  console.log(`community_deals rows: ${rows.length} | with base64 to migrate: ${toMigrate.length}`);

  const backupFile = path.join(__dirname, `backfill-backup-${Date.now()}.jsonl`);
  let migrated = 0, uploaded = 0, unsupported = 0, bytesBefore = 0, bytesAfter = 0;

  for (const row of toMigrate) {
    const { isArray, items } = splitImages(row.image_url);
    bytesBefore += (row.image_url || '').length;
    if (APPLY) fs.appendFileSync(backupFile, JSON.stringify({ id: row.id, image_url: row.image_url }) + '\n');

    const out = [];
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (typeof it === 'string' && it.startsWith('data:')) {
        const d = parseDataUrl(it);
        if (!d) { out.push(it); unsupported++; continue; }   // keep unsupported as-is
        const p = `community/backfill/${row.id}-${i}-${Math.random().toString(36).slice(2, 8)}.${d.ext}`;
        if (APPLY) { out.push(await uploadToStorage(p, d.buffer, d.mime)); }
        else { out.push(`${URL}/storage/v1/object/public/${BUCKET}/${p}`); }
        uploaded++;
      } else { out.push(it); }   // already a URL → keep
    }
    const newVal = isArray ? JSON.stringify(out) : out[0];
    bytesAfter += (newVal || '').length;
    if (APPLY) await updateImageUrl(row.id, newVal);
    migrated++;
    process.stdout.write(`  ${APPLY ? 'migrated' : 'would migrate'} ${migrated}/${toMigrate.length} (row ${row.id})   \r`);
  }

  console.log('\n──────────────────────────────────────');
  console.log(`rows ${APPLY ? 'migrated' : 'to migrate'} : ${migrated}`);
  console.log(`images uploaded     : ${uploaded}${unsupported ? `  (skipped ${unsupported} unsupported type)` : ''}`);
  console.log(`image_url size      : ${(bytesBefore / 1024 / 1024).toFixed(2)} MB → ${(bytesAfter / 1024).toFixed(1)} KB`);
  if (APPLY) console.log(`backup written      : ${backupFile}\n  (restore with: node scripts/backfill-community-images.cjs --restore ${backupFile})`);
  else console.log('\nDry run only — re-run with --apply to perform.');
}

main().catch((e) => die(e.message || String(e)));
