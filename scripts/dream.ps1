# 离线"做梦"：日常整合（每次运行）+ 每周深化与遗忘（距上次周整理满 7 天时）。
# 建议计划任务：每天凌晨跑一次。无新笔记且未到周整理时秒退。
# 用法：powershell -NoProfile -File .\dream.ps1 -AgentId <AGENT_ID> -MemoryDir "<MEMORY_DIR>"
#
# 日常整合：把 DSH 写进收件箱的笔记交给 Letta 记忆管家整合进 MemFS。
#   并发安全：先把 notes.jsonl 原子改名为 notes.processing.jsonl 再处理，DSH 之后追加的笔记落进新的 notes.jsonl。
#   处理失败时 processing 文件保留，下次运行优先续跑它。
# 每周整理：forget-plan.mjs 按"重要度 × 闲置天数"算出淡忘/唤回清单（0 LLM），
#   连同本周事件交给管家：提炼近期状态 → 执行淡忘/唤回 → 收敛常驻区。按"上次周整理日期"判断，关机错过会补跑。

param(
  [Parameter(Mandatory = $true)][string]$AgentId,
  [Parameter(Mandatory = $true)][string]$MemoryDir,
  [string]$Inbox = "$env:USERPROFILE\.letta-bridge\inbox\notes.jsonl",
  [string]$CuratorPrompt,
  [string]$WeeklyPrompt,
  [int]$MaxNotes = 200,
  [int]$WeeklyEveryDays = 7,
  # 立即执行一次周整理（不看上次日期）
  [switch]$ForceWeekly,
  # letta 调用的公共参数；CLI 版本不同时按 `letta --help` 调整（例如需要追加跳过权限确认的参数）
  [string[]]$LettaArgs = @("--backend", "local")
)

$ErrorActionPreference = "Stop"
# PS 5.1 在 -File 模式下绑定 [Parameter] 参数时 $PSScriptRoot 为空，默认值必须在脚本体内补。
if (-not $CuratorPrompt) { $CuratorPrompt = Join-Path $PSScriptRoot "..\prompts\memory-curator.md" }
if (-not $WeeklyPrompt) { $WeeklyPrompt = Join-Path $PSScriptRoot "..\prompts\weekly-reflection.md" }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$dir = Split-Path $Inbox -Parent
$processing = Join-Path $dir "notes.processing.jsonl"
$archive = Join-Path $dir "archive"
$log = Join-Path $dir "dream.log"
$task = Join-Path $dir "dream-task.md"
$stateFile = Join-Path $dir "dream-state.json"
New-Item -ItemType Directory -Force -Path $archive | Out-Null

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  [System.IO.File]::AppendAllText($log, $line + "`r`n", $utf8)
  Write-Host $line
}

function Read-Lines([string]$path) {
  @([System.IO.File]::ReadAllLines($path, $utf8) | Where-Object { $_.Trim() -ne "" })
}

function Read-Text([string]$path) {
  [System.IO.File]::ReadAllText((Resolve-Path $path), $utf8)
}

# 把任务正文写进文件，命令行只传一句短指令（避免 Windows 32K 命令行上限）；返回 letta 退出码
function Invoke-Curator([string]$body, [string]$what) {
  [System.IO.File]::WriteAllText($task, $body, $utf8)
  $prompt = "读取文件 $task ，它包含你的整理规则和本次任务。按规则处理你的记忆目录 $MemoryDir 并提交，然后只输出一行摘要。"
  Log "开始$what，agent=$AgentId"
  Push-Location $dir
  # PS 5.1 在 Stop 模式下会把原生命令的任何 stderr 输出当成终止错误；成败只看退出码
  $ErrorActionPreference = "Continue"
  try {
    $out = & letta @LettaArgs --agent $AgentId -p $prompt 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = "Stop"
    Pop-Location
  }
  Log "letta 退出码 $code"
  Log ($out | Out-String)
  return $code
}

foreach ($p in @($CuratorPrompt, $WeeklyPrompt)) { if (-not (Test-Path $p)) { throw "找不到规则文件：$p" } }
$rules = Read-Text $CuratorPrompt

