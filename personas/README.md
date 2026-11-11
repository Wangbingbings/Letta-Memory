# 人设库与选择机制 · 设计提案

> 状态：**提案，未实现**。插件、脚本、prompts 代码均未改动；「先选人设」提醒已写入 HANDOFF.md（§0 第 10 条、Step 4 第 3 小步、§5.11 引言、§7 第 1 条）与 README.md。
> 目标：用户可以自行选择人设（初始化时选、聊天中随时换），也可以明确选择**不用任何人设**。

---

## 1. 人设目录

| id | 文件 | 类型 | 自称 | 一句话 | 字符数 |
|---|---|---|---|---|---|
| `whale`（默认） | [../persona.md](../persona.md) | 萌系宠物 | 本鲸／人家 | 戴眼镜系围裙的小鲸，讨饭、嘴硬、炸毛、装死 | 2274 |
| `gentle` | [gentle.md](gentle.md) | 温柔治愈 | 我 | 深夜留着的一盏小灯，先听完再说话 | 1410 |
| `tsundere` | [tsundere.md](tsundere.md) | 清冷傲娇 | 本猫 | 系铃铛的黑猫，嘴硬心软，傲娇有底线 | 1424 |
| `genki` | [genki.md](genki.md) | 活泼元气 | 我 | 系三角巾的小狗，精力充沛，懂分寸 | 1440 |
| `literary` | [literary.md](literary.md) | 沉稳文艺 | 我 | 深夜书店守店人，说话慢，留白多 | 1343 |
| `none` | —（无文件） | 不用人设 | — | 只有记忆、没有角色表演的普通助手 | — |

## 2. 编写规范（新增人设须遵守）

- **四段结构**：身份与语气 / 情绪与动作 / 标志台词 / 禁止行为清单。与记忆管家硬规则 2「保留身份、自称、禁止行为清单、情绪动作和标志台词」对齐，保证聊天微调在任何卡上都能工作。
- **frontmatter `name: persona`**：每份都是 MemFS `persona.md` 槽位的即插即用替换件，description 注明类型。
- **≤2600 字符**（含 frontmatter，UTF-16 计数，与 `setup-letta.ps1` 的校验同口径）。建议 ≤2400：管家落聊天微调时要有余量。四份新卡刻意留了约 1100+ 字符余量。
- **不预设姓名**：名字留给用户取，与现有设计一致。
- **事实锚点条款收尾**：「角色表现不冒充事实……」，每张卡必须有。
- 禁止清单至少包含：不说教、自称不漂移、长对话不丢角色、真实错误如实处理。

## 3. 现状盘点（机制落点）

| 已有能力 | 位置 | 对选择机制的意义 |
|---|---|---|
| 初始化指定源文件 | `setup-letta.ps1 -PersonaPath` | 初始化选择已有入口，缺的只是"选项列表"和 `none` |
| 已存在不覆盖 | setup `Write-IfMissing` | 切换必须是显式动作，不会被初始化悄悄冲掉 |
| 核心文件缺失自动跳过 | 插件 `renderCore`（try/catch continue，空 body 也跳过） | **「不用人设」零改动可行**：MemFS 没有 persona.md 即可 |
| mtime 缓存 | 插件 `createCoreCache` | 换卡后下一轮组装自动生效，DSH 不用重启 |
| 聊天微调人设 | 管家规则 2（persona 标签笔记，增量改） | 微调与切换要分开：微调改当前卡，切换整卡替换 |
| git 历史 | MemFS 本身是 git 仓库 | 切换/停用前的旧卡（含用户微调）天然有备份，可回滚 |

## 4. 方案对比

| | A. 聊天驱动（推荐） | B. 离线切换脚本 | C. 插件配置项 |
|---|---|---|---|
| 入口 | 用户直接说"换成黑猫" | 跑 `switch-persona.ps1` | 改插件 config |
| 生效时机 | 下次整合（每天 03:00，可手动补跑 dream） | 立即 | 立即 |
| LLM 成本 | 一次整合（稀有操作，可忽略） | 0 | 0 |
| 需要改动 | setup 同步库 + 管家新规则 + MEMORY 模板 | 新脚本 + 并发保护 | 插件代码 |
| 架构一致性 | ✅ 保持「只有 Letta 写 MemFS」、单一事实源 | ⚠️ 打破单写者原则（setup 已是初始化期例外） | ❌ 双事实源：配置指一份、MemFS 一份，管家微调会与配置漂移 |

**推荐 A**：QQ 陪聊场景里"说一句话就换"是最自然的交互；库放进 MemFS 深水区后，管家照现有职责切分执行，不新增写者。B 作为要求立即生效时的备选。C 不建议。

