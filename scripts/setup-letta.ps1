# 初始化 Letta 侧：（缺失时）装 CLI、在记忆管家的 MemFS 里补齐骨架、建 MemFS 之外的收件箱目录。
# 前提：已完成 `letta connect` 并建好记忆管家 agent，拿到了它的 MemFS 目录（见 HANDOFF Step 3–4）。
# 用法：powershell -NoProfile -File .\setup-letta.ps1 -MemoryDir "<MEMORY_DIR>" [-Persona <id>] [-PersonaPath <file>]
#   -Persona：从仓库 personas/ 选卡，whale（默认）/ gentle / tsundere / genki / literary / none。
#             none = 不创建 persona.md（插件自动跳过，只有记忆、没有角色表演）。
#   -PersonaPath：自定义人设源文件；与 -Persona 互斥。

param(
  [Parameter(Mandatory = $true)][string]$MemoryDir,
  [string]$Inbox = "$env:USERPROFILE\.letta-bridge\inbox\notes.jsonl",
  [string]$PersonaPath,
  [ValidateSet("whale", "gentle", "tsundere", "genki", "literary", "none")][string]$Persona = "whale"
)

$ErrorActionPreference = "Stop"
# PS 5.1 在 -File 模式下绑定 [Parameter] 参数时 $PSScriptRoot 为空，默认值必须在脚本体内补。
if ($PersonaPath -and $PSBoundParameters.ContainsKey("Persona")) {
  throw "-PersonaPath 与 -Persona 不能同时使用：二选一。"
}
$personaLibrary = Join-Path $PSScriptRoot "..\personas"
if (-not $PersonaPath -and $Persona -ne "none") {
  $candidate = Join-Path $personaLibrary "$Persona.md"
  # 兼容旧布局：没有 personas/whale.md 时回退仓库根 persona.md
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -and $Persona -eq "whale") {
    $candidate = Join-Path $PSScriptRoot "..\persona.md"
  }
  $PersonaPath = $candidate
}
$utf8 = New-Object System.Text.UTF8Encoding($false)

Write-Host "== 1/3 检查 Node 与 Letta CLI ==" -ForegroundColor Cyan
$node = (node -v) 2>$null
if (-not $node) { throw "未找到 node，请先安装 Node.js 22.19+" }
Write-Host "node $node"
if ([int]($node.TrimStart('v').Split('.')[0]) -lt 22) { Write-Warning "Letta CLI 要求 Node 22.19+，当前 $node" }
$letta = Get-Command letta -ErrorAction SilentlyContinue
if (-not $letta) {
  npm install -g @letta-ai/letta-code
  $letta = Get-Command letta -ErrorAction SilentlyContinue
}
if (-not $letta) { Write-Warning "letta 未进 PATH，重开终端或检查 npm 全局 bin 目录" } else { Write-Host "letta => $($letta.Source)" }

Write-Host "== 2/3 补齐 MemFS 骨架（已存在的文件不覆盖）==" -ForegroundColor Cyan
if (-not (Test-Path $MemoryDir)) { throw "MemFS 目录不存在：$MemoryDir（先完成 HANDOFF Step 4）" }
foreach ($d in @("events", "people", "topics", "archive\events")) { New-Item -ItemType Directory -Force -Path (Join-Path $MemoryDir $d) | Out-Null }

function Write-IfMissing([string]$Path, [string]$Content) {
  if (Test-Path $Path) { Write-Host "  已存在，跳过：$Path"; return }
  [System.IO.File]::WriteAllText($Path, $Content, $utf8)
  Write-Host "  写入：$Path"
}

$coreLines = @()
if ($Persona -ne "none" -or $PersonaPath) { $coreLines += "- persona.md —— 我是谁：语气、边界、说话习惯" }
$coreLines += "- human.md —— 对方是谁：称呼、作息、口味、雷点、关系阶段"
$deepLines = @(
  "- events/ —— 按日期的事件线，一天一个文件",
  "- people/ —— 对方生活里出现的人",
  "- topics/ —— 长期话题：工作、健康、游戏、共同经历"
)
if (Test-Path -LiteralPath $personaLibrary -PathType Container) {
  $deepLines += "- personas/ —— 人设库（只读源），对方要求时按卡片切换"
}
$memoryTemplate = @"
---
name: MEMORY
description: "记忆索引：常驻文件 + 深水区目录。"
---

