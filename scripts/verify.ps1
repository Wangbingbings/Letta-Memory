# 校验接线是否成立：记忆目录、核心区大小、收件箱位置与积压、插件是否进了 desktop profile。
param(
  [Parameter(Mandatory = $true)][string]$MemoryDir,
  [string]$Inbox = "$env:USERPROFILE\.letta-bridge\inbox\notes.jsonl",
  [string]$DshHome = "",
  [string]$Profile = "desktop"
)

$ok = $true
function Check([string]$label, [bool]$cond, [string]$detail = "") {
  if ($cond) { Write-Host "  [OK]   $label $detail" -ForegroundColor Green }
  else { Write-Host "  [FAIL] $label $detail" -ForegroundColor Red; $script:ok = $false }
}

if ($DshHome) { $env:DSH_HOME = $DshHome }

Write-Host "== 记忆目录（MemFS）==" -ForegroundColor Cyan
Check "目录存在" (Test-Path $MemoryDir) $MemoryDir
if (Test-Path $MemoryDir) {
  Check "是 git 仓库（Letta MemFS 应自带）" (Test-Path (Join-Path $MemoryDir ".git"))
  foreach ($f in @("MEMORY.md", "persona.md", "human.md")) {
    $p = Join-Path $MemoryDir $f
    if (Test-Path $p) {
      $len = (Get-Content $p -Raw -Encoding UTF8).Length
      $limit = if ($f -eq "human.md") { 1200 } elseif ($f -eq "persona.md") { 600 } else { 800 }
      Check "$f 存在" $true "$len 字（上限 $limit）"
      if ($len -gt $limit) { Write-Host "         ↑ 超预算，会让每轮输入变贵，让记忆管家压缩" -ForegroundColor Yellow }
    } else { Check "$f 存在" $false }
  }
  $events = Join-Path $MemoryDir "events"
  if (Test-Path $events) {
    $files = @(Get-ChildItem $events -Filter *.md)
    $noImp = @($files | Where-Object { -not ((Get-Content $_.FullName -Raw -Encoding UTF8) -match '(?m)^importance:\s*[123]\s*$') })
    Write-Host "  [info] events/ 共 $($files.Count) 个文件；未标重要度 $($noImp.Count) 个（按 2 处理）"
    if ($files.Count -gt 300) { Write-Host "         ↑ 接近检索扫描上限 400，确认周整理在正常淡忘" -ForegroundColor Yellow }
  }
  $faded = Join-Path $MemoryDir "archive\events"
  if (Test-Path $faded) { Write-Host "  [info] archive/events/ 已淡忘 $((Get-ChildItem $faded -Filter *.md | Measure-Object).Count) 个" }
}

Write-Host "== 做梦（整合 / 周整理）==" -ForegroundColor Cyan
$stateFile = Join-Path (Split-Path $Inbox -Parent) "dream-state.json"
if (Test-Path $stateFile) {
  $last = (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).lastWeekly
  $days = (New-TimeSpan -Start ([datetime]$last) -End (Get-Date)).Days
  Write-Host "  [info] 上次周整理 $last（$days 天前）" -ForegroundColor $(if ($days -gt 14) { "Yellow" } else { "Gray" })
  if ($days -gt 14) { Write-Host "         ↑ 超过两周没跑周整理，看 dream.log" -ForegroundColor Yellow }
} else { Write-Host "  [info] 还没跑过周整理（首次运行 dream.ps1 时会跑）" }
Check "node 在 PATH（周整理的遗忘计划需要）" ([bool](Get-Command node -ErrorAction SilentlyContinue))

Write-Host "== 收件箱 ==" -ForegroundColor Cyan
$inboxDir = Split-Path $Inbox -Parent
Check "收件箱目录存在" (Test-Path $inboxDir) $inboxDir
if (Test-Path $MemoryDir) {
  $full = (Resolve-Path $MemoryDir).Path.TrimEnd('\')
  Check "收件箱在 MemFS 之外" (-not $Inbox.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) $Inbox
}
if (Test-Path $Inbox) {
  $pending = (Get-Content $Inbox -Encoding UTF8 | Where-Object { $_.Trim() -ne "" } | Measure-Object).Count
  Write-Host "  [info] 收件箱待整合 $pending 条" -ForegroundColor $(if ($pending -gt 300) { "Yellow" } else { "Gray" })
  if ($pending -gt 300) { Write-Host "         积压过多，跑一次 dream.ps1" -ForegroundColor Yellow }
} else { Write-Host "  [info] 收件箱还没有（正常，等 DSH 写第一条）" }
$processing = Join-Path $inboxDir "notes.processing.jsonl"
if (Test-Path $processing) { Write-Host "  [WARN] 有上次未完成的 $processing，看 dream.log 修好后重跑 dream.ps1" -ForegroundColor Yellow }

Write-Host "== Letta CLI ==" -ForegroundColor Cyan
$cli = Get-Command letta -ErrorAction SilentlyContinue
Check "letta 在 PATH" ([bool]$cli) $(if ($cli) { $cli.Source } else { "重开终端或 npm i -g @letta-ai/letta-code" })

Write-Host "== DSH profile（必须是 desktop，不能是 web）==" -ForegroundColor Cyan
if (-not $env:DSH_HOME) { Write-Host "  [info] 未设置 DSH_HOME，跳过（先跑 scripts\find-dsh.ps1）" -ForegroundColor Gray }
else {
  $profDir = Join-Path $env:DSH_HOME "profiles\$Profile"
  Check "profile 目录存在" (Test-Path $profDir) $profDir

  $pkg = Join-Path $profDir "package.json"
  $dep = $false; $bundled = $false
  if (Test-Path $pkg) {
    $j = Get-Content $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
    $dep = [bool]($j.dependencies.PSObject.Properties.Name -contains "dsh-letta-memory")
    $bundled = [bool]($j.dsh.profile.bundles -contains "dsh-letta-memory")
  }
  Check "package.json 依赖里有 dsh-letta-memory" $dep
  Check "dsh.profile.bundles 里有 dsh-letta-memory" $bundled
  Check "插件已安装到 node_modules" (Test-Path (Join-Path $profDir "node_modules\dsh-letta-memory\lib\index.js"))

  $patch = Join-Path $profDir "cordis.patch.yml"
  $hasDir = (Test-Path $patch) -and ((Get-Content $patch -Raw -Encoding UTF8) -match "memoryDir:\s*'[^']+'")
  $envDir = [Environment]::GetEnvironmentVariable("LETTA_MEMORY_DIR", "User")
  Check "memoryDir 已配置（profile patch 或用户环境变量）" ($hasDir -or [bool]$envDir)

  if ($Profile -eq "web") { Write-Host "  [WARN] 这是独立网页版 profile，桌面版请用 desktop" -ForegroundColor Yellow }
}

if ($ok) { Write-Host "`n全部通过。" -ForegroundColor Green } else { Write-Host "`n有失败项，按上面提示修。" -ForegroundColor Red; exit 1 }
