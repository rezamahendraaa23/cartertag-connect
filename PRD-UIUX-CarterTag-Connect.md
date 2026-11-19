# PRD UI/UX — CarterTag Connect

> Untuk Claude Design. Fitur, role, dan aturan bisnis mengacu ke `PRD-Sistem-CarterTag-Connect.md` (kode fitur F#/M# di bawah merujuk ke sana).
> Dasar keputusan desain: skill **ui-ux-pro-max** (urutan prioritas: Accessibility → Touch → Performance → Style → Layout → Typography & Color → Animation → Forms → Navigation) + design system CarterTag System yang sudah ada.

---

## 1. Ringkasan Produk & Target Role

App chat lapangan untuk hari konser: driver dan panitia tetap bisa saling kirim pesan saat sinyal hilang.

| Role | Konteks pemakaian | Layar paling sering |
|---|---|---|
| **Driver** | Di dalam mobil / parkiran, satu tangan, sering di bawah terik matahari atau malam gelap, sambil menunggu | Pesan cepat, Chat area, Manifest, Status armada |
| **Panitia** | Berdiri di gerbang/titik kumpul, kerumunan, berisik | Chat grup, DM, Radar, SOS |
| **Koordinator** | Berpindah-pindah, butuh gambaran semua mobil | Papan Armada, Pengumuman, Absen, Chat |
| **Admin Console** | Desktop di kantor/posko, online | Menu Tim Lapangan di CarterTag Console |

**Prinsip desain turunan dari konteks**
1. **Terbaca di luar ruangan**: kontras tinggi, teks dasar 16sp, tanpa abu-abu tipis di atas abu-abu.
2. **Satu tangan**: aksi utama di sepertiga bawah layar, target sentuh ≥ 48dp.
3. **Status koneksi selalu jujur**: user harus selalu tahu pesannya lewat internet, mesh, atau masih menunggu.
4. **Darurat tidak boleh tertekan tak sengaja, tapi harus selalu terjangkau.**

---

## 2. Design System

### 2.1 Arah gaya

Hasil ui-ux-pro-max:
- Domain `product` "Chat & Messaging App" → **Minimalism + micro-interactions**, fokus pada kontras gelembung pengirim/penerima.
- Domain `style` "Neubrutalism" → border hitam tebal, bayangan keras tanpa blur, warna datar. Wajib kontras 4.5:1, focus terlihat, dan reduced-motion.

**Keputusan: hibrida.** Kerangka app (top bar, tombol, kartu, sheet, papan armada, SOS) memakai **Neobrutalism CarterTag**, supaya konsisten dengan CarterTag System. **Area isi chat dibuat lebih tenang**: gelembung border 2px **tanpa** bayangan keras. Kalau ratusan gelembung masing-masing punya shadow 4px, layar jadi bising dan scroll lebih berat.

### 2.2 Token warna (diambil dari tema Neobrutalism `admin.html`)

| Token | Terang | Gelap | Pemakaian |
|---|---|---|---|
| `bg` | `#FFFBF2` | `#12141A` | Latar layar |
| `card` | `#FFFFFF` | `#1C1F27` | Kartu, sheet, gelembung penerima |
| `card-low` | `#F6F3EA` | `#171A21` | Input, area sekunder |
| `ink` / `line` | `#0B0B0F` | `#F2EEE2` | Border tebal, shadow keras, teks utama |
| `muted` | `#4E4D46` | `#BDB9AD` | Waktu, meta (bukan teks utama) |
| `accent` | `#1D5DAA` | `#5CB8F0` | Tombol primary, gelembung saya, tab aktif, link |
| `on-accent` | `#FFFFFF` | `#0B0B0F` | Teks di atas accent |
| `accent-bg` | `#DCEEFC` | `#143049` | Chip info, sorotan reply |
| `ok` / `ok-bg` | `#0A6B3A` / `#B9F0CF` | `#4ADE80` / `#123A24` | Online, Aman, Naik, Tiba |
| `amber` / `amber-bg` | `#6B4100` / `#FFE27A` | `#FFD84A` / `#3A3110` | Mesh, menunggu, belum jawab, tidak ada kabar |
| `danger` / `danger-bg` | `#B3261E` / `#FFC7C7` | `#FF8A8A` / `#40191B` | **Khusus SOS & kendala**, tidak dipakai untuk hal lain |

Kontras yang sudah dihitung: `#1D5DAA` vs putih **6,6:1** · `#B3261E` vs putih **6,5:1** · `#6B4100` vs `#FFE27A` **6,9:1** · `#0B0B0F` vs `#FFFBF2` **19:1**. Semua ≥ 4.5:1.

**Tema:** ikut sistem (default), bisa dipaksa Terang/Gelap di Pengaturan. Di venue malam hari, tema gelap mencegah silau. Jangan pernah pakai `#1D5DAA` sebagai teks di tema gelap, pakai `#5CB8F0`.

**Aturan warna:** status **tidak pernah hanya warna**. Selalu warna + ikon + teks (contoh: ikon awan + "Online"), sesuai aturan ui-ux-pro-max "Color Only".

### 2.3 Tipografi

| Gaya | Font | Ukuran / tinggi baris | Pemakaian |
|---|---|---|---|
| Display | Space Grotesk 700 | 28/34 | Judul onboarding, angka besar SOS/kompas |
| Title | Space Grotesk 700 | 20/26 | Judul layar |
| Subtitle | Space Grotesk 600 | 17/24 | Nama channel, nama di kartu |
| Body | Space Grotesk 400 | **16/24** | Teks chat (bisa diperbesar ke 18/20 di Pengaturan) |
| Label | Space Grotesk 600 | 14/20 | Tombol, chip |
| Meta | JetBrains Mono 500 | 12/16 | Jam pesan, jarak, baterai |
| Data | JetBrains Mono 600 | 14–28 | Plat nomor, nomor mobil, Order ID, kode konser `CT-7KQ4MX` |

Tidak ada teks isi < 12sp. Dukung skala font sistem sampai 200% tanpa terpotong.

### 2.4 Bentuk, spasi, efek
- Border: 2.5px `ink` untuk kartu & tombol, 2px untuk gelembung & input.
- Shadow keras: `4px 4px 0 ink` (kartu/tombol). Tombol ditekan → bergeser 4px dan shadow hilang (efek "ditekan" CarterTag), 100ms.
- Radius: 12 (kartu), 999 (tombol pil, chip), 18 (gelembung, dengan sudut ekor 6).
- Spasi kelipatan 4: 4/8/12/16/24/32. Jarak antar target sentuh ≥ 8dp.
- Ikon: **Lucide** (SVG, stroke 2px). Tanpa emoji sebagai ikon.
- Logo: `https://raw.githubusercontent.com/rezamahendraaa23/logocartertag/refs/heads/main/cartertagnew.png` (PNG transparan bulat), di splash, onboarding, dan ikon app (adaptive icon latar `#1D5DAA`).

### 2.5 Gerak
- Durasi: 150ms (tap), 220ms (sheet/transisi layar), 300ms (banner koneksi). Masuk dengan ease-out, keluar lebih cepat (exit < enter).
- Gerak harus punya makna: pesan baru meluncur dari bawah. Status ✓ → ✓✓ memudar.
- `MediaQuery.disableAnimations` / reduced-motion → semua animasi jadi fade 0–100ms. **Pengecualian:** pulsa SOS diganti kedip warna statis 1 Hz (bukan animasi skala).

---

## 3. Daftar Halaman per Role

### 3.1 Android app & PWA (satu codebase)

| # | Halaman | Driver | Panitia | Koordinator | PWA |
|---|---|:-:|:-:|:-:|:-:|
| S01 | Splash | ✅ | ✅ | ✅ | ✅ |
| S02 | Selamat datang + pilih bahasa | ✅ | ✅ | ✅ | ✅ |
| S03 | Penjelasan izin (step per izin) | ✅ | ✅ | ✅ | Notifikasi saja |
| S04 | Gabung: nama, HP, kode konser | ✅ | ✅ | ✅ | ✅ |
| S05 | Konfirmasi peran & mobil | ✅ | ✅ | ✅ | ✅ |
| S06 | Gabung via QR (scan) | ✅ | ✅ | ✅ | ✅ |
| S07 | **Chat** — daftar channel & DM (tab 1) | ✅ | ✅ | ✅ | ✅ |
| S08 | Ruang chat | ✅ | ✅ | ✅ | ✅ |
| S09 | Info pesan (status per penerima) | ✅ | ✅ | ✅ | ✅ |
| S10 | Anggota & mulai DM | ✅ | ✅ | ✅ | ✅ |
| S11 | Sheet pesan cepat | ✅ | ✅ | ✅ | ✅ |
| S12 | Push-to-talk (overlay) | ✅ | ✅ | ✅ | — |
| S13 | **Armada** — papan armada (tab 2) | Area sendiri | ✅ | ✅ | ✅ |
| S14 | Mobil saya: status perjalanan + manifest | ✅ | — | Detail mobil mana pun | ✅ |
| S15 | Detail penumpang | ✅ | Tanpa WA | ✅ | ✅ |
| S16 | **Radar** — radar anggota (tab 3) | ✅ | ✅ | ✅ | Online saja |
| S17 | Kompas ke anggota/SOS | ✅ | ✅ | ✅ | Online saja |
| S18 | **Info** — pengumuman + absen (tab 4) | ✅ | ✅ | ✅ | ✅ |
| S19 | Buat pengumuman | — | — | ✅ | ✅ |
| S20 | Absen: mulai & rekap | Jawab | Jawab | Mulai + rekap | ✅ |
| S21 | Kirim SOS (tahan) | ✅ | ✅ | ✅ | ✅ |
| S22 | SOS masuk (full-screen) | ✅ | ✅ | ✅ | ✅ (dalam tab) |
| S23 | SOS aktif saya (pengirim) | ✅ | ✅ | ✅ | ✅ |
| S24 | **Saya** — profil & pengaturan (tab 5) | ✅ | ✅ | ✅ | ✅ |
| S25 | Detail koneksi (peer, gateway, antrean) | ✅ | ✅ | ✅ | Ringkas |
| S26 | Undang via QR (tampilkan) | ✅ | ✅ | ✅ | — |
| S27 | Mode Jembatan iPhone (host) | ✅ | ✅ | ✅ | — |
| S28 | Panduan jembatan (klien iPhone) | — | — | — | ✅ |
| S29 | Ganti konser / keluar konser | ✅ | ✅ | ✅ | ✅ |
| S30 | Update tersedia (banner + layar) | ✅ | ✅ | ✅ | — |

### 3.2 CarterTag Console — menu "Tim Lapangan" (web desktop)

| # | Halaman | Isi |
|---|---|---|
| C01 | Tim Lapangan · Pengaturan | Toggle Connect, kode konser besar + Salin + Reset, "Hanya nomor terdaftar", manifest ON/OFF + sumber |
| C02 | Anggota | Tabel driver (dari Mobil) + panitia, role, status gabung, terakhir terlihat. Tambah panitia, set Koordinator, Keluarkan |
| C03 | Monitor | Strip KPI + papan armada + SOS aktif (auto-refresh 10 dtk) |
| C04 | Pengumuman | Kirim pengumuman + daftar terkirim & tanda terima |
| C05 | Manifest | Sumber aktif, upload CSV/XLSX, pratinjau validasi, unduh template |
| C06 | Distribusi App | Link APK + QR halaman unduh + link PWA + versi terbaru |

Console mengikuti layout CarterTag Console yang sudah ada (sidebar grup Operasional/Katalog/Pengaturan, Neobrutalism). Menu "Tim Lapangan" masuk grup **Operasional**.

---

## 4. Detail per Halaman

Format tiap halaman: **Komponen** · **Layout** · **State** · **Interaksi**.

### Komponen global yang menempel di semua layar utama
- **Top bar**: logo kecil + nama konser (1 baris, terpotong …) · **Pil koneksi** (lihat K01) · tombol **SOS** (K02).
- **Bottom nav 5 tab** (batas ≤ 5 sesuai ui-ux-pro-max): Chat · Armada · Radar · Info · Saya. Ikon + label teks selalu tampil. Badge angka belum dibaca (tab Info: titik merah kalau ada absen belum dijawab).
- **Banner koneksi** di bawah top bar kalau status bukan Online (bisa diciutkan, tidak bisa ditutup permanen).

### S04 — Gabung
- **Komponen**: logo, judul "Gabung tim konser", 3 field berlabel di atas field (Nama · Nomor HP · Kode konser), helper text di bawah tiap field, tombol primary "Gabung", link "Punya QR undangan? Scan".
- **Layout**: satu kolom, tombol primary menempel di atas keyboard.
- **Field kode**: JetBrains Mono 24, auto-uppercase, prefix tetap `CT-`, 6 kotak karakter, bisa paste.
- **Field HP**: `keyboardType: phone`, auto-format `0812-3456-7890`, menerima `+62`.
- **State**: idle → validasi inline saat blur (error di bawah field, ikon + teks merah) → loading (tombol jadi "Menghubungkan…" + spinner, field dikunci) → sukses (ke S05) → error server spesifik: "Kode tidak ditemukan", "Nomor belum terdaftar di konser ini — hubungi koordinator", "Terlalu banyak percobaan, coba lagi 9:42" (hitung mundur) → offline: kartu amber "Butuh internet sekali untuk gabung. Atau minta QR undangan ke teman tim" + tombol Scan QR.
- **Aksesibilitas**: label terlihat (bukan placeholder saja), urutan fokus Nama → HP → Kode → Gabung, error diumumkan screen reader (live region).

### S05 — Konfirmasi peran & mobil
- Kartu Neobrutalism: "Kamu terdaftar sebagai **Driver** · Mobil **03** · `B 1234 CTG` · Area **Bekasi**". Kalau datanya salah: link "Bukan saya? Hubungi koordinator".
- Tombol "Masuk". Di belakang layar: progres unduh (roster, manifest) dengan label "Menyiapkan data offline… 3/4".
- State gagal unduh sebagian: tetap boleh masuk, banner "Manifest belum terunduh, coba lagi saat online".

### S07 — Daftar Chat
- **Layout**: daftar dengan seksi **Pengumuman terbaru** (1 kartu pinned, ringkas) → **Grup** (Grup Konser, Area X, Koordinator) → **Pesan pribadi**.
- **Baris**: avatar inisial (lingkaran border 2px, warna dari hash nama, tanpa foto) · nama channel 17sp · potongan pesan terakhir 1 baris · jam (Mono) · badge belum dibaca (pil accent) · ikon status jalur pesan terakhir.
- **FAB** "Pesan baru" (ikon pensil + label) kanan bawah, di atas bottom nav.
- **State**: kosong ("Belum ada pesan. Sapa timmu di Grup Konser" + tombol), loading skeleton 6 baris, offline tetap tampil penuh (data lokal).

### S08 — Ruang Chat (layar terpenting)
- **Header**: kembali · nama channel + subjudul ("40 anggota · 12 terjangkau") · ikon info.
- **Daftar pesan**: `ListView.builder` terbalik (lazy, sesuai ui-ux-pro-max Flutter "Use ListView.builder"). Pemisah tanggal. Nama pengirim di atas gelembung (grup saja), dengan chip role kecil (`Driver 03`, `Koordinator`).
- **Gelembung saya**: latar `accent`, teks `on-accent`, kanan. **Gelembung orang**: latar `card`, border 2px `ink`, kiri. Lebar maks 78%.
- **Meta di bawah teks** (Mono 12): jam · ikon jalur (awan = online, ikon jaringan-titik = mesh, ikon tautan = jembatan) · status: jam pasir *Antre* → ✓ *Terkirim* → ✓✓ *Sampai* → ✓✓ isi accent *Dibaca*. Ikon selalu disertai `semanticsLabel` ("Terkirim lewat mesh, sampai ke 8 dari 12").
- **Pesan antre**: gelembung dengan border putus-putus + teks "Menunggu jalur…". Tekan lama → "Coba sekarang / Hapus".
- **Pesan khusus**: status armada (kartu kecil berikon mobil: "Mobil 03 · Berangkat · 18:42"), pengumuman (kartu kuning amber-bg), SOS (kartu merah, tombol "Lihat lokasi").
- **Composer** (bawah, menempel di atas keyboard): tombol **Pesan cepat** (ikon Lucide `zap`) (kiri, ikon + label "Cepat" di layar ≥ 360dp) · field teks multi-baris (maks 5 baris, counter muncul setelah 800/1000) · lampiran (foto, voice) · kirim. Tombol kirim berubah jadi **mic** saat field kosong (tahan = voice note, atau PTT kalau channel walkie).
- **Interaksi**: geser gelembung ke kanan = balas. Tekan lama = menu (Balas, Salin, Info, Hapus untuk saya). Haptic hanya untuk kirim berhasil & PTT (jangan setiap tap).
- **State**: memuat riwayat lama (spinner kecil di atas), media mengunggah (progress ring di thumbnail), media "menunggu online" (ikon awan coret + teks).

### S11 — Pesan cepat (bottom sheet)
- Grid 2 kolom tombol besar (≥ 64dp tinggi), ikon + teks. Driver: Sudah di titik jemput · Berangkat · Tiba di venue · Macet ±15 mnt · Penumpang kurang · Mobil bermasalah · Butuh bantuan. Panitia: Saya di gerbang · Penumpang sudah dikumpulkan · Menuju parkiran · Butuh bantuan.
- Tap = langsung kirim + toast "Terkirim ke Area Bekasi" dengan tombol **Urungkan** 5 detik. Tombol yang juga mengubah status armada diberi label kecil "+ update status".

### S12 — Push-to-talk
- Overlay saat tombol mic ditahan di channel walkie: lingkaran besar accent dengan hitung mundur 15 → 0 (Mono 28), bentuk gelombang level suara, teks "Geser ke kiri untuk batal".
- Lepas = kirim. Kalau hanya ada jalur BLE: toast "Dikirim sebagai voice note (jalur lambat)".
- Penerima: voice masuk diputar otomatis + chip "Memutar dari Budi · Driver 03" di atas layar, tap untuk jeda.

### S13 — Papan Armada
- **Strip ringkasan** (stat card Neobrutalism, scroll horizontal di layar sempit): Total mobil · Berangkat · Tiba · **Kendala** (merah) · **Tidak ada kabar** (amber).
- **Filter chip**: Leg (Pergi/Pulang) · Area · Status.
- **Kartu mobil** (satu per mobil, urut: kendala → tidak ada kabar → lainnya): nomor mobil besar (Mono 24) + plat · nama driver · chip status (ikon + teks + warna) · "Naik 6/7" · terakhir terlihat "2 mnt lalu · mesh" · baterai driver (ikon + %). Tap → S14 (mode lihat).
- **State**: kosong ("Belum ada data mobil. Plotingan belum dibuat di Console"), data lama (label amber "Data 12 menit lalu, menunggu sinkron").

### S14 — Mobil Saya (driver)
- **Atas**: kartu besar "Mobil 03 · B 1234 CTG · Leg Pergi". Toggle Pergi/Pulang.
- **Stepper status** horizontal 6 langkah (Siap → Menuju → Di titik → Berangkat → Tiba → Selesai). Langkah sekarang diisi accent. **Satu tombol primary besar** di bawah (tinggi 56dp): label = langkah berikutnya ("Tandai: Berangkat"). Tombol sekunder "Lapor kendala" (outline danger).
- Setelah tap: toast "Status: Berangkat" + **Urungkan** 2 menit (sesuai aturan PRD Sistem §8.5).
- **Manifest** di bawahnya: header "Penumpang 6/7 naik" + progress bar. List per booking: nama (+ "dan 2 lainnya" kalau rombongan) · pax · titik kumpul · jam jemput (Mono). Kanan: dua tombol segmented **Naik** / **Tidak datang** (masing-masing ≥ 48dp, ikon + teks). Tap baris → S15.
- **Sumber data** di bawah list: "Sumber: Plotingan · diperbarui 19 Nov 10:12".
- **State**: manifest nonaktif untuk konser ini (kartu info, bukan error), belum terunduh (tombol "Unduh saat online").

### S15 — Detail Penumpang
- Nama, Order ID (Mono), pax, trip (PP/OW), area, **titik kumpul (alamat lengkap)**, jam jemput, catatan.
- Driver & Koordinator: tombol **Telepon** & **WhatsApp** (pakai sinyal kalau ada; offline → tombol disabled dengan teks "Butuh sinyal seluler").
- Panitia: nomor tidak ditampilkan sama sekali.

### S16 — Radar
- Lingkaran radar (cincin 25/50/100/200 m, label Mono) dengan "saya" di tengah, utara mengikuti kompas HP. Titik anggota berupa pin inisial + warna role. SOS = pin merah berkedip (statis kalau reduced-motion).
- Di bawah radar: daftar urut jarak: nama · jarak · arah ("156 m · Tenggara") · umur lokasi ("1 mnt" / "lama" amber). Tap → S17.
- Toggle "Bagikan lokasi saya" (default ON selama konser aktif) + teks privasi.
- **State**: GPS mati (kartu dengan tombol "Nyalakan lokasi"), kompas perlu kalibrasi (ilustrasi gerakan angka 8), belum ada lokasi anggota.

### S17 — Kompas ke anggota
- Panah besar (≥ 50% lebar layar) menunjuk arah target. Jarak Display 28 Mono. Akurasi "±12 m". Nama & umur lokasi.
- Getar pendek saat < 20 m. Tombol "Buka di Google Maps" (hanya aktif saat online).
- Layar tetap menyala (wakelock) selama halaman ini terbuka.

### S18 — Info (Pengumuman & Absen)
- **Absen aktif** (kalau ada) paling atas: kartu amber "Absen dari Koordinator — tandai kondisimu" + dua tombol besar **Aman** (ok) / **Butuh bantuan** (danger).
- **Pengumuman**: kartu pinned urut terbaru. Prioritas penting = border kiri tebal amber + ikon pin. Tampil judul, isi, pengirim, waktu. Koordinator melihat "Diterima 34/40 · Dibaca 28" (tap → daftar nama).
- Koordinator: FAB "Pengumuman" dan tombol "Mulai absen".

### S20 — Rekap Absen (koordinator)
- 3 stat card: Aman · Butuh bantuan · Belum jawab.
- Tab daftar per kelompok. "Butuh bantuan" di atas dengan tombol DM & Kompas. "Belum jawab" dengan terakhir terlihat.
- Tombol "Tutup absen" (konfirmasi dialog).

### S21–S23 — SOS
- **Tombol SOS (K02)** di top bar: pil merah "SOS" + ikon. Tap biasa → tooltip "Tahan 2 detik untuk kirim SOS". Tahan → layar S21.
- **S21**: lingkaran progres mengisi selama 2 detik (dengan getar mulai), teks "Tahan… lepas untuk batal". Setelah penuh: pilih jenis (Medis · Kendaraan · Keamanan · Lainnya) dengan **otomatis kirim "Lainnya" dalam 5 detik** kalau tidak dipilih.
- **S22 (penerima)**: full-screen merah `danger`, teks putih: "SOS · MEDIS", nama + role, jarak & arah (Display), baterai pengirim, waktu. Tombol: **Saya menuju** (putih, primary) · **Lihat kompas** · **Matikan alarm** (alarm berhenti, SOS tetap tercatat). Bunyi alarm + getar berulang.
- **S23 (pengirim)**: banner merah persisten di atas semua layar "SOS aktif · dikirim ulang tiap 30 dtk" + daftar responder ("Rina menuju · 80 m"). Tombol **Batalkan SOS** dengan konfirmasi.
- **Aksesibilitas**: alarm juga memicu kedip lampu kilat (opsional) untuk lingkungan bising. Teks SOS bisa dibaca screen reader dengan prioritas assertive.

### S24 — Saya (Profil & Pengaturan)
- Kartu profil (nama, role, mobil, konser aktif + "Ganti").
- Grup pengaturan: Tampilan (Tema, Ukuran teks) · Notifikasi (per channel, bunyi) · Koneksi (Mode hemat baterai, Detail koneksi → S25, Mode Jembatan → S27) · Undang via QR → S26 · Bahasa ID/EN · Privasi (Bagikan lokasi, Hapus data konser) · Versi app.

### S25 — Detail Koneksi
- Kartu status besar (sama dengan pil koneksi, versi lengkap).
- Bagian "Internet" (ya/tidak, gateway aktif?), "HP terdekat" (list: nama · BLE/Wi-Fi · perkiraan jarak dari RSSI · terakhir), "Antrean" (n pesan menunggu + tombol "Coba kirim sekarang").
- Untuk diagnosa lapangan: teks teknis boleh lebih banyak, tetap kontras penuh.

### S26 — Undang via QR (tampilkan)
- QR besar di kartu putih border tebal (tetap putih di tema gelap supaya bisa dipindai) + hitung mundur 15:00 + tombol "Buat ulang". Teks: "Minta temanmu install CarterTag Connect, lalu pilih *Scan QR undangan*".
- Kecerahan layar dinaikkan otomatis selama QR tampil.

### S27 — Mode Jembatan (host Android)
- Penjelasan 1 kalimat: "Bantu teman pakai iPhone ikut chat tanpa internet."
- Toggle "Aktifkan jembatan". Saat aktif: **Langkah 1** QR Wi-Fi (beserta nama jaringan & sandi dalam teks Mono, untuk diketik manual), **Langkah 2** QR alamat web. Daftar iPhone tersambung (maks 6) + permintaan masuk ("Izinkan Budi?" Tolak/Izinkan).
- Peringatan baterai: "Jembatan memakai baterai lebih banyak (±10%/jam)".

### S28 — Panduan Jembatan (PWA iPhone)
- Muncul saat PWA mendeteksi offline: "Tidak ada internet. Minta HP Android tim mengaktifkan **Mode Jembatan**, lalu scan 2 QR-nya pakai Kamera." Ilustrasi 2 langkah bernomor.
- Saat terhubung via jembatan: pil koneksi "Jembatan · via HP Rina".

### Console C01–C06 (desktop-first)
- **C01**: kartu kode konser dengan JetBrains Mono 40 "CT-7KQ4MX", tombol Salin, Tampilkan QR (untuk dipasang di briefing), **Reset kode** (dialog konfirmasi bahaya: "Semua anggota tetap masuk, tapi anggota yang dikeluarkan tidak bisa membaca pesan baru").
- **C02**: tabel dengan header sticky, filter role/status, cari nama/HP. Kolom: Nama · Role · Mobil · Status (chip) · Terakhir terlihat · Aksi. Tambah panitia via drawer kanan (pola Console yang ada).
- **C03**: strip KPI + grid kartu mobil (sama dengan S13) + panel SOS aktif di kanan (merah, paling atas). Penanda "diperbarui 8 dtk lalu".
- **C05**: area upload drag-and-drop + tombol pilih file, tabel pratinjau dengan baris error disorot (ikon + teks error di baris itu, bukan hanya di atas tabel), tombol "Simpan manifest" aktif hanya kalau 0 error.

---

## 5. User Flow / Navigasi

### 5.1 Pertama kali (driver, H-1 konser, masih ada sinyal)
```
Install APK (link/QR dari koordinator)
  → S01 Splash → S02 Bahasa → S03 Izin (Bluetooth → Perangkat sekitar → Lokasi → Notifikasi → Baterai)
  → S04 Gabung (nama, HP, CT-7KQ4MX) → S05 "Driver · Mobil 03" → [unduh data offline]
  → S07 Chat (Grup Konser terbuka dengan pesan sambutan)
```

### 5.2 Hari H — driver lapor (offline)
```
Notifikasi "Pengumuman: titik jemput pindah ke Gate 5" → S18
  → tab Armada → S14 Mobil Saya → "Tandai: Di titik jemput"
  → centang Naik per penumpang → "Tandai: Berangkat"
  → (pil koneksi: Mesh · 3 HP) → pesan & status menunggu gateway → otomatis tersinkron
```

### 5.3 Panitia cari penumpang yang hilang
```
S08 chat Area Bekasi "Penumpang a.n. Dina belum datang" → tap nama di manifest (S15)
  → DM driver (S08 DM) → tab Radar (S16) → S17 kompas ke driver
```

### 5.4 Darurat
```
Semua layar → tahan SOS 2 dtk → (pilih jenis) → S23 banner aktif
Penerima: notifikasi full-screen → S22 → "Saya menuju" → S17 kompas → sampai → pengirim "Batalkan SOS"
```

### 5.5 Teman pakai iPhone
```
Android: Saya → Mode Jembatan → aktifkan → tampil QR-1 & QR-2
iPhone: Kamera scan QR-1 (join Wi-Fi) → scan QR-2 (buka web) → isi HP → host "Izinkan" → S07
```

**Aturan navigasi (ui-ux-pro-max `ux`):**
- Tombol kembali sistem Android selalu bisa diprediksi: ruang chat → daftar chat → keluar app. Bukan menutup sheet sekaligus menutup layar.
- Deep link: notifikasi membuka layar tujuan langsung (`/chat/{id}`, `/sos/{id}`, `/info/{id}`, `/fleet/{car}`). Kembali dari sana mengarah ke tab induknya, bukan keluar app.
- Bottom nav tetap ada di 5 tab utama dan tersembunyi di layar detail (ruang chat, kompas, SOS).
- Posisi scroll & draf pesan per channel diingat.

---

## 6. Requirement Responsive

| Permukaan | Prioritas | Ketentuan |
|---|---|---|
| Android app | **Mobile-first** (360–430dp) | Layout satu kolom. Uji di 320dp (HP murah driver): tidak ada scroll horizontal kecuali strip stat card yang memang di-scroll. Safe area & gesture bar dihormati. Lanskap: ruang chat & radar tetap bisa dipakai. |
| PWA di iPhone | **Mobile-first** | `viewport-fit=cover`, safe area notch. Zoom tidak dimatikan. Composer naik di atas keyboard iOS (visualViewport). |
| PWA di laptop | Adaptif ≥ 900px | Dua panel: daftar chat kiri (360px) + ruang chat kanan. Bottom nav jadi rail kiri. |
| Console Tim Lapangan | **Desktop-first** | Ikut breakpoint Console yang ada (< 900px sidebar jadi drawer). Monitor tetap terbaca di tablet posko (768px, grid 2 kolom). |

---

## 7. Komponen Reusable

| ID | Komponen | Varian / catatan |
|---|---|---|
| K01 | **Pil koneksi** | Online (ok, ikon awan) · Mesh · n HP (amber, ikon jaringan) · Jembatan (accent, ikon tautan) · Terisolasi · x antre (abu tebal, ikon awan coret). Tap → S25. Selalu ikon + teks. |
| K02 | **Tombol SOS** | Pil merah top bar. State: normal, ditahan (progres), aktif (berkedip/statis). Label "SOS" selalu tampil. |
| K03 | **Gelembung pesan** | Saya / orang / sistem (status armada) / pengumuman / SOS / media / voice / antre. Satu widget dengan varian. |
| K04 | **Meta pesan** | Jam + jalur + status, Mono 12, `semanticsLabel` lengkap |
| K05 | **Composer** | Teks, pesan cepat, lampiran, kirim/mic/PTT |
| K06 | **Stat card** | Angka besar Mono + label + ikon, border tebal + shadow keras, varian warna status |
| K07 | **Kartu mobil** | Nomor, plat, driver, chip status, naik x/y, terakhir terlihat, baterai |
| K08 | **Chip status** | Armada (6 status + kendala), absen (Aman/Bantuan/Belum), member (aktif/diundang/dikeluarkan), selalu ikon + teks |
| K09 | **Stepper perjalanan** | 6 langkah + tombol aksi berikutnya + urungkan |
| K10 | **Baris manifest** | Nama, pax, titik, jam, segmented Naik/Tidak datang |
| K11 | **Bottom sheet** | Handle + judul + isi, tutup dengan geser/back |
| K12 | **Toast + Urungkan** | Bawah, di atas bottom nav, tidak menutupi composer, durasi 4–5 dtk (Urungkan status 2 mnt via tombol di S14) |
| K13 | **Dialog konfirmasi** | Judul, penjelasan dampak, tombol aksi berlabel jelas ("Batalkan SOS", bukan "OK"). Aksi bahaya di kanan, warna danger. |
| K14 | **Banner** | Info (accent-bg), peringatan (amber-bg), bahaya (danger-bg). Ikon + teks + aksi opsional. |
| K15 | **QR card** | Kartu putih border tebal + hitung mundur + teks cadangan Mono |
| K16 | **Avatar inisial** | Lingkaran border 2px, warna dari hash nama (palet 6 warna yang semuanya lolos kontras dengan teks hitam) |
| K17 | **Empty / error state** | Ikon Lucide + judul + 1 kalimat + 1 aksi |
| K18 | **Skeleton** | Daftar chat, kartu mobil, manifest. Tidak dipakai di data lokal yang instan. |
| K19 | **Field berlabel** | Label di atas, helper di bawah, error inline (ikon + teks), counter opsional |
| K20 | **Radar & kompas** | Canvas kustom, reduced-motion aware |

---

## 8. Checklist sebelum serah ke Claude Code (dari ui-ux-pro-max pro-rules)

- [ ] Semua tombol ikon punya label teks atau `semanticsLabel`. Tidak ada emoji sebagai ikon.
- [ ] Target sentuh ≥ 48dp (Android) / 44pt (iOS web), jarak ≥ 8dp.
- [ ] Kontras ≥ 4.5:1 di tema terang **dan** gelap, termasuk teks di atas accent & danger.
- [ ] Status tidak pernah hanya warna.
- [ ] Setiap aksi punya feedback ≤ 100ms (pressed state), dan aksi jaringan punya loading → sukses/gagal.
- [ ] Error form muncul di dekat field.
- [ ] Reduced motion dihormati, termasuk SOS & radar.
- [ ] Safe area (notch, gesture bar) dihormati di Android & iPhone PWA.
- [ ] Daftar panjang pakai builder/lazy (chat, manifest, anggota).
- [ ] Teks bisa diperbesar 200% tanpa terpotong di S04, S08, S14, S22.
