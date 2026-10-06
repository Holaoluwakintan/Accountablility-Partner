/* Accountability Partner service worker: app shell offline, network for data. */
var V = 'ap-__V__';
var SHELL = ['/', '/index.html', '/styles.css?v=__V__', '/app.js?v=__V__', '/vendor/supabase.js', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png'];
self.addEventListener('install', function (e) { e.waitUntil(caches.open(V).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); })); });
self.addEventListener('activate', function (e) { e.waitUntil(caches.keys().then(function (ks) { return Promise.all(ks.filter(function (k) { return k !== V; }).map(function (k) { return caches.delete(k); })); }).then(function () { return self.clients.claim(); })); });
self.addEventListener('fetch', function (e) {
  var u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.indexOf('/api/') === 0) return;
  if (e.request.mode === 'navigate') {
    e.respondWith(fetch(e.request).then(function (r) { var c = r.clone(); caches.open(V).then(function (ca) { ca.put('/index.html', c); }); return r; }).catch(function () { return caches.match('/index.html'); }));
    return;
  }
  e.respondWith(caches.match(e.request).then(function (hit) { return hit || fetch(e.request).then(function (r) { if (r.ok) { var c = r.clone(); caches.open(V).then(function (ca) { ca.put(e.request, c); }); } return r; }); }));
});
/* Web push (next phase): notification copy is lock-screen safe and never names the commitment. */
self.addEventListener('push', function (e) {
  var d = {}; try { d = e.data.json(); } catch (x) {}
  e.waitUntil(self.registration.showNotification(d.title || 'Accountability Partner', { body: d.body || 'Time to check in.', icon: '/icons/icon-192.png', badge: '/icons/icon-192.png', tag: 'ap' }));
});
self.addEventListener('notificationclick', function (e) { e.notification.close(); e.waitUntil(self.clients.openWindow('/')); });
