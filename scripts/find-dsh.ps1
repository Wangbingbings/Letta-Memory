# 找到 DeepSeek Harness 的 DSH_HOME 与桌面版 profile。
# 桌面版 = profile 名 desktop；独立网页版 = profile 名 web。装错会拉起浏览器界面。
param(
  [string[]]$Roots = @("$env:LOCALAPPDATA\Programs", "$env:USERPROFILE", "C:\Program Files", "D:\", "E:\")
)

$found = @()
foreach ($root in $Roots) {
  if (-not (Test-Path $root)) { continue }
  $hits = Get-ChildItem -Path $root -Directory -Filter "profiles" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName "desktop\cordis.patch.yml") }
  foreach ($h in $hits) { $found += (Split-Path $h.FullName -Parent) }
}

$found = $found | Sort-Object -Unique
if (-not $found) {
  Write-Host "没找到含 desktop profile 的 DSH_HOME。" -ForegroundColor Red
  Write-Host "请手动确认：桌面版的 home 目录里应有 profiles\desktop\cordis.patch.yml" -ForegroundColor Yellow
  Write-Host "也可以在一个正在运行的 DSH 会话里执行：`$env:DSH_HOME" -ForegroundColor Yellow
  exit 1
}

foreach ($home2 in $found) {
  Write-Host "DSH_HOME 候选：$home2" -ForegroundColor Cyan
  Get-ChildItem (Join-Path $home2 "profiles") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $pkg = Join-Path $_.FullName "package.json"
    $bundles = ""
    if (Test-Path $pkg) {
      try {
        $j = Get-Content $pkg -Raw | ConvertFrom-Json
        $bundles = ($j.dsh.profile.bundles -join ", ")
      } catch {}
    }
    "  - profile: {0,-8} {1}" -f $_.Name, $bundles
  }
  $desk = Join-Path $home2 "profiles\desktop\package.json"
  if (Test-Path $desk) {
    $v = (Get-Content $desk -Raw | ConvertFrom-Json).dependencies.'@deepseek-ai/dsh-desktop-runtime'
    if ($v) { "  desktop runtime: $v" }
  }
  ""
}

Write-Host "用法：" -ForegroundColor Green
Write-Host "  `$env:DSH_HOME = '<上面某个路径>'" -ForegroundColor Green
Write-Host "  桌面版请从 GUI 装插件（profile=desktop，CLI 不可写）" -ForegroundColor Green
