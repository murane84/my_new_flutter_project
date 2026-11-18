# Builds the Aluta Admin web app and places it in my_aluta_api\adminapp, which
# the backend serves at https://aluta.ozilane.com/admin/ .
#
#   powershell -ExecutionPolicy Bypass -File tool\build_admin.ps1
#
# Then commit my_aluta_api\adminapp and push (Railway redeploys).
$ErrorActionPreference = 'Stop'
# Read and write UTF-8 explicitly (no BOM): Windows PowerShell 5 otherwise
# reads these files as ANSI and turns "—" into "â€”" on the admin page.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

flutter build web --release -t lib/main_admin.dart --base-href /admin/ --output build/admin
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

# Give the installable app its own name / colours (the web/ template says "Aluta").
$manifestPath = Join-Path $root 'build\admin\manifest.json'
$m = [System.IO.File]::ReadAllText($manifestPath, $utf8) | ConvertFrom-Json
$m.name = 'Aluta Admin'
$m.short_name = 'Aluta Admin'
$m.description = 'Aluta backoffice (owner only)'
$m.background_color = '#0F0F14'
$m.theme_color = '#0F0F14'
$m.orientation = 'any'
# Its own installable app (separate from the main Aluta PWA at /).
$m | Add-Member -NotePropertyName id -NotePropertyValue '/admin/' -Force
$m | Add-Member -NotePropertyName scope -NotePropertyValue '/admin/' -Force
$m.start_url = '/admin/'
[System.IO.File]::WriteAllText($manifestPath, ($m | ConvertTo-Json -Depth 6), $utf8)

$indexPath = Join-Path $root 'build\admin\index.html'
$html = [System.IO.File]::ReadAllText($indexPath, $utf8)
$html = $html -replace '<title>[^<]*</title>', '<title>Aluta Admin</title>'
# Private: never indexed, never canonical to the public site.
$html = $html -replace '<meta name="robots" content="[^"]*">', '<meta name="robots" content="noindex, nofollow">'
$html = $html -replace '<link rel="canonical" href="[^"]*">', '<link rel="canonical" href="https://aluta.ozilane.com/admin/">'
$html = $html -replace '(?s)<script type="application/ld\+json">.*?</script>', ''
$html = $html -replace 'content="Aluta"', 'content="Aluta Admin"'
$html = $html -replace '#C62828', '#0F0F14'
# Catch the browser's install offer before Flutter loads (it can fire early);
# the app shows its own "Install Aluta Admin" card from it.
$catcher = '<script>(function(){if(window.__alutaInstallWired)return;window.__alutaInstallWired=true;window.addEventListener("beforeinstallprompt",function(e){e.preventDefault();window.__alutaInstall=e;if(window.__alutaOnInstallReady)window.__alutaOnInstallReady();});window.addEventListener("appinstalled",function(){window.__alutaInstall=null;window.__alutaInstalled=true;if(window.__alutaOnInstallReady)window.__alutaOnInstallReady();});})();</script>'
$html = $html -replace '</head>', "$catcher</head>"
[System.IO.File]::WriteAllText($indexPath, $html, $utf8)

$dest = Join-Path $root 'my_aluta_api\adminapp'
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Copy-Item (Join-Path $root 'build\admin') $dest -Recurse
Write-Host "Admin app ready in my_aluta_api\adminapp - commit and push to deploy."
