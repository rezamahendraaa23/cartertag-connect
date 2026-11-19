// Connect.gs — API CarterTag Connect (app komunikasi lapangan driver & panitia).
//
// App (Android/PWA) memanggil:  POST <exec>?api=connect   body JSON {action, ...}   (Content-Type text/plain, tanpa preflight CORS)
// Console (admin.html) memanggil fungsi adminConnect* lewat google.script.run, dijaga adminGuard_ + izin menu "timlapangan".
//
// Penyimpanan:
//   - config_json konser  -> config.connect {enabled, epoch, manifest{enabled, source}} (default aktif; kode driver & koordinator dihitung dari epoch)
//   - Script Properties   -> CONNECT_KEY_<slug>_<epoch> (kunci grup, base64 32 byte), CONNECT_SECRET (HMAC token member),
//                            FIREBASE_SA_JSON (service account), FIREBASE_DB_URL, CONNECT_APK_URL, CONNECT_PWA_URL, CONNECT_APP_VERSION
//   - Spreadsheet konser  -> tab Tim Lapangan, Checkin Penumpang, Log Armada, Manifest Upload (dibuat otomatis)
//   - Firebase RTDB       -> /c/<slug>/... (lihat firebase/database.rules.json di repo app)
// Semua helper berakhiran "_" supaya tidak bisa dipanggil dari browser.

var CONNECT_TAB = { TEAM: 'Tim Lapangan', CHECKIN: 'Checkin Penumpang', FLEET: 'Log Armada', MANIFEST: 'Manifest Upload' };
var CONNECT_SCHEMAS = {
  'Tim Lapangan': {
    headers: ['member_id', 'nama', 'hp', 'role', 'nomor_mobil', 'area', 'status', 'pub_x25519', 'pub_ed25519', 'platform', 'fcm_token', 'app_version', 'joined_at', 'last_seen'],
    numeric: []
  },
  'Checkin Penumpang': { headers: ['event_id', 'order_id', 'hari', 'leg', 'status', 'nomor_mobil', 'oleh', 'waktu', 'synced_at'], numeric: [] },
  'Log Armada': { headers: ['event_id', 'nomor_mobil', 'member_id', 'leg', 'status', 'catatan', 'lat', 'lng', 'akurasi_m', 'waktu', 'synced_at'], numeric: [] },
  'Manifest Upload': { headers: ['nomor_mobil', 'nama', 'pax', 'no_wa', 'area', 'titik_kumpul', 'jam_jemput', 'trip', 'hari', 'order_id'], numeric: [] }
};
var CONNECT_CODE_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
var CONNECT_ROLES = ['driver', 'panitia', 'koordinator'];
var CONNECT_TOKEN_DAYS = 30;
var CONNECT_MEDIA_MAX = 5 * 1024 * 1024;

// ============================================================ entry point app

/** Dipanggil doPost (Code.gs) bila ?api=connect. */
function connectHandle_(e) {
  var out;
  try {
    var body = parseJson_((e && e.postData && e.postData.contents) || '{}', {});
    var fn = CONNECT_ACTIONS_[String(body.action || '')];
    if (!fn) throw userError_('Aksi tidak dikenal.');
    out = { ok: true, data: fn(body) };
    if (connectFirebaseReady_()) connectMaybeCleanup_();
  } catch (err) {
    if (!(err && err.isUserError)) console.error('connect error:', err && err.stack ? err.stack : err);
    out = { ok: false, error: { code: (err && err.code) || (err && err.isUserError ? 'user' : 'server'), message: err && err.isUserError ? err.message : 'Terjadi kesalahan server. Coba lagi.' } };
  }
  return ContentService.createTextOutput(JSON.stringify(out)).setMimeType(ContentService.MimeType.JSON);
}

var CONNECT_ACTIONS_ = {
  join: function (b) { return connectJoin_(b); },
  refresh: function (b) { return connectRefresh_(b); },
  leave: function (b) { return connectLeave_(b); },
  notify: function (b) { return connectNotify_(b); },
  media_upload: function (b) { return connectMediaUpload_(b); },
  media_get: function (b) { return connectMediaGet_(b); },
  sync_reports: function (b) { return connectSyncReports_(b); }
};

function connectError_(code, message) { var e = userError_(message); e.code = code; return e; }

// ============================================================ helper dasar

/** Pengaturan Connect per konser. Default: AKTIF untuk semua konser Aktif, tanpa perlu disetting admin. */
function connectCfg_(k) {
  var c = (k.config && k.config.connect) || {};
  return {
    enabled: c.enabled !== false,
    epoch: parseInt(c.epoch, 10) || 1,
    manifest: { enabled: !(c.manifest && c.manifest.enabled === false), source: (c.manifest && c.manifest.source) === 'upload' ? 'upload' : 'plotting' },
    updatedAt: String(c.updatedAt || '')
  };
}

/**
 * Dua kode per konser, dibuat otomatis (tidak disimpan): HMAC(secret, slug|role|epoch) -> 6 karakter.
 *   driver      : yang gabung pakai kode ini jadi Driver (wajib isi nomor mobil)
 *   koordinator : yang gabung pakai kode ini jadi Koordinator (boleh kirim pengumuman, mulai absen)
 * Reset kode = epoch naik -> kedua kode & kunci enkripsi berganti.
 */
function connectCodes_(k) {
  var cfg = connectCfg_(k), key = Utilities.base64Decode(connectSecret_()), out = {};
  ['driver', 'koordinator'].forEach(function (role) {
    var h = Utilities.computeHmacSha256Signature(Utilities.newBlob(k.slug + '|' + role + '|' + cfg.epoch).getBytes(), key), s = '';
    for (var i = 0; i < 6; i++) s += CONNECT_CODE_ALPHABET[(h[i] & 255) % 32];
    out[role] = s;
  });
  return out;
}

/** 08xx / +62 8xx / 8xx -> 628xx (hanya digit). */
function connectHp_(hp) {
  var d = String(hp || '').replace(/\D/g, '');
  if (d.indexOf('0') === 0) d = '62' + d.substring(1);
  else if (d.indexOf('8') === 0) d = '62' + d;
  return /^62\d{8,13}$/.test(d) ? d : '';
}

function connectB64url_(bytes) { return Utilities.base64EncodeWebSafe(bytes).replace(/=+$/, ''); }
function connectB64urlStr_(s) { return connectB64url_(Utilities.newBlob(s).getBytes()); }

/** member_id stabil per konser per HP: m_ + 10 karakter base32 dari SHA-256(slug|kunci publik Ed25519 perangkat). Rumus sama dengan app. */
function connectMemberId_(slug, devKey) {
  var d = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, slug + '|' + devKey, Utilities.Charset.UTF_8);
  var alpha = 'abcdefghijklmnopqrstuvwxyz234567', bits = 0, val = 0, out = '';
  for (var i = 0; i < d.length && out.length < 10; i++) {
    val = (val << 8) | (d[i] & 255); bits += 8;
    while (bits >= 5 && out.length < 10) { out += alpha[(val >>> (bits - 5)) & 31]; bits -= 5; }
  }
  return 'm_' + out;
}

