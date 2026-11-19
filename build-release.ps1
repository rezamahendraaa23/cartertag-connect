# Build rilis CarterTag Connect: web (PWA) -> salin ke aset APK (Mode Jembatan) -> APK per ABI.
# Pakai:  powershell -ExecutionPolicy Bypass -File build-release.ps1 -Api "https://script.google.com/macros/s/XXXX/exec"
param(
  [Parameter(Mandatory = $true)][string]$Api,
  [string]$Flutter = "C:\src\flutter\bin\flutter.bat"
)
$ErrorActionPreference = 'Stop'
if ($Api -notmatch '^https://script\.google\.com/macros/s/[^/]+/exec$') { throw "URL -Api harus berbentuk https://script.google.com/macros/s/<id>/exec" }

$app = Join-Path $PSScriptRoot 'app'
Push-Location $app
try {
  & $Flutter pub get
  if ($LASTEXITCODE) { throw 'pub get gagal' }

  # 1. Web / PWA. Tanpa CDN supaya bisa dibuka offline lewat jembatan.
  & $Flutter build web --release --no-web-resources-cdn "--dart-define=CONNECT_API=$Api"
  if ($LASTEXITCODE) { throw 'build web gagal' }

  # 2. Salinan ramping untuk aset APK (Safari iPhone hanya butuh canvaskit standar, tanpa varian chromium/skwasm/peta debug)
  $dst = Join-Path $app 'android\app\src\main\assets\bridge_web'
  if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
  New-Item -ItemType Directory -Force $dst | Out-Null
  $src = Join-Path $app 'build\web'
  Get-ChildItem $src -File | Where-Object { $_.Extension -ne '.map' } | Copy-Item -Destination $dst
  Copy-Item (Join-Path $src 'assets') $dst -Recurse
  Copy-Item (Join-Path $src 'icons') $dst -Recurse
  New-Item -ItemType Directory -Force (Join-Path $dst 'canvaskit') | Out-Null
  Copy-Item (Join-Path $src 'canvaskit\canvaskit.js'), (Join-Path $src 'canvaskit\canvaskit.wasm') (Join-Path $dst 'canvaskit')
  Remove-Item (Join-Path $dst 'assets\NOTICES') -ErrorAction SilentlyContinue
  $mb = [math]::Round(((Get-ChildItem $dst -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
  Write-Host "Aset jembatan: $mb MB"

  # 3. APK per ABI (arm64-v8a untuk hampir semua HP Android modern)
  & $Flutter build apk --release --split-per-abi "--dart-define=CONNECT_API=$Api"
  if ($LASTEXITCODE) { throw 'build apk gagal' }

  Write-Host ''
  Write-Host 'Selesai:'
  Get-ChildItem (Join-Path $app 'build\app\outputs\flutter-apk') -Filter '*-release.apk' | ForEach-Object { Write-Host ("  {0}  ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB)) }
  Write-Host "  Web: $src  ->  firebase deploy --only hosting (dari folder firebase)"
}
finally { Pop-Location }
