# 把 Letta 接进大肥鱼（DeepSeek Harness）· 文件桥方案

> 目标：让 DSH 的陪伴 agent 拥有 Letta 那种「人设 + 用户画像 + 事件线」的长期记忆，同时**不**把 Letta 的对话循环塞进主链路。
> 场景：QQ 私聊（SnowLuma → QQ 桥接插件 → DSH 桌面版），只服务一个人，DSH 7×24 常驻，人设允许被聊天内容修改。
> **安装与验收只看 [HANDOFF.md](HANDOFF.md)**；本文只讲设计。

---

## 1. 三种接法，只推荐第一种

| 接法 | 数据面 | 主循环 | 每轮额外成本 | 适配度 |
|---|---|---|---|---|
| **A. 文件桥（本方案）** | Letta MemFS 目录（git 版 markdown） | DSH | 0 次额外模型调用（核心区常驻，深水区按需） | ★★★★★ |
| B. SDK 会话桥 | Letta App Server（WebSocket） | DSH + Letta 各跑一次 | 每轮双份模型调用 | ★★☆ |
| C. 全托管 | Letta agent 拥有对话 | Letta | 丢掉 DSH 的 compaction / tools / skills | ★ |

**为什么不选 B/C**：Letta 的 agent 是"自己管上下文"的重型循环。让它同时当陪聊，同一条消息被两个 harness 各推理一遍，token 翻倍，还会和 DSH 的 compaction 抢改历史。**让 Letta 只干它最擅长的那件事：离线把流水账整理成结构化记忆。**

---

## 2. 架构

```
  QQ 私聊 ─ SnowLuma ─ QQ→DSH 桥接插件
                          │
                          ▼
┌──────────────── DSH（陪聊主体，deepseek-flash）────────────────┐
│ 系统提示稳定段：MEMORY.md + persona.md + human.md（mtime 缓存）  │
│ 尾部：memory_search / memory_read 的按需结果                    │
└──────────────┬────────────────────────────────▲───────────────┘
               │ memory_note / 提取日志            │ 只读
               ▼                                 │
  ~/.letta-bridge/inbox/notes.jsonl      <MEMORY_DIR>/*.md（MemFS）
               │ dream.ps1（每天 03:00）           ▲ 改写 + git commit
               ▼                                 │
┌──────────────── Letta「记忆管家」（deepseek-flash）─────────────┐
│ 每天：读规则+笔记 → 合并/去重/标重要度 → 改写 → 提交              │
│ 每周：提炼近期状态 → 淡忘/唤回事件 → 收敛常驻区 → 提交            │
└──────────────────────────────────────────────────────────────┘
```

四个关键点：

1. **MemFS 的目录结构本身就是分层记忆**。根目录核心文件每轮进系统提示（画像）；子目录不进上下文，靠工具读（深水区）。
2. **核心区按 mtime 自动刷新**。插件把核心段注册成函数式 text，每次组装只 stat 文件：不变则逐字节不变（缓存命中），dream 改写后下一步自动生效。DSH 常驻不需要重启。
3. **写入走收件箱**。DSH 只 append 一行 JSON（零 LLM、零延迟）；整合交给离线批处理。收件箱在 MemFS **之外**，避免被管家当成记忆提交。
4. **只让 Letta 写 MemFS**。职责切开后 git 冲突只可能出现在 Letta 侧。
5. **做梦 = 深化 + 遗忘**（见 §5）。

---

## 3. 插件提供的工具

| 工具 | 作用 | 成本 |
|---|---|---|
| `memory_list` | 列记忆文件树 | 本地 IO |
| `memory_search` | 关键词检索（空格分隔多词，同时出现才命中），返回 `path:line` | ≤40 条命中 |
| `memory_read` | 读单个 `.md`（也能读 `archive/` 里淡忘的旧事） | 单次 ≤20k 字符 |
| `memory_note` | 写一行到收件箱 | 0 LLM 调用 |

---

## 4. 记忆槽位规范（决定人设崩不崩）

| 文件 | 内容 | 上限 | 进上下文 |
|---|---|---|---|
| `persona.md` | 我是谁：语气、边界、说话习惯、情绪动作与标志台词（可被聊天要求修改） | 2600 字符（含格式） | 每轮 |
| `human.md` | 对方是谁：称呼、作息、口味、雷点、关系阶段；末尾「近期状态（周整理推断）」 | 1400 字符 | 每轮 |
| `MEMORY.md` | 索引：只列目录结构 | 1000 字符 | 每轮 |
| `events/YYYY-MM-DD.md` | 有日期的事件线，frontmatter 带 `importance: 1-3` | 单条 ≤200 字 | 按需 |
| `archive/events/…` | 淡忘的旧事件（不参与检索） | — | 仅直接读取 |
| `people/<名字>.md` | 对方生活里的人 | 400 字 | 按需 |
| `topics/<话题>.md` | 长期话题 | 800 字 | 按需 |

整理规则：日常 [prompts/memory-curator.md](prompts/memory-curator.md)，每周叠加 [prompts/weekly-reflection.md](prompts/weekly-reflection.md)，`dream.ps1` 每次读它们。人设被改坏时用 MemFS 的 git 历史回滚。

仓库根目录的 [persona.md](persona.md) 是不预设姓名的人设源文件；初始化脚本用 `-Persona` 从 `personas/` 选卡（默认 `whale`，`none` 表示不装人设），或用 `-PersonaPath` 指定另一份人设，仅在 MemFS 缺少 persona 时原样复制；已有文件保留。插件实际读取的是配置的 `<MEMORY_DIR>/persona.md`，修改仓库源文件不会自动同步已有 MemFS。

