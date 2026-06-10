# Syncs web/pkg/ (the flutter_rust_bridge wasm bundle that RustLib.init()
# loads on Flutter Web) with the fula_client version resolved in
# pubspec.lock. Run after every fula_client bump, then commit web/pkg/.
#
#   powershell -ExecutionPolicy Bypass -File tools\sync-wasm-pkg.ps1
#
# The bundle is the fula-api release asset flutter-wasm-pkg.zip
# (wasm-pack --target no-modules of crates/fula-flutter), produced by the
# same CI run that publishes the pub.dev package, so the rustContentHash
# embedded in the wasm matches the package's Dart bindings. The deploy
# workflow fails if web/pkg/VERSION != the pubspec.lock version.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$lockPath = Join-Path $repoRoot 'pubspec.lock'
$lock = Get-Content $lockPath -Raw

if ($lock -notmatch '(?ms)^  fula_client:\r?\n.*?version: "([^"]+)"') {
    throw "fula_client entry not found in $lockPath"
}
$version = $Matches[1]

$pubspec = Get-Content (Join-Path $repoRoot 'pubspec.yaml') -Raw
if ($pubspec -match '(?ms)^dependency_overrides:.*?fula_client:\s*\r?\n\s+path:') {
    Write-Warning "pubspec.yaml overrides fula_client to a local path - web/pkg/ should be built from that tree with wasm-pack, not downloaded. Continuing anyway."
}

$url = "https://github.com/functionland/fula-api/releases/download/v$version/flutter-wasm-pkg.zip"
$tmp = Join-Path $env:TEMP "fula-flutter-wasm-$version"
$zip = "$tmp.zip"

Write-Host "fula_client $version -> $url"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $tmp -Force

# The zip wraps everything in a flutter-wasm-pkg/ folder.
$src = Join-Path $tmp 'flutter-wasm-pkg'
if (-not (Test-Path $src)) { $src = $tmp }
foreach ($name in @('fula_flutter.js', 'fula_flutter_bg.wasm', 'VERSION')) {
    $file = Join-Path $src $name
    if (-not (Test-Path $file)) { throw "expected $name in release zip, not found under $src" }
}

$dst = Join-Path $repoRoot 'web\pkg'
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item (Join-Path $src 'fula_flutter.js'), (Join-Path $src 'fula_flutter_bg.wasm'), (Join-Path $src 'VERSION') $dst -Force

Remove-Item $zip -Force
Remove-Item $tmp -Recurse -Force

$stamped = (Get-Content (Join-Path $dst 'VERSION') -Raw).Trim()
Write-Host "web/pkg/ updated: fula_flutter.js + fula_flutter_bg.wasm (VERSION $stamped)"
if ($stamped -ne $version) {
    Write-Warning "VERSION stamp ($stamped) != pubspec.lock version ($version)"
}
