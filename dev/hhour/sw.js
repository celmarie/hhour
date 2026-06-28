/* Appie Hour service worker — offline app shell + asset cache.
   Lets the app load with no internet. Deal DATA is served from the localStorage
   cache the app already maintains (last-loaded deals), so users can browse what
   they last saw while offline. Private/dynamic data (Supabase REST/auth, our API)
   is NEVER cached — only the shell, libraries, fonts and public deal photos. */
var CACHE = 'hh-offline-v2';
var SHELL = ['/', '/happyhourly-complete.html', '/version.json'];

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

  // App navigation (any SPA path: /, /merchant, /fireclay …) → network-first,
  // fall back to the cached shell when offline.
  if(req.mode === 'navigate' ||
     (url.origin === self.location.origin && (url.pathname === '/' || url.pathname.indexOf('happyhourly-complete.html') !== -1))){
    e.respondWith(
      fetch(req).then(function(res){
        // iOS/WebKit throws a network error if a service worker returns a REDIRECTED
        // response to a navigation (our domain 308-redirects non-www→www). Repeated
        // navigation errors show "A problem repeatedly occurred". Rebuild a clean,
        // non-redirected response and cache THAT (never cache a redirect/non-OK).
        if(res && res.redirected){
          return res.blob().then(function(b){
            var clean = new Response(b, { status: res.status, statusText: res.statusText, headers: res.headers });
            if(res.ok){ var cc = clean.clone(); caches.open(CACHE).then(function(c){ c.put('/happyhourly-complete.html', cc); }); }
            return clean;
          });
        }
        if(res && res.ok){ var cp = res.clone(); caches.open(CACHE).then(function(c){ c.put('/happyhourly-complete.html', cp); }); }
        return res;
      }).catch(function(){
        return caches.match('/happyhourly-complete.html').then(function(m){ return m || caches.match('/'); });
      })
    );
    return;
  }

  // Libraries + fonts + public deal photos → cache-first w/ background refresh
  if(url.hostname.indexOf('jsdelivr.net') !== -1 ||
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
