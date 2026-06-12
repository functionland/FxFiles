# P0 perf-baseline runner for docs/web-listing-prefetch-cache-plan.md.
#
# Serves nothing itself — point it at an already-running static server
# hosting a build made with:
#   flutter build web --release -t lib/main_web.dart `
#     --dart-define=E2E=true --dart-define=PERF=true --pwa-strategy=none
#
# Normal profile:
#   .\tools\web-perf-run.ps1 -Port 8902 -Seed "<24 words>"
# Low-end profile (§8.1: CPU-throttled via CDP Emulation.setCPUThrottlingRate;
# the DevTools websocket must stay open for the override to hold):
#   .\tools\web-perf-run.ps1 -Port 8902 -Seed "<24 words>" -ThrottleRate 5
param(
    [int]$Port = 8902,
    [Parameter(Mandatory = $true)][string]$Seed,
    [double]$ThrottleRate = 0,
    [int]$TimeoutSec = 240,
    [string]$Mode = "perf",
    [string]$Chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
)

$seedEnc = [uri]::EscapeDataString($Seed)
$url = "http://localhost:$Port/?e2e=$Mode&seed=$seedEnc"
$profileDir = "$env:TEMP\fx-perf-$(Get-Random)"
$errFile = "$env:TEMP\fx-perf-stderr-$(Get-Random).txt"
$dbgPort = 9333

$chromeArgs = @(
    "--headless=new", "--disable-gpu", "--enable-logging=stderr", "--v=0",
    "--enable-precise-memory-info",
    "--user-data-dir=$profileDir", "--window-size=1280,900"
)
if ($ThrottleRate -gt 0) {
    # Start on about:blank, throttle the target over CDP, then navigate.
    $chromeArgs += "--remote-debugging-port=$dbgPort"
    $chromeArgs += "about:blank"
} else {
    $chromeArgs += $url
}

$proc = Start-Process $Chrome -ArgumentList $chromeArgs -PassThru `
    -RedirectStandardError $errFile -WindowStyle Hidden

$ws = $null
try {
    if ($ThrottleRate -gt 0) {
        Start-Sleep -Seconds 3
        $targets = Invoke-RestMethod "http://localhost:$dbgPort/json/list"
        $page = $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
        if ($null -eq $page) { throw "No page target on CDP port $dbgPort" }

        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ct = [System.Threading.CancellationToken]::None
        $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).GetAwaiter().GetResult()

        function Send-Cdp([hashtable]$msg) {
            $json = $msg | ConvertTo-Json -Compress -Depth 5
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $seg = [System.ArraySegment[byte]]::new($bytes)
            $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text,
                $true, $ct).GetAwaiter().GetResult()
            $buf = [System.ArraySegment[byte]]::new((New-Object byte[] 16384))
            $null = $ws.ReceiveAsync($buf, $ct).GetAwaiter().GetResult()
        }

        Send-Cdp @{ id = 1; method = 'Emulation.setCPUThrottlingRate'; params = @{ rate = $ThrottleRate } }
        Send-Cdp @{ id = 2; method = 'Page.navigate'; params = @{ url = $url } }
        Write-Output "# throttle=$($ThrottleRate)x applied via CDP"
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if ((Test-Path $errFile) -and
            (Select-String -Path $errFile -Pattern 'E2E DONE' -Quiet)) { break }
    }
} finally {
    if ($null -ne $ws) { try { $ws.Dispose() } catch {} }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -Confirm:$false }
}

Get-Content $errFile |
    Select-String -Pattern '\[e2e\]|\[perf\]' |
    ForEach-Object { ($_.Line -split '"')[1] }
Remove-Item $profileDir -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
