/* Appie Hour service worker — offline app shell + asset cache.
   Lets the app load with no internet. Deal DATA is served from the localStorage
   cache the app already maintains (last-loaded deals), so users can browse what
   they last saw while offline. Private/dynamic data (Supabase REST/auth, our API)
   is NEVER cached — only the shell, libraries, fonts and public deal photos. */
// v6: purges every pre-2026-07-16 cached shell. Those hold the boot bug where a
// failed supabase-js load froze the app on "Loading…" forever — and because the
// cached shell is what answers an OFFLINE launch, devices carrying it would keep
// replaying that freeze even after the fix shipped. Bumping the name forces the
// old cache to be deleted on activate.
var CACHE = 'hh-offline-v6';
var SHELL = ['/', '/happyhourly-complete.html', '/version.json'];

// Merchant + admin portals must NEVER be answered from this cache — always network.
// (They're client-side routes of the same single-file app, but a stale cached shell
// there can boot an outdated build whose portal routing misbehaves.)
function isPortalPath(pathname){
  return pathname === '/merchant' || pathname.indexOf('/merchant/') === 0 ||
         pathname === '/fireclay' || pathname.indexOf('/fireclay/') === 0;
}

self.addEventListener('install', function(e){
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(function(c){
    return Promise.all(SHELL.map(function(u){ return c.add(u).catch(function(){}); }));
  }));
});

self.addEventListener('activate', function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(keys.map(function(k){ return k === CACHE ? null : caches.delete(k); }));
    }).then(function(){ return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function(e){
  var req = e.request;
  if(req.method !== 'GET') return;               // never touch writes
  var url;
  try { url = new URL(req.url); } catch(_){ return; }

  // Portal denylist: /merchant + /fireclay (and subroutes) go straight to the
  // network — no respondWith, no cache read, no cache write. Ever.
  if(url.origin === self.location.origin && isPortalPath(url.pathname)) return;

  // Supabase REST / auth / realtime → always network (never cache private/dynamic data)
  if(url.hostname.indexOf('supabase.co') !== -1 &&
     (url.pathname.indexOf('/rest/') === 0 || url.pathname.indexOf('/auth/') === 0 || url.pathname.indexOf('/realtime') === 0)){
    return;
  }
  // Our own serverless API → always network
  if(url.origin === self.location.origin && url.pathname.indexOf('/api/') === 0) return;

  // version.json → network-first (keeps the auto-update guard accurate), cache fallback offline
  if(url.pathname.indexOf('version.json') !== -1){
    e.respondWith(fetch(req).then(function(res){
      var cp = res.clone(); caches.open(CACHE).then(function(c){ c.put(req, cp); }); return res;
    }).catch(function(){ return caches.match(req); }));
    return;
  }

  // App navigation (customer SPA paths only — portals returned above). ALWAYS
  // answer with a freshly-REBUILT 200 of the app shell. Passing the navigation
  // request itself to fetch() can yield a redirected or opaque-redirect response
  // (non-www→www 308 etc.); WebKit fails a navigation answered that way, retries,
  // fails again — and bricks the tab with "A problem repeatedly occurred". Fetching
  // the shell FILE directly and rebuilding the body makes that class of failure
  // impossible. Cache the clean copy; fall back to it offline.
  if(req.mode === 'navigate' ||
     (url.origin === self.location.origin && (url.pathname === '/' || url.pathname.indexOf('happyhourly-complete.html') !== -1))){
    e.respondWith(
      fetch('/happyhourly-complete.html', { redirect: 'follow', credentials: 'same-origin' })
        .then(function(res){
          if(!res || !res.ok) throw new Error('shell ' + (res && res.status));
          return res.blob().then(function(b){
            var clean = new Response(b, { status: 200, statusText: 'OK',
              headers: { 'Content-Type': 'text/html; charset=utf-8' } });
            try { var cp = clean.clone(); caches.open(CACHE).then(function(c){ c.put('/happyhourly-complete.html', cp); }); } catch(_){}
            return clean;
          });
        })
        .catch(function(){
          return caches.match('/happyhourly-complete.html').then(function(m){
            if(m) return m;
            return caches.match('/').then(function(m2){
              return m2 || new Response(
                '<meta http-equiv="refresh" content="1;url=/"><body style="font-family:sans-serif;padding:40px;text-align:center;color:#555;">Reconnecting…</body>',
                { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
            });
          });
        })
    );
    return;
  }

  // Libraries + fonts + public deal photos → cache-first w/ background refresh
  // NB: unpkg is the supabase-js fallback CDN. It must be cached on the same terms
  // as jsdelivr — otherwise a boot that fell back to unpkg would leave the library
  // uncached and the NEXT offline launch would have nothing to load it from.
  if(url.hostname.indexOf('jsdelivr.net') !== -1 ||
     url.hostname.indexOf('unpkg.com') !== -1 ||
     url.hostname.indexOf('fonts.googleapis.com') !== -1 ||
     url.hostname.indexOf('fonts.gstatic.com') !== -1 ||
     (url.hostname.indexOf('supabase.co') !== -1 && url.pathname.indexOf('/storage/') !== -1)){
    e.respondWith(
      caches.match(req).then(function(cached){
        var net = fetch(req).then(function(res){
          if(res && (res.ok || res.type === 'opaque')){ var cp = res.clone(); caches.open(CACHE).then(function(c){ c.put(req, cp); }); }
          return res;
        }).catch(function(){ return cached; });
        return cached || net;
      })
    );
    return;
  }

  // Everything else (e.g. maps) → network, fall back to cache if we have it
  e.respondWith(fetch(req).catch(function(){ return caches.match(req); }));
});

/* ── Web Push (OS-level notifications) ──────────────────────────────────────
   Fired when api/send-push.js delivers a payload via VAPID/web-push. Shows a
   system notification even when the app is closed (iOS 16.4+ Home-Screen PWAs,
   Android, desktop). notificationclick focuses/opens the app at data.url. */
var HH_ICON = 'https://hjzyqhfuvcswfcvkjsyv.supabase.co/storage/v1/object/public/photos/appie-icon.png?v=4';

self.addEventListener('push', function(e){
  var data = {};
  try { data = e.data ? e.data.json() : {}; }
  catch(_){ try { data = { title: 'Appie Hour', body: e.data && e.data.text() }; } catch(__){ data = {}; } }
  var title = data.title || 'Appie Hour';
  var opts = {
    body: data.body || '',
    icon: data.icon || HH_ICON,
    badge: data.badge || HH_ICON,
    tag: data.tag || undefined,               // same tag collapses duplicates
    renotify: !!data.tag,
    data: { url: data.url || '/' }
  };
  e.waitUntil(self.registration.showNotification(title, opts));
});

self.addEventListener('notificationclick', function(e){
  e.notification.close();
  var target = (e.notification.data && e.notification.data.url) || '/';
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(list){
      for(var i=0;i<list.length;i++){
        var c = list[i];
        if(c.url.indexOf(self.location.origin) === 0 && 'focus' in c){
          if('navigate' in c){ try { c.navigate(target); } catch(err){ console.warn('[sw notificationclick] navigate failed', err); } }
          return c.focus();
        }
      }
      if(self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});