function connectRandomBytes_(n) {
  var out = [];
  while (out.length < n) {
    var d = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, Utilities.getUuid() + Utilities.getUuid() + Date.now() + Math.random());
    out = out.concat(d);
  }
  return out.slice(0, n);
}

/** Kunci grup per epoch (32 byte, base64). Dibuat sekali, disimpan di Script Properties (bukan di sheet). */
function connectGroupKey_(slug, epoch) {
  var name = 'CONNECT_KEY_' + slug + '_' + epoch, v = props_().getProperty(name);
  if (!v) { v = Utilities.base64Encode(connectRandomBytes_(32)); props_().setProperty(name, v); }
  return v;
}

function connectSecret_() {
  var s = setting_('CONNECT_SECRET');
  if (!s) { s = Utilities.base64Encode(connectRandomBytes_(32)); props_().setProperty('CONNECT_SECRET', s); }
  return s;
}

function connectSign_(payload) {
  return connectB64url_(Utilities.computeHmacSha256Signature(Utilities.newBlob(payload).getBytes(), Utilities.base64Decode(connectSecret_())));
}

/** Token member: base64url(json).hmac — berisi slug, member_id, epoch saat dibuat, kedaluwarsa (ms). */
function connectMakeToken_(slug, mid) {
  var p = connectB64urlStr_(JSON.stringify({ s: slug, m: mid, x: Date.now() + CONNECT_TOKEN_DAYS * 86400000 }));
  return p + '.' + connectSign_(p);
}

/** Verifikasi token + muat konser & baris anggota. Melempar error kalau tidak sah. */
function connectAuth_(token) {
  var parts = String(token || '').split('.');
  if (parts.length !== 2 || connectSign_(parts[0]) !== parts[1]) throw connectError_('auth', 'Sesi tidak valid. Gabung ulang.');
  var p = parseJson_(Utilities.newBlob(Utilities.base64DecodeWebSafe(parts[0])).getDataAsString(), {});
  if (!p.s || !p.m || !(p.x > Date.now())) throw connectError_('auth', 'Sesi kedaluwarsa. Gabung ulang.');
  var k = useKonser_(p.s), cfg = connectCfg_(k);
  if (!cfg.enabled) throw connectError_('disabled', 'Connect untuk konser ini sedang nonaktif.');
  var team = connectTeam_(), me = team.byId[p.m];
  if (!me || me.status === 'dikeluarkan') throw connectError_('removed', 'Kamu sudah tidak terdaftar di tim konser ini.');
  if (me.status === 'keluar') throw connectError_('left', 'Kamu sudah keluar dari tim konser ini. Gabung lagi pakai kode.');
  return { konser: k, cfg: cfg, team: team, me: me };
}

function connectSs_() {
  var ss = openSpreadsheet_(), key = 'CONNECT_SCHEMA_' + _konser.slug, cache = CacheService.getScriptCache();
  try { if (!cache.get(key)) { ensureSchema_(ss, CONNECT_SCHEMAS); cache.put(key, '1', 21600); } } catch (e) { ensureSchema_(ss, CONNECT_SCHEMAS); }
  return ss;
}

function connectRateLimit_(key, max, seconds) {
  var c = CacheService.getScriptCache(), n = parseInt(c.get(key) || '0', 10);
  if (n >= max) throw connectError_('rate', 'Terlalu banyak percobaan. Coba lagi dalam ' + Math.ceil(seconds / 60) + ' menit.');
  return function () { c.put(key, String(n + 1), seconds); };
}

// ============================================================ tim (driver + panitia)

/** Info mobil dari Plotingan (tab Mobil) untuk nomor mobil yang diketik driver: area & plat. Kosong kalau belum diplot. */
function connectCarInfo_(ss, car) {
  var hit = { area: '', plat: '' };
  if (!car) return hit;
  try {
    readTableIn_(ss, TAB_CAR).some(function (c) {
      if (String(c['No']).trim() !== String(car).trim()) return false;
      hit = { area: String(c['Area'] || ''), plat: String(c['Plat'] || '') };
      return true;
    });
  } catch (e) { /* tab Mobil belum ada */ }
  return hit;
}

/**
 * Anggota konser = semua yang sudah gabung pakai kode (tab Tim Lapangan). Tidak perlu didaftarkan admin.
 * Disimpan di cache 2 menit supaya refresh/notify tidak membaca Sheet di setiap panggilan;
 * fresh = baca langsung dari Sheet (dipakai sebelum menulis), dan cache dibuang setiap ada perubahan anggota.
 */
function connectTeam_(fresh) {
  var key = 'CT_TEAM_' + _konser.slug, cache = CacheService.getScriptCache();
  if (!fresh) {
    try {
      var hit = cache.get(key);
      if (hit) {
        var list0 = JSON.parse(hit), byId0 = {};
        list0.forEach(function (m) { byId0[m.member_id] = m; });
        return { list: list0, byId: byId0 };
      }
    } catch (e) { /* cache rusak: baca ulang */ }
  }
  var team = connectTeamRead_();
  try { cache.put(key, JSON.stringify(team.list), 120); } catch (e) { /* > 100 KB: tanpa cache */ }
  return team;
}

function connectTeamClear_() {
  try { CacheService.getScriptCache().remove('CT_TEAM_' + _konser.slug); } catch (e) { /* abaikan */ }
}

function connectTeamRead_() {
  var ss = connectSs_(), byId = {}, list = [];
  readTableIn_(ss, CONNECT_TAB.TEAM).forEach(function (r) {
    var mid = String(r.member_id || '');
    if (!mid) return;
    var cur = byId[mid];
    if (!cur) { cur = byId[mid] = { member_id: mid }; list.push(cur); }
    cur.nama = String(r.nama || '');
    cur.hp = String(r.hp || '');
    cur.role = CONNECT_ROLES.indexOf(String(r.role)) !== -1 ? String(r.role) : 'panitia';
    cur.nomor_mobil = String(r.nomor_mobil || '');
    cur.cars = cur.nomor_mobil ? [cur.nomor_mobil] : [];
    cur.area = String(r.area || '');
    cur.status = String(r.status || 'aktif');
    cur.pub_x = String(r.pub_x25519 || ''); cur.pub_ed = String(r.pub_ed25519 || '');
    cur.platform = String(r.platform || ''); cur.fcm_token = String(r.fcm_token || '');
    cur.app_version = String(r.app_version || ''); cur.joined_at = String(r.joined_at || ''); cur.last_seen = String(r.last_seen || '');
    cur._row = r._row;
  });
  // plat & area driver diambil dari Plotingan kalau nomor mobilnya sudah diplot (driver cukup mengetik nomor mobil)
  var cars = {};
  try { readTableIn_(ss, TAB_CAR).forEach(function (c) { cars[String(c['No']).trim()] = c; }); } catch (e) { /* tab Mobil belum ada */ }
  list.forEach(function (m) {
    var c = m.nomor_mobil && cars[m.nomor_mobil.trim()];
    if (!c) return;
    m.plat = String(c['Plat'] || '');
    if (!m.area) m.area = String(c['Area'] || '');
  });
  return { list: list, byId: byId };
}