# 记忆索引

常驻（每轮都在上下文里，务必短）：
$($coreLines -join "`n")

深水区（不进上下文，按需 read/search）：
$($deepLines -join "`n")
"@
Write-IfMissing (Join-Path $MemoryDir "MEMORY.md") $memoryTemplate

# 人设库：同步到 MemFS 深水区（只补缺失，不覆盖已有文件；库文件是只读源）
if (Test-Path -LiteralPath $personaLibrary -PathType Container) {
  $libTarget = Join-Path $MemoryDir "personas"
  New-Item -ItemType Directory -Force -Path $libTarget | Out-Null
  foreach ($card in Get-ChildItem -LiteralPath $personaLibrary -Filter "*.md" -File | Where-Object { $_.Name -ne "README.md" }) {
    Write-IfMissing (Join-Path $libTarget $card.Name) ([System.IO.File]::ReadAllText($card.FullName, [System.Text.Encoding]::UTF8))
  }
  $whaleTarget = Join-Path $libTarget "whale.md"
  if (-not (Test-Path -LiteralPath $whaleTarget)) {
    $rootPersona = Join-Path $PSScriptRoot "..\persona.md"
    if (Test-Path -LiteralPath $rootPersona -PathType Leaf) {
      Write-IfMissing $whaleTarget ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $rootPersona).Path, [System.Text.Encoding]::UTF8))
    }
  }
  Write-Host "  人设库：$libTarget"
} else {
  Write-Host "  未找到人设库目录，跳过同步：$personaLibrary"
}

$personaTarget = Join-Path $MemoryDir "persona.md"
if ($Persona -eq "none") {
  if (Test-Path $personaTarget) {
    Write-Warning "已存在 persona.md；-Persona none 不会删除它。确定不用人设时请手动删除（git 历史可恢复）；已有 MEMORY.md 索引也不会自动改写。"
  } else {
    Write-Host "  不用人设：未创建 persona.md（插件会自动跳过）"
  }
} elseif (Test-Path $personaTarget) {
  Write-Host "  已存在，跳过：$personaTarget"
} else {
  if (-not (Test-Path -LiteralPath $PersonaPath -PathType Leaf)) { throw "人设源文件不存在：$PersonaPath（-Persona $Persona）" }
  $personaText = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $PersonaPath).Path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($personaText)) { throw "人设源文件为空：$PersonaPath" }
  if ($personaText.Length -gt 2600) { throw "人设源文件超出 2600 字符：$($personaText.Length)" }
  $personaLabel = if ($PSBoundParameters.ContainsKey("PersonaPath")) { "自定义" } else { $Persona }
  Write-Host "  人设：$personaLabel => $personaTarget"
  Write-IfMissing $personaTarget $personaText
}

Write-IfMissing (Join-Path $MemoryDir "human.md") @"
---
name: human
description: "对方是谁：稳定事实与偏好（≤1400 字符）。"
---

# 对方

## 基本
- 称呼：
- 时区/作息：

## 偏好
-

## 雷点
-

## 关系
- 阶段：初识 / 熟悉 / 亲近
- 最近一次重要互动：

## 近期状态（周整理推断）
"@

Write-Host "== 3/3 收件箱目录（在 MemFS 之外）==" -ForegroundColor Cyan
$inboxDir = Split-Path $Inbox -Parent
New-Item -ItemType Directory -Force -Path (Join-Path $inboxDir "archive") | Out-Null
Write-Host "  收件箱：$Inbox"

$full = (Resolve-Path $MemoryDir).Path.TrimEnd('\')
if ($Inbox.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
  Write-Warning "收件箱位于 MemFS 内，会被 Letta 提交进 git。请换一个 MemFS 之外的路径。"
}
Write-Host "`n完成。下一步：HANDOFF Step 5（装进 DSH 桌面版）。" -ForegroundColor Green
