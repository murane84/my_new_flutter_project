# Builds the Aluta Admin web app and places it in my_aluta_api\adminapp, which
# the backend serves at https://aluta.ozilane.com/admin/ .
#
#   powershell -ExecutionPolicy Bypass -File tool\build_admin.ps1
#
# Then commit my_aluta_api\adminapp and push (Railway redeploys).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

flutter build web --release -t lib/main_admin.dart --base-href /admin/ --output build/admin
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

# Give the installable app its own name / colours (the web/ template says "Aluta").
$manifestPath = Join-Path $root 'build\admin\manifest.json'
$m = Get-Content $manifestPath -Raw | ConvertFrom-Json
$m.name = 'Aluta Admin'
$m.short_name = 'Aluta Admin'
$m.description = 'Aluta backoffice (owner only)'
$m.background_color = '#0F0F14'
$m.theme_color = '#0F0F14'
$m.orientation = 'any'
$m | ConvertTo-Json -Depth 6 | Set-Content $manifestPath -Encoding UTF8

$indexPath = Join-Path $root 'build\admin\index.html'
$html = Get-Content $indexPath -Raw
$html = $html -replace '<title>Aluta</title>', '<title>Aluta Admin</title><meta name="robots" content="noindex, nofollow">'
$html = $html -replace 'content="Aluta"', 'content="Aluta Admin"'
$html = $html -replace '#C62828', '#0F0F14'
Set-Content $indexPath $html -Encoding UTF8

$dest = Join-Path $root 'my_aluta_api\adminapp'
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Copy-Item (Join-Path $root 'build\admin') $dest -Recurse
Write-Host "Admin app ready in my_aluta_api\adminapp - commit and push to deploy."