function connectRosterEntry_(m) {
  return { mid: m.member_id, n: m.nama, r: m.role, car: m.nomor_mobil || '', cars: m.cars || [], area: m.area || '', plat: m.plat || '',
    hp: m.hp || '', px: m.pub_x || '', pe: m.pub_ed || '', st: m.status, pf: m.platform || '', ls: m.last_seen || '', ja: connectMs_(m.joined_at) };
}

/** Anggota keluar / dikeluarkan + waktu keluarnya (ms presisi dari cache kalau ada, selain itu last_seen per menit). */
function connectGone_(slug, team) {
  var gone = team.list.filter(function (m) { return m.status === 'dikeluarkan' || m.status === 'keluar'; });
  if (!gone.length) return [];
  var cached = CacheService.getScriptCache().getAll(gone.map(function (m) { return 'CLMS_' + slug + '_' + m.member_id; }));
  return gone.map(function (m) {
    var ms = Number(cached['CLMS_' + slug + '_' + m.member_id]) || 0;
    return { mid: m.member_id, at: ms || connectMs_(m.last_seen), p: !!ms };   // p = presisi ms (tidak perlu toleransi menit)
  });
}

/** "yyyy-MM-dd'T'HH:mm" (nowLocal_) -> epoch ms; 0 kalau kosong / tidak terbaca. */
function connectMs_(s) {
  if (!s) return 0;
  try { return Utilities.parseDate(String(s), Session.getScriptTimeZone(), "yyyy-MM-dd'T'HH:mm").getTime(); } catch (e) { return 0; }
}

function connectUpsertMember_(m) {
  var ss = connectSs_(), now = nowLocal_();
  var row = { member_id: m.member_id, nama: m.nama, hp: m.hp, role: m.role, nomor_mobil: m.nomor_mobil || '', area: m.area || '', status: m.status,
    pub_x25519: m.pub_x || '', pub_ed25519: m.pub_ed || '', platform: m.platform || '', fcm_token: m.fcm_token || '', app_version: m.app_version || '',
    joined_at: m.joined_at || '', last_seen: now };
  if (m._row) updateObjectIn_(ss, CONNECT_TAB.TEAM, m._row, row);
  else m._row = appendObjectIn_(ss, CONNECT_TAB.TEAM, row);
  m.last_seen = now;
  connectTeamClear_();
  return m;
}

// ============================================================ manifest

/** Manifest penumpang: dari Plotingan (Mobil + Plot Penumpang + Booking) atau tab Manifest Upload. */
function connectManifest_(cfg) {
  if (!cfg.manifest.enabled) return { enabled: false, source: cfg.manifest.source, rows: [] };
  var ss = connectSs_(), rows = [];
  if (cfg.manifest.source === 'upload') {
    readTableIn_(ss, CONNECT_TAB.MANIFEST).forEach(function (r, i) {
      rows.push({ order_id: String(r.order_id || ('UP-' + (i + 1))), car: String(r.nomor_mobil || ''), nama: String(r.nama || ''), pax: parseInt(r.pax, 10) || 1,
        wa: connectHp_(r.no_wa), area: String(r.area || ''), titik: String(r.titik_kumpul || ''), jam: String(r.jam_jemput || ''),
        trip: String(r.trip || ''), hari: String(r.hari || ''), catatan: '' });
    });
  } else {
    var cars = {}, books = {};
    readTableIn_(ss, TAB_CAR).forEach(function (c) { cars[String(c['Hari'] || '') + '|' + String(c['No'])] = c; });
    readTableIn_(ss, TAB.BOOKING).forEach(function (b) { books[String(b['Order ID'])] = b; });
    readTableIn_(ss, TAB_PLOT).forEach(function (p) {
      var b = books[String(p['Order ID'])];
      if (!b || b.Status === STATUS.CANCELLED || b.Status === STATUS.WAIT_PAY) return;
      var hari = String(p['Hari'] || ''), car = cars[hari + '|' + String(p['Mobil'])] || {};
      rows.push({ order_id: String(p['Order ID']), car: String(p['Mobil'] || ''), nama: String(b['Nama Lengkap'] || ''), pax: parseInt(b['Jumlah Penumpang'], 10) || 1,
        wa: connectHp_(b['No WhatsApp']), area: String(b['Area'] || car['Area'] || ''), titik: String(b['Detail Alamat'] || ''),
        jam: String(p['Jam'] || car['Jam Jemput'] || b['Waktu Keberangkatan'] || ''), trip: String(b['Kebutuhan Trip'] || ''), hari: hari || String(b['Day Concert'] || ''),
        catatan: String(b['Catatan Khusus'] || '') });
    });
  }
  return { enabled: true, source: cfg.manifest.source, rows: rows, updatedAt: nowLocal_() };
}

/** Saring manifest per role: driver hanya mobilnya (+WA), panitia semua tanpa WA, koordinator semua. */
function connectManifestFor_(man, me) {
  if (!man.enabled) return man;
  var rows = man.rows;
  if (me.role === 'driver') rows = rows.filter(function (r) { return (me.cars || [me.nomor_mobil]).indexOf(r.car) !== -1; });
  else if (me.role === 'panitia') rows = rows.map(function (r) { var c = Object.assign({}, r); c.wa = ''; return c; });
  return { enabled: true, source: man.source, rows: rows, updatedAt: man.updatedAt };
}

// ============================================================ join / refresh

function connectBundle_(k, cfg, team, me) {
  var dates = (k.config.dates || []).slice();
  // options = konfigurasi klien Firebase (publik): {android:{apiKey, appId, messagingSenderId, projectId}, web:{..., authDomain}, vapidKey}
  var fb = connectFirebaseReady_() ? { custom_token: connectCustomToken_(k.slug, me), db_url: setting_('FIREBASE_DB_URL'),
    options: parseJson_(setting_('FIREBASE_CLIENT_JSON'), null), topics: connectTopicsFor_(k.slug, me) } : null;
  return {
    member: connectRosterEntry_(me),
    member_token: connectMakeToken_(k.slug, me.member_id),
    konser: { slug: k.slug, nama: k.config.name || k.nama, venue: k.config.venue || '', dates: dates },
    epoch: cfg.epoch,
    group_key: connectGroupKey_(k.slug, cfg.epoch),
    roster: team.list.filter(function (m) { return m.status !== 'dikeluarkan' && m.status !== 'keluar'; }).map(connectRosterEntry_),
    // yang keluar / dikeluarkan: app menyembunyikannya juga dari daftar yang dikenal lewat Bluetooth (at = waktu keluar)
    gone: connectGone_(k.slug, team),
    manifest: connectManifestFor_(connectManifest_(cfg), me),
    firebase: fb,
    app: { version: setting_('CONNECT_APP_VERSION'), apk_url: setting_('CONNECT_APK_URL'), pwa_url: setting_('CONNECT_PWA_URL') },
    server_time: Date.now()
  };
}

