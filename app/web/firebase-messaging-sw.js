// Service worker Web Push (PWA / iPhone iOS 16.4+ setelah "Tambah ke Layar Utama").
// FCM mengirim data-message tanpa isi chat (isi terenkripsi), jadi notifikasi hanya berisi pengirim & jenis.
self.addEventListener('push', (event) => {
  let d = {};
  try {
    const j = event.data ? event.data.json() : {};
    d = j.data || j;
  } catch (e) {}
  const kind = d.kind || 'msg';
  const from = d.from_name || 'Tim';
  const map = {
    sos: ['SOS dari ' + from, 'Buka untuk melihat arah & jarak'],
    ann: ['Pengumuman: ' + (d.title || ''), 'Dari ' + from],
    rollcall: ['Absen dari ' + from, 'Tandai kondisimu'],
    fleet: [from, 'Update status armada'],
  };
  const [title, body] = map[kind] || [from, 'Pesan baru'];
  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      icon: '/icons/Icon-192.png',
      badge: '/icons/Icon-192.png',
      tag: kind === 'sos' ? 'sos' : 'ct-' + (d.ch || 'g'),
      renotify: true,
      requireInteraction: kind === 'sos',
      vibrate: kind === 'sos' ? [800, 400, 800, 400, 800] : [200],
      data: { route: kind === 'sos' ? 'sos' : kind === 'msg' ? 'chat:' + (d.ch || 'g') : 'info' },
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if ('focus' in c) return c.focus();
      }
      return clients.openWindow('/');
    })
  );
});