三份常驻文件在上一版基线上各增加 200 字符：persona 2600、human 1400、MEMORY 1000，合计 5000 字符。插件 `maxCoreChars` 同步从 5000 提至 5600，保留原有 600 字符余量，避免后置的 human 被截断。上限是 UTF-16 字符数，不等于 token 数；核心正文去掉 frontmatter 后共享总预算，格式也计入字符。人设每轮常驻，答复前静默核对，不维护“每十轮”计数或每轮改写文件。

---

## 5. 做梦：深化与遗忘

做梦不只是"把笔记写进去"。遗忘是为了更好地记住：长期不用的旧事退出检索，常用的记忆更容易被想起，检索噪声和常驻区体积都受控。

| 机制（科学依据） | 本方案实现 | 频率 | 成本 |
|---|---|---|---|
| 存储强度 vs 提取强度（Bjork） | 遗忘 = 降一层可提取性：核心 → 深水区 → `archive/` → git，从不删除 | — | — |
| 编码时的情绪/重要性标记 | 事件标重要度 1–3；3（雷点/约定/大事/强情绪）永不淡忘 | 每天 | ≈0（同一次调用） |
| 提取强化（用进废退） | `memory_read` / `memory_search` 命中记入 `recall.jsonl`，被想起即重新计时 | 实时 | 0 LLM |
| 突触稳态（睡眠降噪） | `forget-plan.mjs` 按规则算淡忘名单：重要度 1 闲置 120 天、2 闲置 210 天 | 每周 | 0 LLM |
| 再学习 / 再巩固 | 淡忘的事被直接读到 → 下次周整理唤回 `events/` | 每周 | 0 LLM |
| 系统巩固（经历 → 认识） | ≥3 件事指向同一结论 → 写进「近期状态」，60 天无佐证过期 | 每周 | ≈1 万 token / 周 |

名单由脚本按规则算，移动由管家执行（只有 Letta 写 MemFS）；管家只能在发现重要内容被标低时拒绝淡忘并上调重要度。

---

## 6. Token 账

| 项 | 本方案 | 对照：在线蒸馏型（每条消息跑一次 LLM） |
|---|---|---|
| 每轮注入 | 核心正文最多 5600 字符，token 数与费用按模型实测；不变部分可命中前缀缓存 | 召回 1–3k tokens + 摘要维护 |
| 写入成本 | `memory_note` = 0 次 LLM 调用 | 每条消息 2–3k tokens 蒸馏 |
| 整合成本 | 每 200 条笔记一次，约 8k 输入 + 1k 输出 | 40 条/天 × 2.7k tokens |
| 周整理 | 每周一次，≈1 万 token 输入（≈0.01–0.02 元） | — |
| 缓存失效 | 每天 dream 后一次 | 每轮 |

---

## 7. 缓存规则

1. **核心文件只由 dream 批量改**。改一次就从变化处失效一次前缀缓存；聊天期间频繁手改等于频繁砸缓存。
2. **`memory_note` 只回"已入队：…"**，不回显长内容。
3. **别把时间戳、随机 ID、当前心情写进核心文件**。

---

## 8. 已知偏差

Letta 的 sleep-time agent 读完整对话原文；本方案只整合模型主动 `memory_note` 的内容。DSH 会话原文在 `$DSH_HOME\sessions\…\session.v4.jsonl.zstd`，等确定 QQ 私聊对应哪个 DSH 会话后可以让 dream 直接读原文；在此之前读全部会话会把桌面 GUI 的工作会话混进记忆。

---

## 9. 目录

```
letta-bridge/
├── README.md                     ← 本文（设计）
├── HANDOFF.md                    ← 安装、验收、排错（自包含，内嵌全部文件全文）
├── persona.md                    ← 人设源文件（初始化时复制进 MemFS）
├── plugin/                       ← DSH 插件（零依赖；核心区注入 + 4 个工具）
│   ├── package.json
│   ├── cordis.patch.yml
│   └── lib/index.js
├── scripts/
│   ├── find-dsh.ps1              ← 找 DSH_HOME / desktop profile
│   ├── setup-letta.ps1           ← 补齐 MemFS 骨架 + 人设选择（-Persona）/ 人设库 + 收件箱目录
│   ├── dream.ps1                 ← 做梦：每天整合 + 每周深化与遗忘（并发安全、失败可续跑）
│   ├── forget-plan.mjs           ← 遗忘计划（确定性规则，0 LLM）
│   └── verify.ps1                ← 体检
└── prompts/
    ├── memory-curator.md         ← 记忆管家规则（日常）
    └── weekly-reflection.md      ← 周整理规则（提炼 / 遗忘 / 收敛）
```

> 改了任何文件后，记得同步 HANDOFF.md §5 里对应的全文。

---

## 参考

- Letta MemFS：<https://docs.letta.com/concepts/memfs>
- Memory & dreaming：<https://docs.letta.com/configuration/memory>
- Headless CLI：<https://docs.letta.com/platform/cli/headless>
- SnowLuma：<https://github.com/SnowLuma/SnowLuma>
- DSH 插件机制：桌面版安装目录 `resources\app\dsh\node_modules\@deepseek-ai\dsh-system-prompt\README.zh.md`、`dsh-tools\README.zh.md`