/** Cari konser + role dari kode yang diketik. Hanya konser Aktif dengan Connect aktif. */
function connectFindByCode_(code) {
  var hit = null;
  readKonserRows_().forEach(function (r) {
    if (hit || r.status !== 'Aktif') return;
    var k = rowToKonser_(r);
    if (!connectCfg_(k).enabled) return;
    var codes = connectCodes_(k);
    if (codes.driver === code) hit = { k: k, role: 'driver' };
    else if (codes.koordinator === code) hit = { k: k, role: 'koordinator' };
  });
  return hit;
}

/** Gabung: cukup nama + kode (+ nomor mobil untuk driver). Role ditentukan kode. */
function connectJoin_(b) {
  var nama = cap_(b.nama, 60);
  if (!nama) throw connectError_('nama', 'Nama wajib diisi.');
  var code = String(b.kode || '').toUpperCase().replace(/^CT-?/, '').replace(/[^A-Z0-9]/g, '');
  if (code.length !== 6) throw connectError_('kode', 'Kode terdiri dari 6 karakter, contoh CT-7KQ4MX.');
  if (!/^[A-Za-z0-9+/=_-]{40,64}$/.test(String(b.pub_x || '')) || !/^[A-Za-z0-9+/=_-]{40,64}$/.test(String(b.pub_ed || ''))) throw connectError_('keys', 'Kunci perangkat tidak valid. Perbarui aplikasi.');
  var dev = Utilities.base64EncodeWebSafe(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, String(b.pub_ed))).substring(0, 16);
  var hit = connectRateLimit_('CJ_' + dev, 8, 600);

  var found = connectFindByCode_(code);
  if (!found) { hit(); throw connectError_('kode', 'Kode tidak ditemukan. Cek lagi ke koordinator.'); }
  var k = found.k, role = found.role;
  var car = cap_(b.car, 10).replace(/^(mobil|m|c)\s*/i, '').trim();   // "C3" / "mobil 3" -> "3" (sama dengan kolom No di Plotingan)
  if (role === 'driver' && !car) throw connectError_('car', 'Kamu pakai kode driver: isi nomor mobil kamu.');
  _konser = k; _ss = null;
  var cfg = connectCfg_(k);

  return withLock_(function () {
    var team = connectTeam_(true), mid = connectMemberId_(k.slug, String(b.pub_ed)), me = team.byId[mid];
    if (me && me.status === 'dikeluarkan') throw connectError_('removed', 'HP ini sudah dikeluarkan dari tim konser. Hubungi koordinator.');
    if (!me) {
      me = { member_id: mid, hp: '', cars: [], area: '', _row: 0 };
      team.byId[mid] = me; team.list.push(me);
    }
    me.role = role;
    me.nomor_mobil = role === 'driver' ? car : '';
    me.cars = me.nomor_mobil ? [me.nomor_mobil] : [];
    var info = connectCarInfo_(connectSs_(), me.nomor_mobil);
    me.area = info.area; me.plat = info.plat;
    me.nama = nama;
    var hp = connectHp_(b.hp);
    if (hp) {
      me.hp = hp;   // opsional: supaya tim bisa telepon / WhatsApp
      // nomor HP sama tapi perangkat lain (app dipasang ulang / ganti HP): baris lama dianggap keluar
      team.list.forEach(function (o) {
        if (o.member_id !== me.member_id && o.hp === hp && o.status === 'aktif') { o.status = 'keluar'; connectUpsertMember_(o); }
      });
    }
    me.pub_x = String(b.pub_x); me.pub_ed = String(b.pub_ed);
    me.platform = b.platform === 'web' ? 'web' : 'android';
    me.fcm_token = cap_(b.fcm_token, 400);
    me.app_version = cap_(b.app_version, 20);
    // join hanya dipanggil saat benar-benar gabung: selalu catat waktunya (dipakai menolak pemberitahuan keluar yang basi)
    me.status = 'aktif'; me.joined_at = nowLocal_();
    // waktu gabung presisi ms (joined_at di sheet cuma sampai menit): pembanding token di connectLeave_
    CacheService.getScriptCache().put('CJMS_' + k.slug + '_' + mid, String(Date.now()), 21600);
    connectUpsertMember_(me);
    return connectBundle_(k, cfg, team, me);
  });
}

function connectRefresh_(b) {
  var a = connectAuth_(b.member_token), me = a.me;
  var changed = false;
  if (b.fcm_token !== undefined && cap_(b.fcm_token, 400) !== me.fcm_token) { me.fcm_token = cap_(b.fcm_token, 400); changed = true; }
  if (b.app_version && b.app_version !== me.app_version) { me.app_version = cap_(b.app_version, 20); changed = true; }
  // last_seen ditulis paling sering tiap 10 menit per anggota (hemat kuota tulis sheet)
  var c = CacheService.getScriptCache(), seenKey = 'CS_' + _konser.slug + '_' + me.member_id;
  if (changed || !c.get(seenKey)) {
    withLock_(function () { var fresh = connectTeam_(true).byId[me.member_id]; if (fresh) { me._row = fresh._row; connectUpsertMember_(me); } });
    c.put(seenKey, '1', 600);
  }
  return connectBundle_(a.konser, a.cfg, a.team, me);
}

/** Anggota menekan "Keluar & hapus konser" di app: tandai keluar (boleh gabung lagi, beda dengan dikeluarkan admin). */
function connectLeave_(b) {
  var parts = String(b.member_token || '').split('.');
  if (parts.length !== 2 || connectSign_(parts[0]) !== parts[1]) throw connectError_('auth', 'Sesi tidak valid.');
  var p = parseJson_(Utilities.newBlob(Utilities.base64DecodeWebSafe(parts[0])).getDataAsString(), {});
  if (!p.s || !p.m) throw connectError_('auth', 'Sesi tidak valid.');
  useKonser_(p.s);
  return withLock_(function () {
    var me = connectTeam_(true).byId[p.m];
    if (!me) return { left: false };
    // token diterbitkan (jam server) sebelum gabung terakhir = pemberitahuan dari sesi lama (tertunda / telat diproses): abaikan.
    // Setiap join menerbitkan token baru, jadi keluar dari sesi sekarang selalu dicatat.
    var iat = (Number(p.x) || 0) - CONNECT_TOKEN_DAYS * 86400000;
    var jm = Number(CacheService.getScriptCache().get('CJMS_' + p.s + '_' + p.m)) || connectMs_(me.joined_at);
    if (me.status === 'aktif' && jm && iat < jm) return { left: false, stale: true };
    if (me.status !== 'dikeluarkan') {
      me.status = 'keluar'; me.fcm_token = ''; connectUpsertMember_(me);
      // waktu keluar presisi ms untuk daftar 'gone' (last_seen di sheet cuma sampai menit)
      CacheService.getScriptCache().put('CLMS_' + p.s + '_' + p.m, String(Date.now()), 21600);
    }
    return { left: true };
  });
}

// ============================================================ notifikasi (FCM)

/** Nama topik FCM per konser: all (semua), koord (koordinator), a_<area> (driver area itu). */
function connectTopic_(slug, scope) {
  return ('ct_' + slug + '_' + scope).replace(/[^a-zA-Z0-9\-_.~%]/g, '_').substring(0, 200);
}
function connectAreaScope_(area) { return 'a_' + String(area || '').toLowerCase().replace(/[^a-z0-9]+/g, '_'); }

