# ShareIT: share the current folder on the internet with a real link, until you close it.
#   irm https://dl.securytik.com/shareit.ps1 | iex
# Open source: https://github.com/mhdhaidarah/shareit
& {
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$NginxVersion = '1.28.0'
$Home2 = Join-Path $env:LOCALAPPDATA 'ShareIT'
$Folder = (Get-Location).ProviderPath

function Fail($m) { Write-Host "ShareIT: $m" -ForegroundColor Red }
# a closed window leaves its work folder behind: remove those whose window is gone
Get-ChildItem $Home2 -Filter 'run-*' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $o = Join-Path $_.FullName 'owner'
  $alive = (Test-Path $o) -and (Get-Process -Id ([int](Get-Content $o)) -ErrorAction SilentlyContinue)
  if (-not $alive) { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}
function Get-Cloudflared {
  New-Item -ItemType Directory -Force -Path $Home2 | Out-Null
  $exe = Join-Path $Home2 'cloudflared.exe'
  if (-not (Test-Path $exe)) {
    Write-Host 'Installing the Cloudflare tunnel program (first run only)...'
    Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $exe -UseBasicParsing
  }
  $exe
}
function Wait-Link($proc, $log) {
  Write-Host 'Creating your link...'
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    if ($proc.HasExited) { return $null }
    $t = try { [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite') } catch { $null }
    if ($t) { $r = New-Object IO.StreamReader($t); $txt = $r.ReadToEnd(); $r.Close(); $m = [regex]::Match($txt, 'https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com'); if ($m.Success) { return $m.Value } }
  }
  $null
}
function Wait-Live($u) {
  for ($i = 0; $i -lt 30; $i++) {
    try { Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 6 | Out-Null; return } catch {
      $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($code -and $code -notin 502, 503, 530) { return }
      Start-Sleep -Seconds 2
    }
  }
}
function Show-Link($u, $a, $b) {
  Write-Host ''
  Write-Host 'Your link is ready' -ForegroundColor Green
  Write-Host ''
  Write-Host "  $u" -ForegroundColor White
  Write-Host ''
  Write-Host "  $a"
  Write-Host "  $b"
  Write-Host ''
  Write-Host 'Close this window, or press Ctrl+C, to end the link.' -ForegroundColor Yellow
}
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class ShareItJob {
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a,b; public uint LimitFlags; public UIntPtr c,d; public uint e; public UIntPtr f; public uint g,h; }
  [StructLayout(LayoutKind.Sequential)] struct IO { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC B; public IO I; public UIntPtr x,y,z,w; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, int l);
  [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  public static IntPtr Make() { var j = CreateJobObject(IntPtr.Zero, null); var i = new EXT(); i.B.LimitFlags = 0x2000; SetInformationJobObject(j, 9, ref i, Marshal.SizeOf(typeof(EXT))); return j; }
  public static void Add(IntPtr j, IntPtr p) { AssignProcessToJobObject(j, p); }
}
'@
$job = [ShareItJob]::Make()

$Mode = $env:SHAREIT_MODE
if (-not $Mode) {
  Write-Host 'What do you want to share?'
  Write-Host "  1) Files in this folder ($Folder): people get a download page"
  Write-Host '  2) A website or app running on a local port'
  $Mode = if ((Read-Host 'Choose 1 or 2') -eq '2') { 'website' } else { 'files' }
}
if ($Mode -eq 'website') {
  $target = $env:SHAREIT_TARGET
  if (-not $target) {
    Write-Host ''
    Write-Host 'Enter the address of your app. Examples:'
    Write-Host '  3000                  port 3000 on this machine'
    Write-Host '  localhost:8080        the same, port 8080'
    Write-Host '  192.168.1.5:8080      another machine on your network'
    $target = Read-Host 'Address'
  }
  $m = [regex]::Match($target.Trim(), '^(?:(https?)://)?(?:([A-Za-z0-9.-]+):)?(\d{1,5})/?$')
  if (-not $m.Success -or [int]$m.Groups[3].Value -gt 65535 -or [int]$m.Groups[3].Value -lt 1) { Fail "`"$target`" is not an address. Examples: 3000, localhost:8080, 192.168.1.5:8080"; return }
  $scheme = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { 'http' }
  $thost = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { 'localhost' }
  $tport = [int]$m.Groups[3].Value
  try { $c = New-Object Net.Sockets.TcpClient; $c.Connect($thost, $tport); $c.Close() } catch { Fail "Nothing is answering on ${thost}:$tport. Start your app first, then paste the command again."; return }
  $cfw = Get-Cloudflared
  $work = Join-Path $Home2 ("run-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  [IO.File]::WriteAllText((Join-Path $work 'owner'), "$PID")
  [IO.File]::WriteAllText((Join-Path $work 'empty.yml'), '')
  $log = Join-Path $work 'tunnel.log'
  $w = $work -replace '\\','/'
  $pC = $null
  try {
    $pC = Start-Process -FilePath $cfw -ArgumentList @('tunnel', '--config', "`"$w/empty.yml`"", '--no-autoupdate', '--no-tls-verify', '--http-host-header', "${thost}:$tport", '--url', "${scheme}://${thost}:$tport") -WindowStyle Hidden -RedirectStandardError $log -PassThru
    [ShareItJob]::Add($job, $pC.Handle)
    $url = Wait-Link $pC $log
    if (-not $url) { Fail 'Cloudflare did not give a link. Check the internet connection and try again.'; return }
    Wait-Live "$url/"
    Show-Link $url "Sharing: your app at ${scheme}://${thost}:$tport" 'Anyone with this link can open your app, so do not leave private data on it.'
    while (-not $pC.HasExited) { Start-Sleep -Seconds 2 }
    Fail 'The Cloudflare connection stopped, so the link has ended. Paste the command again for a new link.'
  } finally {
    if ($pC -and -not $pC.HasExited) { try { Stop-Process -Id $pC.Id -Force } catch {} }
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host 'The link has ended. The tunnel is off; nothing was uninstalled.'
  }
  return
}

$risky = @($env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:SystemDrive\", "$env:SystemDrive\Users", "$env:SystemRoot\System32")
if (($risky | ForEach-Object { if ($_) { $_.TrimEnd('\') } }) -contains $Folder.TrimEnd('\') -and -not $env:SHAREIT_FORCE) {
  Fail "ShareIT will not put $Folder on the internet: it may hold private files."
  Write-Host '  Go to the folder you want to share (cd) and paste the command there.'
  return
}

# ---- tools: downloaded once, no admin rights needed ----
New-Item -ItemType Directory -Force -Path $Home2 | Out-Null
$nginxDir = Join-Path $Home2 "nginx-$NginxVersion"
$nginx = Join-Path $nginxDir 'nginx.exe'
if (-not (Test-Path $nginx)) {
  Write-Host 'Installing nginx (first run only)...'
  $zip = Join-Path $Home2 'nginx.zip'
  Invoke-WebRequest "https://nginx.org/download/nginx-$NginxVersion.zip" -OutFile $zip -UseBasicParsing
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $Home2)
  Remove-Item $zip
}
$cf = Get-Cloudflared

# ---- the page ----
function Enc($s) { [System.Net.WebUtility]::HtmlEncode($s) }
function Human([double]$b) { $u = 'B','KB','MB','GB','TB'; $i = 0; while ($b -ge 1024 -and $i -lt 4) { $b /= 1024; $i++ }; if ($i -eq 0) { "{0:N0} {1}" -f $b, $u[$i] } else { "{0:N1} {1}" -f $b, $u[$i] } }
$root = $Folder.TrimEnd('\')
$files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
  $r = $_.FullName.Substring($root.Length + 1); -not (($r -split '\\') | Where-Object { $_.StartsWith('.') }) -and -not $_.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)
} | Sort-Object FullName | Select-Object -First 5000)
if ($files.Count -eq 0) { Fail 'This folder has no files to share.'; return }
$sum = ($files | Measure-Object Length -Sum).Sum
$total = Human $sum
function Href($rel) { (($rel -split '\\') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/' }
function ExtOf($n) { $e = [IO.Path]::GetExtension($n).TrimStart('.'); if (-not $e) { $e = 'file' }; if ($e.Length -gt 5) { $e = $e.Substring(0,5) }; $e }
$name = Split-Path $root -Leaf
if ($files.Count -eq 1) {
  $f = $files[0]; $rel = $f.FullName.Substring($root.Length + 1)
  $body = "<div class=`"one`"><div class=`"ext`">$(Enc (ExtOf $f.Name))</div><h2 dir=`"auto`">$(Enc $f.Name)</h2><p>$total</p><a class=`"btn`" href=`"$(Href $rel)`" download>Download</a></div>"
} else {
  $rows = New-Object Text.StringBuilder
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1)
    $sub = Split-Path $rel -Parent
    $dir = if ($sub) { "<span class=`"dir`">$(Enc ($sub -replace '\\','/'))</span>" } else { '' }
    [void]$rows.Append("<li><a href=`"$(Href $rel)`" download><span class=`"ext`">$(Enc (ExtOf $f.Name))</span><span class=`"name`" dir=`"auto`">$(Enc $f.Name)$dir</span><span class=`"size`">$(Human $f.Length)</span><span class=`"get`">Download</span></a></li>")
  }
  $body = "<div class=`"head`"><div><h1 dir=`"auto`">$(Enc $name)</h1><p>$($files.Count) files &middot; $total</p></div></div><div class=`"bar`"><input class=`"find`" id=`"find`" type=`"search`" placeholder=`"Find a file`" aria-label=`"Find a file`"></div><ul>$($rows.ToString())</ul><div class=`"none`" id=`"none`">No file with that name.</div>"
}
$page = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>__TITLE__ · ShareIT</title>
<style>
:root{--bg:#f4f7fb;--card:#fff;--fg:#0f172a;--muted:#64748b;--line:#e2e8f0;--soft:#f1f5f9;--accent:#0891b2;--btn:#0f172a;--btn-fg:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#0b1220;--card:#131c2e;--fg:#e2e8f0;--muted:#94a3b8;--line:#22304a;--soft:#1b2740;--accent:#22d3ee;--btn:#22d3ee;--btn-fg:#06202a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans Arabic",sans-serif}
.wrap{max-width:860px;margin:0 auto;padding:32px 16px 48px}
.brand{display:flex;align-items:center;gap:12px;margin-bottom:24px}
.brand svg{width:44px;height:44px;flex:none}
.brand b{display:block;font-size:19px;line-height:1.2}
.brand span{color:var(--muted);font-size:13px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden}
.head{padding:18px 20px;border-bottom:1px solid var(--line);display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between}
.head h1{margin:0;font-size:18px;overflow-wrap:anywhere}
.head p{margin:2px 0 0;color:var(--muted);font-size:13px}
.find{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:9px;background:var(--soft);color:var(--fg);font:inherit;font-size:16px}
.bar{padding:12px 20px;border-bottom:1px solid var(--line)}
ul{list-style:none;margin:0;padding:0}
li a{display:flex;align-items:center;gap:12px;padding:12px 20px;color:inherit;text-decoration:none;border-bottom:1px solid var(--line);transition:background .15s,transform .15s}
li:last-child a{border-bottom:0}
li a:hover{background:var(--soft)}
.ext{flex:none;width:44px;height:36px;border-radius:8px;background:var(--soft);color:var(--muted);font-size:10.5px;font-weight:700;display:grid;place-items:center;text-transform:uppercase;overflow:hidden}
.name{flex:1;min-width:0;overflow-wrap:anywhere}
.dir{display:block;color:var(--muted);font-size:12px}
.size{flex:none;color:var(--muted);font-size:13px;font-variant-numeric:tabular-nums}
.get{flex:none;color:var(--accent);font-weight:600;font-size:13px}
.one{padding:36px 20px;text-align:center}
.one .ext{margin:0 auto 12px;width:64px;height:52px;font-size:13px}
.one h2{margin:0 0 4px;font-size:18px;overflow-wrap:anywhere}
.one p{margin:0 0 18px;color:var(--muted)}
.btn{display:inline-block;padding:11px 26px;border-radius:9px;background:var(--btn);color:var(--btn-fg);font-weight:600;text-decoration:none;transition:opacity .15s,transform .15s}
.btn:hover{opacity:.88;transform:translateY(-1px)}
.none{display:none;padding:24px 20px;text-align:center;color:var(--muted)}
footer{margin-top:18px;color:var(--muted);font-size:12.5px;text-align:center}
footer a{color:inherit;text-decoration:none}
@media (max-width:560px){.get{display:none}}
</style>
</head>
<body>
<div class="wrap">
  <div class="brand">__LOGO__<div><b>ShareIT</b><span>by SecuryTik</span></div></div>
  <div class="card">
__BODY__
  </div>
  <footer>This link works only while the sender keeps ShareIT open · <a href="https://securytik.com">securytik.com</a></footer>
</div>
<script>
(function(){var f=document.getElementById('find');if(!f)return;var r=[].slice.call(document.querySelectorAll('li')),n=document.getElementById('none');
f.addEventListener('input',function(){var q=f.value.toLowerCase(),c=0;r.forEach(function(x){var s=x.textContent.toLowerCase().indexOf(q)>=0;x.style.display=s?'':'none';if(s)c++});n.style.display=c?'none':'block'})})();
</script>
</body>
</html>
'@
$logo = @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="SecuryTik">
  <defs>
    <linearGradient id="sk-bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#1e293b"/>
      <stop offset="100%" stop-color="#0b1220"/>
    </linearGradient>
    <radialGradient id="sk-glow" cx="0.5" cy="0.5" r="0.55">
      <stop offset="0%" stop-color="#22d3ee" stop-opacity="0.34"/>
      <stop offset="70%" stop-color="#22d3ee" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="sk-shield" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#22d3ee"/>
      <stop offset="50%" stop-color="#38bdf8"/>
      <stop offset="100%" stop-color="#0ea5e9"/>
    </linearGradient>
  </defs>
  <rect width="64" height="64" rx="14" fill="url(#sk-bg)"/>
  <rect width="64" height="64" rx="14" fill="url(#sk-glow)"/>
  <rect x="0.75" y="0.75" width="62.5" height="62.5" rx="13.25"
        fill="none" stroke="#ffffff" stroke-opacity="0.12" stroke-width="1"/>
  <path fill="none" stroke="url(#sk-shield)" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round"
        d="M32 12 L50 18 L50 35 C50 46 32 52 32 52 C32 52 14 46 14 35 L14 18 Z"/>
</svg>
'@
$page = $page.Replace('__TITLE__', (Enc $name)).Replace('__LOGO__', $logo).Replace('__BODY__', $body)

# ---- run: both programs die with this window (a Windows job object) ----
$work = Join-Path $Home2 ("run-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
foreach ($d in 'logs','temp','temp/client_body_temp') { New-Item -ItemType Directory -Force -Path (Join-Path $work $d) | Out-Null }
[IO.File]::WriteAllText((Join-Path $work 'owner'), "$PID")
[IO.File]::WriteAllText((Join-Path $work 'index.html'), $page, (New-Object Text.UTF8Encoding($false)))
$bytes = New-Object byte[] 16; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
$port = 8765
while ($true) { try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port); $l.Start(); $l.Stop(); break } catch { $port++ } }
$w = $work -replace '\\','/'; $s = $root -replace '\\','/'; $n = $nginxDir -replace '\\','/'
$conf = @"
worker_processes 1;
pid "$w/nginx.pid";
error_log "$w/logs/error.log";
events { worker_connections 512; }
http {
  include "$n/conf/mime.types";
  default_type application/octet-stream;
  access_log off;
  server_tokens off;
  client_body_temp_path "$w/temp/client_body_temp";
  proxy_temp_path "$w/temp/p"; fastcgi_temp_path "$w/temp/f"; uwsgi_temp_path "$w/temp/u"; scgi_temp_path "$w/temp/s";
  server {
    listen 127.0.0.1:$port;
    location = /$token/ { default_type text/html; root "$w"; try_files /index.html =404; add_header Cache-Control no-store; }
    location ~ ^/$token/(.*/)?\. { return 404; }
    location /$token/ {
      alias "$s/";
      add_header Content-Disposition attachment;
      add_header X-Content-Type-Options nosniff;
      limit_except GET { deny all; }
    }
    location / { return 404; }
  }
}
"@
[IO.File]::WriteAllText((Join-Path $work 'nginx.conf'), $conf, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $work 'empty.yml'), '')
$pN = $null; $pC = $null
try {
  $pN = Start-Process -FilePath $nginx -ArgumentList @('-p', "`"$w/`"", '-e', "`"$w/logs/error.log`"", '-c', "`"$w/nginx.conf`"") -WorkingDirectory $nginxDir -WindowStyle Hidden -PassThru
  [ShareItJob]::Add($job, $pN.Handle)
  Start-Sleep -Milliseconds 800
  if ($pN.HasExited) { Fail 'nginx could not start:'; Get-Content (Join-Path $work 'logs/error.log') -ErrorAction SilentlyContinue | Select-Object -Last 5; return }
  $log = Join-Path $work 'tunnel.log'
  $pC = Start-Process -FilePath $cf -ArgumentList @('tunnel', '--config', "`"$w/empty.yml`"", '--no-autoupdate', '--url', "http://127.0.0.1:$port") -WindowStyle Hidden -RedirectStandardError $log -PassThru
  [ShareItJob]::Add($job, $pC.Handle)
  $url = Wait-Link $pC $log
  if (-not $url) { Fail 'Cloudflare did not give a link. Check the internet connection and try again.'; return }
  Wait-Live "$url/$token/"
  Show-Link "$url/$token/" "Sharing: $Folder  ($($files.Count) files, $total)" 'Anyone with this link can download these files.'
  while (-not $pC.HasExited) { Start-Sleep -Seconds 2 }
  Fail 'The Cloudflare connection stopped, so the link has ended. Paste the command again for a new link.'
} finally {
  foreach ($p in $pC, $pN) { if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force } catch {} } }
  Get-CimInstance Win32_Process -Filter "Name='nginx.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$w*" -or $_.ExecutablePath -eq $nginx } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
  Start-Sleep -Milliseconds 300
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host ''
  Write-Host 'The link has ended. nginx and the tunnel are off; nothing was uninstalled.'
}
}