# ── 日常整合 ─────────────────────────────────────────────
function Invoke-Daily {
  if (Test-Path $processing) {
    Log "发现上次未完成的 $processing，先续跑它（新笔记留在 notes.jsonl 等下次）"
  } else {
    if (-not (Test-Path $Inbox)) { Log "收件箱没有新笔记"; return }
    $moved = $false
    for ($i = 0; $i -lt 5 -and -not $moved; $i++) {
      try { [System.IO.File]::Move($Inbox, $processing); $moved = $true }
      catch { Start-Sleep -Seconds 1 }   # DSH 正在追加时文件短暂被占用
    }
    if (-not $moved) { throw "收件箱被占用，无法改名：$Inbox" }
  }

  $all = Read-Lines $processing
  if ($all.Count -eq 0) { Remove-Item $processing -Force; Log "收件箱为空"; return }

  $archiveFile = Join-Path $archive ("processed-{0}.jsonl" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
  # 分批：每批成功后立刻归档并回写剩余，失败时剩余（含失败批）留在 processing
  $offset = 0
  while ($offset -lt $all.Count) {
    $batch = @($all | Select-Object -Skip $offset -First $MaxNotes)
    $notesText = ($batch | ForEach-Object {
        try {
          $o = $_ | ConvertFrom-Json
          $tags = if ($o.tags) { " [" + ($o.tags -join ",") + "]" } else { "" }
          "- $($o.ts)$tags $($o.text)"
        } catch { "- $_" }
      }) -join "`n"

    $body = $rules + "`n`n---`n`n## 本次笔记（$($batch.Count) 条）`n`n记忆目录：$MemoryDir`n`n" + $notesText + "`n"
    $code = Invoke-Curator $body "日常整合：第 $($offset + 1)-$($offset + $batch.Count) 条 / 共 $($all.Count) 条"
    if ($code -ne 0) {
      Log "失败：剩余 $($all.Count - $offset) 条保留在 $processing，修好后直接重跑"
      throw "letta 调用失败"
    }
    [System.IO.File]::AppendAllLines($archiveFile, [string[]]$batch, $utf8)
    $offset += $batch.Count
    $rest = @($all | Select-Object -Skip $offset)
    if ($rest.Count -gt 0) { [System.IO.File]::WriteAllLines($processing, [string[]]$rest, $utf8) }
  }
  Remove-Item $processing -Force
  Log "日常整合完成：已归档 $($all.Count) 条 → $archiveFile"
}

# ── 每周深化与遗忘 ───────────────────────────────────────
function Invoke-Weekly {
  $today = Get-Date -Format "yyyy-MM-dd"
  $last = $null
  if (Test-Path $stateFile) { $last = (Read-Text $stateFile | ConvertFrom-Json).lastWeekly }
  if (-not $ForceWeekly -and $last -and ((New-TimeSpan -Start ([datetime]$last) -End ([datetime]$today)).Days -lt $WeeklyEveryDays)) {
    Log "周整理未到期（上次 $last）"
    return
  }

  $planJson = & node (Join-Path $PSScriptRoot "forget-plan.mjs") --memory-dir $MemoryDir --state-dir $dir --today $today
  if ($LASTEXITCODE -ne 0) { throw "forget-plan.mjs 失败" }
  $plan = ($planJson -join "`n") | ConvertFrom-Json
  Log ("遗忘计划：淡忘 {0}、唤回 {1}、本周事件 {2}；现有事件 {3}、已淡忘 {4}、永不淡忘 {5}" -f
    @($plan.archive).Count, @($plan.restore).Count, @($plan.recent).Count, $plan.stats.events, $plan.stats.archived, $plan.stats.pinned)

  $recentText = if (@($plan.recent).Count -eq 0) { "（本周没有新事件）" } else {
    (@($plan.recent) | ForEach-Object { "### $_`n" + (Read-Text (Join-Path $MemoryDir $_)).Trim() }) -join "`n`n"
  }
  $fmt = { param($items) if (@($items).Count -eq 0) { "（无）" } else { (@($items) | ForEach-Object { "- $($_.from) → $($_.to)" }) -join "`n" } }

  $body = $rules + "`n`n---`n`n" + (Read-Text $WeeklyPrompt) +
    "`n`n---`n`n今天：$today`n记忆目录：$MemoryDir`n`n## 本周事件`n`n$recentText" +
    "`n`n## 遗忘计划`n`n### 淡忘`n" + (& $fmt $plan.archive) + "`n`n### 唤回`n" + (& $fmt $plan.restore) + "`n"
  $code = Invoke-Curator $body "周整理"
  if ($code -ne 0) { throw "周整理失败，下次运行会重试" }

  [System.IO.File]::WriteAllText($stateFile, (@{ lastWeekly = $today } | ConvertTo-Json), $utf8)
  Log "周整理完成"
}

Invoke-Daily
Invoke-Weekly
Remove-Item $task -Force -ErrorAction SilentlyContinue