/** App 1.3.0+ berlangganan topik; versi lebih lama tetap dikirim per token. */
function connectTopicReady_(ver) {
  var p = String(ver || '0').split('.').map(function (x) { return parseInt(x, 10) || 0; });
  return (p[0] || 0) > 1 || ((p[0] || 0) === 1 && (p[1] || 0) >= 3);
}

/** Topik yang wajib diikuti HP Android anggota ini (dikirim di bundle join/refresh). */
function connectTopicsFor_(slug, m) {
  var t = [connectTopic_(slug, 'all')];
  if (m.role !== 'driver') t.push(connectTopic_(slug, 'koord'));
  if (m.area) t.push(connectTopic_(slug, connectAreaScope_(m.area)));
  return t;
}

/**
 * Fan-out FCM data-message (tanpa isi pesan — isi terenkripsi, app mengambil sendiri dari RTDB).
 * HP Android menerima lewat TOPIK (1 panggilan untuk semua), web/iPhone dikirim per token (biasanya sedikit).
 * Pengirim juga berlangganan topik, jadi app mengabaikan push dengan "from" = dirinya sendiri.
 * ch: 'g' semua, 'k' koordinator & panitia, 'a:<area>' anggota area itu + koordinator, 'd:<mid>:<mid>' lawan bicara.
 */
function connectNotify_(b) {
  var a = connectAuth_(b.member_token);
  if (!connectFirebaseReady_()) return { sent: 0, reason: 'firebase_not_configured' };
  var ch = String(b.ch || 'g'), prio = parseInt(b.prio, 10) || 0, me = a.me;
  var hit = connectRateLimit_('CN_' + _konser.slug + '_' + me.member_id, prio >= 2 ? 1000 : 120, 60); hit();
  var isDm = ch.indexOf('d:') === 0;
  var topics = [];
  if (!isDm) {
    if (prio >= 1 || ch === 'g') topics = [connectTopic_(_konser.slug, 'all')];
    else if (ch === 'k') topics = [connectTopic_(_konser.slug, 'koord')];
    else if (ch.indexOf('a:') === 0) topics = [connectTopic_(_konser.slug, connectAreaScope_(ch.substring(2))), connectTopic_(_konser.slug, 'koord')];
  }
  var targets = a.team.list.filter(function (m) {
    if (m.member_id === me.member_id || !m.fcm_token || m.status !== 'aktif') return false;
    if (!isDm && m.platform !== 'web' && connectTopicReady_(m.app_version)) return false;   // Android 1.3.0+ sudah lewat topik
    if (prio >= 1) return true;   // pengumuman / SOS ke semua
    if (ch === 'g') return true;
    if (ch === 'k') return m.role !== 'driver';
    if (ch.indexOf('a:') === 0) return m.role === 'koordinator' || String(m.area).toLowerCase() === ch.substring(2).toLowerCase();
    if (ch.indexOf('d:') === 0) return ch.split(':').indexOf(m.member_id) !== -1;
    return false;
  });
  var data = { slug: _konser.slug, ch: ch, from: me.member_id, from_name: me.nama, kind: String(b.kind || 'msg').substring(0, 20),
    title: cap_(b.title, 80), ids: (b.msg_ids || []).slice(0, 20).join(','), prio: String(prio) };
  var sent = connectFcmSend_(targets.map(function (m) { return m.fcm_token; }), data, prio, topics);
  return { sent: sent, topics: topics.length };
}

function connectFcmSend_(tokens, data, prio, topics) {
  topics = topics || [];
  if (!tokens.length && !topics.length) return 0;
  var sa = connectSa_(), url = 'https://fcm.googleapis.com/v1/projects/' + sa.project_id + '/messages:send', auth = 'Bearer ' + connectOauth_();
  var targets = tokens.map(function (t) { return { token: t }; }).concat(topics.map(function (t) { return { topic: t }; }));
  var reqs = targets.map(function (target) {
    var msg = { message: Object.assign({}, target, { data: data,
      android: { priority: prio >= 1 ? 'HIGH' : 'NORMAL', ttl: prio >= 2 ? '7200s' : '21600s' },
      webpush: { headers: { Urgency: prio >= 1 ? 'high' : 'normal', TTL: '21600' } } }) };
    return { url: url, method: 'post', contentType: 'application/json', headers: { Authorization: auth }, payload: JSON.stringify(msg), muteHttpExceptions: true };
  });
  var ok = 0;
  for (var i = 0; i < reqs.length; i += 50) {
    UrlFetchApp.fetchAll(reqs.slice(i, i + 50)).forEach(function (r) { if (r.getResponseCode() === 200) ok++; });
  }
  return ok;
}

// ============================================================ media (Google Drive)

function connectMediaFolder_() {
  var parent = DriveApp.getFolderById(_konser.folder_id), it = parent.getFoldersByName('Connect Media');
  return it.hasNext() ? it.next() : parent.createFolder('Connect Media');
}

/** Simpan media terenkripsi (ciphertext dari app) ke Drive folder konser. */
function connectMediaUpload_(b) {
  var a = connectAuth_(b.member_token);
  var hit = connectRateLimit_('CM_' + _konser.slug + '_' + a.me.member_id, 60, 600); hit();
  var bytes = Utilities.base64Decode(String(b.b64 || ''));
  if (!bytes.length) throw connectError_('media', 'File kosong.');
  if (bytes.length > CONNECT_MEDIA_MAX) throw connectError_('media', 'File terlalu besar (maks 5 MB).');
  var name = String(b.msg_id || Utilities.getUuid()).replace(/[^a-zA-Z0-9-]/g, '') + '.bin';
  var file = connectMediaFolder_().createFile(Utilities.newBlob(bytes, 'application/octet-stream', name));
  file.setDescription('CarterTag Connect · ' + a.me.member_id + ' · ' + String(b.mime || '').substring(0, 40));
  return { file_id: file.getId(), size: bytes.length };
}

function connectMediaGet_(b) {
  connectAuth_(b.member_token);
  var id = String(b.file_id || '');
  if (!/^[a-zA-Z0-9_-]{20,80}$/.test(id)) throw connectError_('media', 'ID file tidak valid.');
  var file = DriveApp.getFileById(id), parents = file.getParents(), inside = false;
  while (parents.hasNext()) { var p = parents.next(); if (p.getName() === 'Connect Media') { var pp = p.getParents(); while (pp.hasNext()) { if (pp.next().getId() === _konser.folder_id) inside = true; } } }
  if (!inside) throw connectError_('media', 'File tidak ditemukan.');
  return { b64: Utilities.base64Encode(file.getBlob().getBytes()) };
}

// ============================================================ laporan (armada, check-in, absen)