## 5. 方案 A 详细设计

### 5.1 人设库进 MemFS（深水区）

- setup 时把仓库 `personas/*.md` 与根 `persona.md`（作为 `whale.md`）同步到 `<MemFS>/personas/`。子目录不进上下文，只通过 `memory_list / memory_read` 按需读——**不占 5600 核心预算**。
- `MEMORY.md` 索引加一行：`personas/ —— 人设库，对方要求时切换`。
- 库文件是只读源：管家只从中复制，不修改库文件本身。

### 5.2 初始化选择

- 未来参数 `-Persona <whale|gentle|tsundere|genki|literary|none>`，默认 `whale`；保留 `-PersonaPath` 兼容自定义源。
- `none`：不写 persona.md，MEMORY.md 索引去掉 persona 行。插件自然跳过，无需任何插件改动。

### 5.3 聊天切换（核心流程）

1. 用户问"有哪些人设？" → 陪聊 agent 读 MEMORY.md / `memory_list personas/` → 报选项。
2. 用户说"换成傲娇黑猫" → `memory_note(text: "对方要求把人设切换为 tsundere", tags: ["persona","switch"])`。
3. 管家见到 switch 笔记 → 读 `personas/tsundere.md` → **逐字**覆盖 `persona.md`（不改写、不"优化"、不与旧卡合并）→ git commit。
4. 用户说"不用人设了" → 管家删除 `persona.md`、更新 MEMORY.md 索引 → commit。旧卡在 git 历史里。
5. "换回小鲸" / "还是用上次的" → 同一流程；想找回微调过的旧卡，用 git 历史恢复。

生效时机：下次 dream 整合。想立即生效就手动补跑一次 `dream.ps1`（脚本本身并发安全、失败可续跑）。

### 5.4 none 模式语义

- 插件只注入 MEMORY + human：有记忆、无角色表演的普通助手。
- 管家**忽略 persona 微调笔记**，不创建 persona.md；只有用户明确说"启用人设"才重建。
- human.md / events / people / topics 照常工作，不受影响。

### 5.5 切换 vs 微调的边界

- 切换 = 整卡替换（以库文件为准）；微调 = 现有规则 2 的增量修改，继续作用于当前卡。
- 微调**不回写库**：库是出厂源，微调是用户定制，两者分离才能随时干净地换卡。
- 切换前的微调随 git 历史保留；不做自动合并（合并容易突破 2600 预算、破坏卡结构）。

### 5.6 管家新增规则要点（实现时写入 memory-curator.md）

- 只在收到明确 switch 笔记时切换；逐字复制库文件，禁止转述或改写。
- 复制后校验 ≤2600 字符，超限报错不写。
- 只动 persona.md 与 MEMORY.md；不改库源文件。
- none 模式下不创建 persona.md。
- 切换是配置不是经历：不写进 events/human（当前人设是什么，persona.md 自己就是事实源）。

## 6. 方案 B 概要（备选，立即生效）

`switch-persona.ps1 -MemoryDir <…> -Persona <id|none>`：

1. 确认 dream 未在运行（并发保护）；
2. git commit 当前 persona.md（保留微调）；
3. 复制库文件 → persona.md，或删除（none）；
4. 更新 MEMORY.md 索引，commit。

优点：0 LLM、立即生效、确定性。代价：打破「只有 Letta 写 MemFS」，需要新脚本与并发保护。适合不想等整合、或批量部署的场景。

## 7. 边界与风险

- **换卡时机**：dream 改写后 mtime 缓存下一轮自动失效，无需重启；陪聊 agent 在切换生效前仍按旧卡说话，属预期。
- **库不进核心区**：personas/ 是子目录，天然不注入；不要把它加进 `coreFiles`。
- **转述风险**：管家可能"总结"库文件而非逐字复制 → 规则强调逐字，验收时 git diff 抽查。
- **预算**：任一时刻只有一份 persona.md 进上下文，5600 总预算不变。
- **none 不是故障**：`verify.ps1` 不应把 persona 缺失报为错误（实现时核对其现有逻辑）。
- **文档同步**：实现时按仓库约定同步 HANDOFF.md §5 全文及 README / Design.md 说明。

## 8. 实现清单（本次均未执行）

- [ ] `setup-letta.ps1`：同步人设库进 MemFS + `-Persona` 参数 + none 支持
- [ ] `prompts/memory-curator.md`：切换 / 停用 / none 模式规则（§5.6）
- [ ] MEMORY.md 模板：personas/ 索引行
- [ ] （可选）`scripts/switch-persona.ps1`：方案 B
- [ ] `verify.ps1`：none 模式下 persona 缺失不误报
- [ ] HANDOFF.md / README.md / Design.md 同步