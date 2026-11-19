# CarterTag Connect

App komunikasi lapangan driver & panitia CarterTag di hari konser. Jalan **dengan atau tanpa internet**:

- Ada sinyal → pesan lewat Firebase Realtime Database (gratis, paket Spark).
- Sinyal mati → pesan lompat antar-HP Android lewat Bluetooth LE (mesh, maks 5 lompatan).
- HP yang dapat sinyal otomatis jadi **gateway**: pesan mesh diteruskan ke internet, dan sebaliknya.
- iPhone memakai web app (PWA). Tanpa internet, iPhone ikut lewat **Mode Jembatan** (Wi-Fi Direct HP Android tim).

Dokumen acuan: [PRD-Sistem-CarterTag-Connect.md](PRD-Sistem-CarterTag-Connect.md), [PRD-UIUX-CarterTag-Connect.md](PRD-UIUX-CarterTag-Connect.md).

## Isi repo

| Folder | Isi |
|---|---|
| `app/` | Flutter (Android + Web). Kode Dart di `app/lib`, modul mesh native di `app/android/app/src/main/kotlin/id/cartertag/connect/mesh` |
| `gas/` | `Connect.gs` (API app + API Console) dan `connect_admin.html` (menu Tim Lapangan). Sudah disalin ke `cartertag new/sistem` |
| `firebase/` | `database.rules.json` (security rules). `firebase.json` & `.firebaserc` ada di root repo (project `cartertag-connect`, hosting `https://cartertag-connect.web.app`) |

## Setup sekali

### 1. Firebase (gratis, paket Spark)

1. Buka console.firebase.google.com → **Add project** → nama `cartertag-connect` (Google Analytics boleh dimatikan).
2. **Build → Realtime Database → Create database** → lokasi **Singapore (asia-southeast1)** → mode **locked**.
3. **Build → Authentication → Get started** (tidak perlu mengaktifkan provider apa pun; app login pakai custom token dari GAS).
4. **Project settings → General → Your apps**:
   - Tambah app **Android**, package name `id.cartertag.connect`. Tidak perlu unduh `google-services.json`.
   - Tambah app **Web**, nama `CarterTag Connect`.
   - Catat nilai `apiKey`, `appId`, `messagingSenderId`, `projectId`, `authDomain` dari kedua app.
5. **Project settings → Cloud Messaging → Web Push certificates → Generate key pair**. Catat `vapidKey`.
6. **Project settings → Service accounts → Generate new private key** (file JSON). Simpan baik-baik, jangan dibagikan.
7. Pasang rules: install Firebase CLI (`npm i -g firebase-tools`), lalu dari root repo:
   ```
   firebase login
   firebase deploy --only database
   ```

### 2. CarterTag System (GAS)

File sudah disalin ke `cartertag new/sistem`: `Connect.gs`, `connect_admin.html`, plus 4 perubahan kecil (route `?api=connect` di `doPost` Code.gs, menu `timlapangan` di Access.gs & admin.html).

1. Dari folder `cartertag new/sistem`: `clasp push`.
2. Di editor Apps Script: **Deploy → Manage deployments → Edit → Version: New version → Deploy** (URL `/exec` tetap).
3. Buka Console → menu **Tim Lapangan** → **Pengaturan Firebase & App** (superadmin):
   - Tempel isi JSON service account.
   - URL Realtime Database (mis. `https://cartertag-connect-default-rtdb.asia-southeast1.firebasedatabase.app`).
   - Config klien:
     ```json
     {
       "android": { "apiKey": "…", "appId": "1:…:android:…", "messagingSenderId": "…", "projectId": "cartertag-connect" },
       "web": { "apiKey": "…", "appId": "1:…:web:…", "messagingSenderId": "…", "projectId": "cartertag-connect", "authDomain": "cartertag-connect.firebaseapp.com" },
       "vapidKey": "…"
     }
     ```
   - Link APK, link PWA, versi app.
4. Beri izin menu **Tim Lapangan (Connect)** ke role yang perlu (menu Pengguna & Role).

### 3. Build app