/** Simpan log status armada & check-in penumpang dari HP. Idempoten berdasarkan event_id. */
function connectSyncReports_(b) {
  var a = connectAuth_(b.member_token), me = a.me, accepted = [];
  var fleet = (b.fleet || []).slice(0, 300), checkins = (b.checkins || []).slice(0, 500);
  if (!fleet.length && !checkins.length) return { accepted_ids: [] };
  return withLock_(function () {
    var ss = connectSs_(), now = nowLocal_();
    var seen = {};
    [CONNECT_TAB.FLEET, CONNECT_TAB.CHECKIN].forEach(function (t) { readTableIn_(ss, t).forEach(function (r) { seen[String(r.event_id)] = 1; }); });
    var fleetRows = [], chkRows = [];
    fleet.forEach(function (f) {
      var id = cap_(f.event_id, 40);
      if (!id) return;
      accepted.push(id);
      if (seen[id]) return;
      seen[id] = 1;
      fleetRows.push({ event_id: id, nomor_mobil: cap_(f.car, 10), member_id: cap_(f.by || me.member_id, 20), leg: f.leg === 'pulang' ? 'pulang' : 'pergi',
        status: cap_(f.status, 20), catatan: cap_(f.note, 200), lat: f.lat || '', lng: f.lng || '', akurasi_m: f.acc || '', waktu: cap_(f.at, 25), synced_at: now });
    });
    checkins.forEach(function (c) {
      var id = cap_(c.event_id, 40);
      if (!id) return;
      accepted.push(id);
      if (seen[id]) return;
      seen[id] = 1;
      chkRows.push({ event_id: id, order_id: cap_(c.order_id, 30), hari: cap_(c.hari, 12), leg: c.leg === 'pulang' ? 'pulang' : 'pergi',
        status: c.status === 'tidak_datang' ? 'tidak_datang' : 'naik', nomor_mobil: cap_(c.car, 10), oleh: cap_(c.by || me.member_id, 20), waktu: cap_(c.at, 25), synced_at: now });
    });
    connectAppendRows_(ss, CONNECT_TAB.FLEET, fleetRows);
    connectAppendRows_(ss, CONNECT_TAB.CHECKIN, chkRows);
    return { accepted_ids: accepted };
  });
}

function connectAppendRows_(ss, tab, objs) {
  if (!objs.length) return;
  var sheet = getSheetIn_(ss, tab), headers = headersOf_(sheet), start = Math.max(sheet.getLastRow(), 1) + 1;
  if (sheet.getMaxRows() < start + objs.length - 1) sheet.insertRowsAfter(sheet.getMaxRows(), Math.max(objs.length, 500));
  sheet.getRange(start, 1, objs.length, headers.length).setNumberFormat('@')
    .setValues(objs.map(function (o) { return headers.map(function (h) { return o[h] === undefined || o[h] === null ? '' : String(o[h]); }); }));
}

// ============================================================ Firebase (service account)

function connectSa_() {
  var sa = parseJson_(setting_('FIREBASE_SA_JSON'), null);
  if (!sa || !sa.private_key || !sa.client_email || !sa.project_id) throw new Error('FIREBASE_SA_JSON belum diisi.');
  return sa;
}
function connectFirebaseReady_() { return !!(setting_('FIREBASE_SA_JSON') && setting_('FIREBASE_DB_URL') && setting_('FIREBASE_CLIENT_JSON')); }

