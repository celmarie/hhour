// ============================================================================
// SSRF-resistant fetch — use this for ANY future feature that requests a
// user-supplied URL (image import, link unfurl/preview, webhook delivery).
// Not wired to anything yet; import it the moment you add such a feature:
//
//   const { safeFetch } = require('./_safefetch');
//   const r = await safeFetch(userUrl, { allowHosts: ['images.example.com'], maxBytes: 2_000_000 });
//   const html = r.text();
//
// Protections:
//   • https only (http is opt-in via allowHttp)
//   • optional exact host allowlist
//   • DNS resolved and EVERY resolved address checked; rejects loopback,
//     private, link-local, CGNAT, and cloud-metadata ranges (IPv4 + IPv6,
//     including IPv4-mapped IPv6). Decimal/octal/DNS-name tricks are caught
//     because we validate the *resolved IP*, not the string.
//   • the socket is PINNED to the validated IP via a custom lookup, so a second
//     resolution can't swap in an internal IP (DNS-rebinding / TOCTOU).
//   • redirects are followed manually and EACH hop is re-validated; capped.
//   • response body is size-capped and the request is timed out.
// ============================================================================
const https = require('https');
const http  = require('http');
const dns   = require('dns').promises;
const net   = require('net');

// True if an IP literal is in a range we must never let the server reach.
function ipIsBlocked(ip) {
  const m = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/i.exec(ip); // v4-mapped v6
  if (m) ip = m[1];
  if (net.isIPv4(ip)) {
    const o = ip.split('.').map(Number);
    if (o.some(n => n < 0 || n > 255)) return true;
    if (o[0] === 0)   return true;                                   // 0.0.0.0/8
    if (o[0] === 10)  return true;                                   // 10/8 private
    if (o[0] === 127) return true;                                   // loopback
    if (o[0] === 169 && o[1] === 254) return true;                   // link-local + cloud metadata (169.254.169.254)
    if (o[0] === 172 && o[1] >= 16 && o[1] <= 31) return true;       // 172.16/12 private
    if (o[0] === 192 && o[1] === 168) return true;                   // 192.168/16 private
    if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) return true;      // 100.64/10 CGNAT
    if (o[0] === 192 && o[1] === 0 && o[2] === 0) return true;       // 192.0.0/24
    if (o[0] >= 224) return true;                                    // multicast/reserved 224-255
    return false;
  }
  if (net.isIPv6(ip)) {
    const x = ip.toLowerCase().replace(/^\[|\]$/g, '');
    if (x === '::1' || x === '::') return true;                      // loopback / unspecified
    if (/^f[cd]/.test(x)) return true;                              // fc00::/7 unique-local
    if (/^fe[89ab]/.test(x)) return true;                          // fe80::/10 link-local
    return false;
  }
  return true; // unknown format → block
}

// Resolve a hostname and ensure NONE of its addresses are blocked; return one
// validated address to pin the connection to.
async function resolveAndValidate(hostname) {
  if (net.isIP(hostname)) {
    if (ipIsBlocked(hostname)) throw new Error('SSRF blocked: literal IP ' + hostname);
    return hostname;
  }
  let records;
  try { records = await dns.lookup(hostname, { all: true }); }
  catch (e) { throw new Error('SSRF blocked: DNS lookup failed for ' + hostname); }
  if (!records || !records.length) throw new Error('SSRF blocked: no DNS records for ' + hostname);
  for (const r of records) {
    if (ipIsBlocked(r.address)) throw new Error('SSRF blocked: ' + hostname + ' resolves to ' + r.address);
  }
  return records[0].address;
}

async function safeFetch(rawUrl, opts = {}) {
  const {
    allowHosts   = null,            // array of exact hostnames; null = any *public* host
    allowHttp    = false,
    maxRedirects = 3,
    maxBytes     = 5 * 1024 * 1024,
    timeoutMs    = 8000,
    method       = 'GET',
    headers      = {},
  } = opts;

  let url;
  try { url = new URL(rawUrl); } catch (e) { throw new Error('SSRF blocked: invalid URL'); }
  if (url.protocol !== 'https:' && !(allowHttp && url.protocol === 'http:')) {
    throw new Error('SSRF blocked: scheme ' + url.protocol);
  }
  const host = url.hostname.toLowerCase();
  if (allowHosts && !allowHosts.map(h => h.toLowerCase()).includes(host)) {
    throw new Error('SSRF blocked: host not allowlisted: ' + host);
  }
  const pinnedIp = await resolveAndValidate(host);

  const lib = url.protocol === 'https:' ? https : http;
  // Force the socket to the address we just validated (defeats DNS rebinding).
  const lookup = (h, o, cb) => cb(null, pinnedIp, net.isIPv6(pinnedIp) ? 6 : 4);

  const result = await new Promise((resolve, reject) => {
    const req = lib.request(url, {
      method, lookup, timeout: timeoutMs,
      servername: net.isIP(host) ? undefined : host,         // SNI for TLS
      headers: { Accept: '*/*', ...headers },
    }, (res) => {
      const chunks = []; let len = 0;
      res.on('data', (c) => {
        len += c.length;
        if (len > maxBytes) { req.destroy(new Error('SSRF blocked: response exceeds ' + maxBytes + ' bytes')); return; }
        chunks.push(c);
      });
      res.on('end', () => resolve({ status: res.statusCode, location: res.headers.location, body: Buffer.concat(chunks) }));
    });
    req.on('timeout', () => req.destroy(new Error('SSRF blocked: request timeout')));
    req.on('error', reject);
    req.end();
  });

  // Follow redirects ourselves so each hop is re-validated (scheme + allowlist + IP).
  if (result.status >= 300 && result.status < 400 && result.location) {
    if (maxRedirects <= 0) throw new Error('SSRF blocked: too many redirects');
    const next = new URL(result.location, url).toString();
    return safeFetch(next, { ...opts, maxRedirects: maxRedirects - 1 });
  }

  return { status: result.status, body: result.body, text: () => result.body.toString('utf8') };
}

module.exports = { safeFetch, ipIsBlocked };