Flutter SDK ada di `C:\src\flutter` (tambahkan `C:\src\flutter\bin` ke PATH supaya bisa memanggil `flutter` langsung).

```
cd app
flutter pub get

# Android (URL exec GAS ditanam supaya driver tidak perlu mengetik)
flutter build apk --release --split-per-abi --dart-define=CONNECT_API=https://script.google.com/macros/s/XXXX/exec

# Web / PWA (iPhone). --no-web-resources-cdn supaya tidak butuh CDN Google saat dibuka lewat jembatan offline
flutter build web --release --no-web-resources-cdn --dart-define=CONNECT_API=https://script.google.com/macros/s/XXXX/exec

# Salin build web ke APK untuk Mode Jembatan, lalu build APK sekali lagi
robocopy build\web android\app\src\main\assets\bridge_web /MIR

# Hosting PWA (dari root repo)
firebase deploy --only hosting
```

APK ada di `app/build/app/outputs/flutter-apk/` (`app-arm64-v8a-release.apk` untuk hampir semua HP Android). Unggah ke Google Drive, isi linknya di Console → Distribusi App.

> **Signing rilis (mulai 1.3.0):** APK ditandatangani keystore permanen `C:\Users\<user>\.cartertag\cartertag-release.jks` (password di `key.properties` di folder yang sama, disalin ke `app/android/key.properties` yang di-ignore Git). **Backup kedua file itu ke tempat aman** (mis. Google Drive pribadi). Kalau hilang, update app tidak bisa dipasang di atas versi lama; semua HP harus uninstall dulu. Sidik jari SHA-256 kunci ini ada di `app/web/.well-known/assetlinks.json` (untuk link gabung).

## Alur pakai hari H

1. Admin: Console → **Tim Lapangan** → pilih konser. Dua kode sudah ada otomatis: **Kode Driver** dan **Kode Koordinator**. Bagikan saat briefing.
2. H-1 (masih ada sinyal): install APK, buka app, isi **nama + kode** (+ nomor mobil untuk driver, nomor HP opsional) → langsung masuk. Tidak perlu didaftarkan di admin.
3. Hari H: chat, pesan cepat, status armada, centang penumpang, SOS. Saat sinyal hilang, status di header berubah ke **Tanpa internet · n HP tim terdekat** dan pesan tetap jalan.
4. iPhone: buka https://cartertag-connect.web.app saat online. Saat offline, minta HP Android tim membuka **Saya → Mode Jembatan**, scan 2 QR-nya.
## Uji lapangan (wajib sebelum konser pertama)

Lihat PRD Sistem §12.5. Minimal: 5 HP Android mode pesawat + Bluetooth nyala, berjajar ±20 m. Pesan ujung ke ujung harus sampai ≤ 15 detik. Lalu nyalakan data di 1 HP saja dan cek pesan muncul di Console → Monitor.

## Catatan implementasi vs PRD

| PRD | Implementasi | Alasan |
|---|---|---|
| drift (SQLite) | sembast | Tanpa code generation, satu API untuk Android & web |
| XChaCha20-Poly1305 | AES-256-GCM | Tersedia di WebCrypto browser & Dart; keamanan setara untuk volume pesan ini |
| `flutterfire configure` | Opsi Firebase dikirim GAS saat gabung | Satu APK bisa dipakai tanpa build ulang saat project Firebase diganti |
| Gateway di Kotlin | Gateway di Dart (saat app berjalan) | Saat app ditutup, pesan mesh tetap diteruskan antar-HP oleh service Kotlin; upload ke internet terjadi begitu app dibuka/online |
| Foto & voice offline lewat Wi-Fi Direct antar-Android | Foto & voice butuh internet | Transfer bulk Wi-Fi Direct antar-Android belum dibuat; teks, status, SOS, absen tetap jalan offline |
| Telepon dua arah | Push-to-talk (voice ≤ 15 dtk, putar otomatis di mode walkie) | Sesuai PRD (§2 di luar scope) |
| Bahasa ID + EN | Indonesia saja | Teks EN belum dibuat |