function connectJwt_(sa, claims) {
  var head = connectB64urlStr_(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  var body = connectB64urlStr_(JSON.stringify(claims));
  var sig = connectB64url_(Utilities.computeRsaSha256Signature(head + '.' + body, sa.private_key));
  return head + '.' + body + '.' + sig;
}

/** Firebase Auth custom token: uid = <slug>__<member_id>, claims dipakai rules RTDB. */
function connectCustomToken_(slug, me) {
  var sa = connectSa_(), now = Math.floor(Date.now() / 1000);
  return connectJwt_(sa, {
    iss: sa.client_email, sub: sa.client_email,
    aud: 'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit',
    iat: now, exp: now + 3600, uid: slug + '__' + me.member_id,
    claims: { konser: slug, mid: me.member_id, role: me.role, cars: (me.cars && me.cars.length ? me.cars : (me.nomor_mobil ? [me.nomor_mobil] : [])).join(',') }
  });
}

/** OAuth access token service account (FCM + RTDB REST), cache 50 menit. */
function connectOauth_() {
  var c = CacheService.getScriptCache(), hit = c.get('CONNECT_OAUTH');
  if (hit) return hit;
  var sa = connectSa_(), now = Math.floor(Date.now() / 1000);
  var jwt = connectJwt_(sa, { iss: sa.client_email, aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600,
    scope: 'https://www.googleapis.com/auth/firebase.messaging https://www.googleapis.com/auth/firebase.database https://www.googleapis.com/auth/userinfo.email' });
  var res = UrlFetchApp.fetch('https://oauth2.googleapis.com/token', { method: 'post', muteHttpExceptions: true,
    payload: { grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt } });
  var tok = parseJson_(res.getContentText(), {}).access_token;
  if (!tok) throw new Error('Gagal mengambil token Firebase: ' + res.getContentText().substring(0, 200));
  c.put('CONNECT_OAUTH', tok, 3000);
  return tok;
}

/** RTDB REST: method GET/PUT/PATCH/DELETE, path tanpa .json. */
function connectRtdb_(method, path, body) {
  var url = setting_('FIREBASE_DB_URL').replace(/\/+$/, '') + '/' + path + '.json';
  var opt = { method: method.toLowerCase(), muteHttpExceptions: true, headers: { Authorization: 'Bearer ' + connectOauth_() }, contentType: 'application/json' };
  if (body !== undefined) opt.payload = JSON.stringify(body);
  var res = UrlFetchApp.fetch(url, opt);
  if (res.getResponseCode() >= 300) throw new Error('RTDB ' + method + ' ' + path + ': ' + res.getResponseCode() + ' ' + res.getContentText().substring(0, 200));
  return parseJson_(res.getContentText(), null);
}

/**
 * Hapus data RTDB konser yang tanggal terakhirnya lewat 7 hari. Tidak memakai time-trigger (ScriptApp butuh scope baru yang
 * harus disetujui ulang pemilik, dan selama belum disetujui web app produksi ikut menolak pengunjung). Sebagai gantinya
 * dipicu panggilan API Connect biasa, maksimal sekali per 24 jam (connectMaybeCleanup_).
 */
function connectMaybeCleanup_() {
  var c = CacheService.getScriptCache();
  if (c.get('CONNECT_CLEANUP_DONE')) return;
  c.put('CONNECT_CLEANUP_DONE', '1', 21600);   // cache maks 6 jam; ditambah penanda tanggal di bawah supaya tetap sekali sehari
  var today = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  if (setting_('CONNECT_CLEANUP_DAY') === today) return;
  props_().setProperty('CONNECT_CLEANUP_DAY', today);
  try { connectCleanup_(); } catch (e) { console.error('connectCleanup_', e); }
}

function connectCleanup_() {
  if (!connectFirebaseReady_() || !systemReady_()) return;
  var limit = Utilities.formatDate(new Date(Date.now() - 7 * 86400000), Session.getScriptTimeZone(), 'yyyy-MM-dd');
  readKonserRows_().forEach(function (r) {
    var k = rowToKonser_(r), dates = (k.config.dates || []).map(String).sort();
    var last = dates.length ? dates[dates.length - 1].substring(0, 10) : '';
    if (last && last < limit && connectCfg_(k).epoch > 0) {
      try { connectRtdb_('DELETE', 'c/' + k.slug); } catch (e) { console.error('cleanup ' + k.slug, e); }
    }
  });
}

// ============================================================ API Console (google.script.run)

function connectAdminSnapshot_(k) {
  var cfg = connectCfg_(k), team = connectTeam_();
  var counts = { total: 0, aktif: 0, driver: 0, panitia: 0, koordinator: 0 };
  team.list.forEach(function (m) {
    if (m.status === 'dikeluarkan' || m.status === 'keluar') return;
    counts.total++; if (m.status === 'aktif') counts.aktif++; counts[m.role] = (counts[m.role] || 0) + 1;
  });
  return {
    slug: k.slug, nama: k.config.name || k.nama, cfg: cfg, counts: counts, codes: cfg.enabled ? connectCodes_(k) : null,
    members: team.list.map(function (m) {
      return { member_id: m.member_id, nama: m.nama, hp: m.hp, role: m.role, mobil: (m.cars && m.cars.length ? m.cars.join(', ') : m.nomor_mobil) || '', area: m.area || '',
        status: m.status, platform: m.platform || '', last_seen: m.last_seen || '', app_version: m.app_version || '' };
    }),
    firebase: connectFirebaseReady_(),
    app: { version: setting_('CONNECT_APP_VERSION'), apk_url: setting_('CONNECT_APK_URL'), pwa_url: setting_('CONNECT_PWA_URL') }
  };
}

function adminConnectGet(token, slug) {
  return adminGuard_(token, function () {
    adminNeed_('timlapangan:view');
    var k = adminUse_(slug);
    return { success: true, data: connectAdminSnapshot_(k) };
  });
}

function adminConnectSave(token, slug, input) {
  return adminGuard_(token, function () {
    adminNeed_('timlapangan:edit');
    var k = adminUse_(slug, true), cur = connectCfg_(k);
    input = input || {};
    if (input.enabled !== undefined) cur.enabled = !!input.enabled;
    if (input.manifest) {
      if (input.manifest.enabled !== undefined) cur.manifest.enabled = !!input.manifest.enabled;
      if (input.manifest.source) cur.manifest.source = input.manifest.source === 'upload' ? 'upload' : 'plotting';
    }
    cur.updatedAt = nowLocal_();
    k.config.connect = cur;
    persistKonser_(k);
    _konser = k; _ss = null;
    return { success: true, data: connectAdminSnapshot_(k) };
  });
}

/** Reset kode: epoch naik -> kode driver, kode koordinator, dan kunci enkripsi berganti. */
function adminConnectCode(token, slug, reset) {
  return adminGuard_(token, function () {
    adminNeed_('timlapangan:edit');
    var k = adminUse_(slug, true), cur = connectCfg_(k);
    if (reset) cur.epoch = cur.epoch + 1;
    cur.updatedAt = nowLocal_();
    k.config.connect = cur;
    persistKonser_(k);
    _konser = k; _ss = null;
    connectGroupKey_(k.slug, cur.epoch);
    if (connectFirebaseReady_()) { try { connectRtdb_('PATCH', 'c/' + k.slug + '/meta', { epoch: cur.epoch, updatedAt: Date.now() }); } catch (e) { console.error(e); } }
    return { success: true, data: connectAdminSnapshot_(k) };
  });
}

/** Ubah role / keluarkan / pulihkan anggota. patch: {role?, status?: 'dikeluarkan'|'aktif'|'diundang'} */
function adminConnectMemberUpdate(token, slug, memberId, patch) {
  return adminGuard_(token, function () {
    adminNeed_('timlapangan:edit');
    adminUse_(slug);
    patch = patch || {};
    withLock_(function () {
      var team = connectTeam_(true), m = team.byId[String(memberId)];
      if (!m) throw new Error('Anggota tidak ditemukan.');
      if (patch.role !== undefined) {
        if (CONNECT_ROLES.indexOf(patch.role) === -1) throw new Error('Role tidak dikenal.');
        m.role = patch.role;
      }
      if (patch.status !== undefined) {
        if (['dikeluarkan', 'aktif', 'diundang', 'keluar'].indexOf(patch.status) === -1) throw new Error('Status tidak dikenal.');
        m.status = patch.status === 'aktif' && !m.pub_x ? 'diundang' : patch.status;
      }
      connectUpsertMember_(m);
    });
    return { success: true, data: connectAdminSnapshot_(_konser) };
  });
}

/** Pengumuman dari Console: ditulis ke RTDB /c/<slug>/ann (dibaca app saat online) + push ke semua. */
function adminConnectAnnounce(token, slug, ann) {
  return adminGuard_(token, function () {
    adminNeed_('timlapangan:edit');
    adminUse_(slug);
    if (!connectFirebaseReady_()) throw new Error('Firebase belum diatur (menu Tim Lapangan → Pengaturan Firebase).');
    ann = ann || {};
    var title = cap_(ann.title, 80), body = cap_(ann.body, 1000);
    if (!title) throw new Error('Judul pengumuman wajib diisi.');
    var id = 'ann_' + Date.now().toString(36) + Utilities.getUuid().substring(0, 6);
    var rec = { id: id, title: title, body: body, prio: ann.prio === 'penting' ? 1 : 0, by: 'Console · ' + (_actor ? _actor.name : 'Admin'), at: Date.now() };
    connectRtdb_('PUT', 'c/' + _konser.slug + '/ann/' + id, rec);
    var team = connectTeam_();
    var sent = connectFcmSend_(team.list.filter(function (m) { return m.status === 'aktif' && m.fcm_token && m.platform === 'web'; }).map(function (m) { return m.fcm_token; }),
      { slug: _konser.slug, ch: 'g', from: 'console', from_name: rec.by, kind: 'ann', title: title, ids: id, prio: '1' }, 1, [connectTopic_(_konser.slug, 'all')]);
    return { success: true, id: id, sent: sent };
  });
}

/** Hari konser (mulai 06.00): pulang lewat tengah malam tetap hari yang sama dengan pergi. */
function connectConcertDay_(ms) {
  return Utilities.formatDate(new Date(ms - 6 * 3600000), Session.getScriptTimeZone(), 'yyyy-MM-dd');
}

/**
 * Rekap check-in penumpang hari konser ini per mobil: {mobil: {pergi: {naik, pax, belum}, pulang: {...}}}.
 * Dari manifest + tab Checkin Penumpang (yang tersinkron dari HP). Di-cache 30 detik supaya Monitor tidak membebani GAS.
 */
function connectCheckinCounts_(cfg) {
  var key = 'CT_CK_' + _konser.slug, cache = CacheService.getScriptCache();
  try { var hit = cache.get(key); if (hit) return JSON.parse(hit); } catch (e) { /* hitung ulang */ }
  var man = connectManifest_(cfg), out = {};
  if (!man.enabled) return out;
  var today = connectConcertDay_(Date.now());
  var days = {};
  man.rows.forEach(function (r) { if (r.hari) days[r.hari] = 1; });
  var multi = Object.keys(days).length > 1;
  var latest = {};
  readTableIn_(connectSs_(), CONNECT_TAB.CHECKIN).forEach(function (c) {
    var t = new Date(String(c.waktu)).getTime();
    if (!t || connectConcertDay_(t) !== today) return;
    var k = String(c.order_id) + '|' + String(c.hari) + '|' + String(c.leg);
    if (!latest[k] || latest[k].t < t) latest[k] = { t: t, st: String(c.status) };
  });
  man.rows.forEach(function (r) {
    if (multi && r.hari && r.hari !== today) return;
    var trip = String(r.trip || '').toLowerCase();
    var legs = trip.indexOf('one') !== -1 ? (trip.indexOf('pulang') !== -1 && trip.indexOf('pergi') === -1 ? ['pulang'] : ['pergi']) : ['pergi', 'pulang'];
    var car = out[r.car] = out[r.car] || { pergi: { naik: 0, pax: 0, belum: 0 }, pulang: { naik: 0, pax: 0, belum: 0 } };
    legs.forEach(function (leg) {
      var ck = latest[r.order_id + '|' + r.hari + '|' + leg];
      car[leg].pax += r.pax;
      if (!ck) car[leg].belum++;
      else if (ck.st === 'naik') car[leg].naik += r.pax;
    });
  });
  try { cache.put(key, JSON.stringify(out), 30); } catch (e) { /* abaikan */ }
  return out;
}

/** Monitor: rekap penumpang per mobil + SOS aktif + presence + pengumuman. */
function adminConnectMonitor(token, slug) {
  return adminGuard_(token, function () {
    adminNeed_('timlapangan:view');
    adminUse_(slug);
    if (!connectFirebaseReady_()) return { success: true, data: { firebase: false } };
    var base = 'c/' + _konser.slug + '/';
    var team = connectTeam_();
    return { success: true, data: {
      firebase: true,
      checkins: connectCheckinCounts_(connectCfg_(_konser)),
      sos: connectRtdb_('GET', base + 'sos') || {},
      presence: connectRtdb_('GET', base + 'presence') || {},
      ann: connectRtdb_('GET', base + 'ann') || {},
      members: team.list.map(connectRosterEntry_),
      at: Date.now()
    } };
  });
}

/** Upload manifest (baris hasil parse CSV/XLSX di browser). dryRun = hanya validasi. */
function adminConnectManifestUpload(token, slug, rows, dryRun) {
  return adminGuard_(token, function () {
    adminNeed_('timlapangan:edit');
    adminUse_(slug);
    rows = (rows || []).slice(0, 3000);
    var errors = [], out = [];
    rows.forEach(function (r, i) {
      var n = i + 2;
      var o = { nomor_mobil: cap_(r.nomor_mobil, 10), nama: cap_(r.nama, 80), pax: parseInt(r.pax, 10) || 0, no_wa: cap_(r.no_wa, 20),
        area: cap_(r.area, 40), titik_kumpul: cap_(r.titik_kumpul, 200), jam_jemput: cap_(r.jam_jemput, 10), trip: cap_(r.trip, 30), hari: cap_(r.hari, 12), order_id: cap_(r.order_id, 30) };
      if (!o.nomor_mobil) errors.push({ row: n, kolom: 'nomor_mobil', pesan: 'Wajib diisi' });
      if (!o.nama) errors.push({ row: n, kolom: 'nama', pesan: 'Wajib diisi' });
      if (o.pax < 1) errors.push({ row: n, kolom: 'pax', pesan: 'Minimal 1' });
      if (o.no_wa && !connectHp_(o.no_wa)) errors.push({ row: n, kolom: 'no_wa', pesan: 'Nomor tidak valid' });
      out.push(o);
    });
    if (dryRun || errors.length) return { success: true, valid: !errors.length, errors: errors, count: out.length };
    withLock_(function () {
      var ss = connectSs_(), sheet = getSheetIn_(ss, CONNECT_TAB.MANIFEST);
      if (sheet.getLastRow() > 1) sheet.getRange(2, 1, sheet.getLastRow() - 1, sheet.getLastColumn()).clearContent();
      connectAppendRows_(ss, CONNECT_TAB.MANIFEST, out);
    });
    return { success: true, valid: true, errors: [], count: out.length };
  });
}

/** Pengaturan global Connect (menu Sistem / Tim Lapangan): service account Firebase, URL DB, link APK/PWA, versi. */
function adminConnectSettingsGet(token) {
  return adminGuard_(token, function () {
    adminNeed_('timlapangan:edit');
    var sa = parseJson_(setting_('FIREBASE_SA_JSON'), null);
    return { success: true, data: {
      firebase_project: sa ? sa.project_id : '', firebase_email: sa ? sa.client_email : '', db_url: setting_('FIREBASE_DB_URL'),
      client_json: setting_('FIREBASE_CLIENT_JSON'),
      apk_url: setting_('CONNECT_APK_URL'), pwa_url: setting_('CONNECT_PWA_URL'), app_version: setting_('CONNECT_APP_VERSION'),
      exec_url: ScriptApp.getService().getUrl() + '?api=connect'
    } };
  });
}

function adminConnectSettingsSave(token, input) {
  return adminGuard_(token, function () {
    adminNeed_('superadmin');
    input = input || {};
    var p = props_();
    if (input.sa_json) {
      var sa = parseJson_(input.sa_json, null);
      if (!sa || sa.type !== 'service_account' || !sa.private_key || !sa.client_email || !sa.project_id) throw new Error('JSON service account tidak valid.');
      p.setProperty('FIREBASE_SA_JSON', JSON.stringify({ project_id: sa.project_id, client_email: sa.client_email, private_key: sa.private_key }));
      CacheService.getScriptCache().remove('CONNECT_OAUTH');
    }
    if (input.client_json !== undefined) {
      var cj = parseJson_(input.client_json, null);
      if (input.client_json && (!cj || !(cj.android || cj.web))) throw new Error('Config klien Firebase harus berisi objek "android" dan/atau "web".');
      p.setProperty('FIREBASE_CLIENT_JSON', input.client_json ? JSON.stringify(cj) : '');
    }
    if (input.db_url !== undefined) {
      var u = String(input.db_url || '').trim().replace(/\/+$/, '');
      if (u && !/^https:\/\/[a-z0-9-]+(\.[a-z0-9-]+)*\.(firebaseio\.com|firebasedatabase\.app)$/.test(u)) throw new Error('URL Realtime Database tidak valid.');
      p.setProperty('FIREBASE_DB_URL', u);
    }
    ['apk_url', 'pwa_url'].forEach(function (f) {
      if (input[f] === undefined) return;
      var v = String(input[f] || '').trim();
      if (v && !/^https:\/\//.test(v)) throw new Error('Link harus diawali https://');
      p.setProperty(f === 'apk_url' ? 'CONNECT_APK_URL' : 'CONNECT_PWA_URL', v);
    });
    if (input.app_version !== undefined) p.setProperty('CONNECT_APP_VERSION', cap_(input.app_version, 20));
    return adminConnectSettingsGet(token);
  });
}
