/**
 * dsh-letta-memory — 把 Letta 的 MemFS 记忆目录接进 DeepSeek Harness。
 *
 * 设计取向（与 Letta 自身的上下文模型保持一致）：
 *   - 记忆根目录下的 .md 文件（persona.md / human.md / MEMORY.md）是"常驻核心区"，
 *     注入系统提示的稳定段。文本按文件 mtime 缓存：文件不变则逐字节不变（前缀缓存命中），
 *     dream 改写后下一次组装自动生效（每天只失效一次），宿主常驻也不需要重启。
 *   - 子目录（events/、people/、topics/…）不进上下文，只能通过工具按需读取（"深水区"）。
 *   - 写入不由本插件做：DSH 只往收件箱追加原始笔记（零 LLM 成本）。收件箱在 MemFS 之外，
 *     由 dream.ps1 交给 Letta 记忆管家离线整合，管家改写 MemFS 并 git commit。
 *   - 提取日志：memory_read / memory_search 命中的深水区文件追加到收件箱旁的 recall.jsonl（零 LLM）。
 *     每周整理据此判断"用进废退"：被想起的记忆续命，长期不用的移进 archive/。
 *   - archive/ 是"可提取性降低、存储仍在"的一层：不出现在 memory_list / memory_search 里，
 *     但能被 memory_read 直接读到；被读到会记入提取日志，下次周整理时移回原处（再学习）。
 *
 * 零 @deepseek-ai 运行时依赖：宿主服务全部通过 inject 取得（与 dsh-wechat 同一模式），
 * 因此以本地目录 / link: 方式安装时不需要在插件目录 npm install。
 */
import { existsSync, readFileSync, readdirSync, statSync, appendFileSync, mkdirSync } from 'node:fs'
import { join, resolve, sep, dirname } from 'node:path'
import { homedir } from 'node:os'

/** Cordis 插件名。 */
export const name = 'letta-memory'
/** 依赖的宿主服务：提示词注册表 + 工具注册表。 */
export const inject = ['systemPrompt', 'tools']

/** 淡忘层目录名（MemFS 根下）。 */
const ARCHIVE_DIR = 'archive'

const DEFAULTS = {
  /** Letta 记忆管家 agent 的 MemFS 目录（必填，或用环境变量 LETTA_MEMORY_DIR）。 */
  memoryDir: '',
  /** 常驻核心区文件（相对 memoryDir，缺失则跳过）。 */
  coreFiles: ['MEMORY.md', 'persona.md', 'human.md'],
  /** 核心区总字符上限，超出按文件顺序截断。 */
  maxCoreChars: 5600,
  /** 系统提示段落 order（落在第一方指导之后、persona 后缀 10200 之前）。 */
  order: 1250,
  /** 是否注册记忆工具。 */
  enableTools: true,
  /** 笔记收件箱（绝对路径；留空则用 LETTA_BRIDGE_INBOX，再回退 ~/.letta-bridge/inbox/notes.jsonl）。必须在 MemFS 之外。 */
  inbox: '',
  /** 搜索时最多扫描的文件数。 */
  maxScanFiles: 400,
}

/** 解析记忆根目录：配置 → 环境变量；都没有则返回空串（不猜默认路径，猜错比不注入更糟）。 */
function resolveRoot(config) {
  const raw = config.memoryDir || process.env.LETTA_MEMORY_DIR || ''
  return raw ? resolve(raw) : ''
}

/** 解析收件箱路径：配置 → 环境变量 → ~/.letta-bridge/inbox/notes.jsonl。 */
function resolveInbox(config) {
  const raw = config.inbox || process.env.LETTA_BRIDGE_INBOX || join(homedir(), '.letta-bridge', 'inbox', 'notes.jsonl')
  return resolve(raw)
}

/** 把核心区文件渲染成一段可注入文本；全部缺失时返回空串。 */
function renderCore(root, config) {
  const parts = []
  let budget = Math.max(200, config.maxCoreChars)
  for (const rel of config.coreFiles) {
    if (budget <= 0) break
    let body
    try {
      body = readFileSync(join(root, rel), 'utf8')
    } catch {
      continue
    }
    body = body.replace(/^\uFEFF/, '').replace(/^---[\s\S]*?---\s*/, '').trim() // 去 BOM 与 YAML frontmatter
    if (!body) continue
    if (body.length > budget) body = body.slice(0, budget) + '\n…（已截断）'
    budget -= body.length
    parts.push(`### ${rel}\n${body}`)
  }
  if (parts.length === 0) return ''
  return [
    '<letta-memory>',
    '以下内容来自 Letta MemFS 的常驻记忆（persona / human / 索引）。它是既定背景，直接使用，不要复述，也不要声称"根据记忆"。',
    '更深的记忆在子目录里：需要时用 memory_list / memory_search / memory_read 查，不要凭印象编。',
    '对方透露了新的稳定事实、偏好、雷点、重要事件，或对你的说话方式提出要求时，用 memory_note 记一条。',
    '',
    parts.join('\n\n'),
    '</letta-memory>',
  ].join('\n')
}

/**
 * 核心区文本的 mtime 缓存：每次提示词组装都会调用，只做 stat，文件没变就返回同一字符串。
 * @returns 渲染函数，返回当前核心区文本（可能为空串）
 */
function createCoreCache(root, config) {
  let key = null
  let text = ''
  return () => {
    const stamp = config.coreFiles
      .map((rel) => {
        try {
          const s = statSync(join(root, rel))
          return `${s.mtimeMs}:${s.size}`
        } catch {
          return '-'
        }
      })
      .join('|')
    if (stamp !== key) {
      key = stamp
      text = renderCore(root, config)
    }
    return text
  }
}

/** 目录树（只列 .md 与一级/二级目录，够模型判断去哪找）。 */
function renderTree(root, maxDepth = 2) {
  const lines = []
  const walk = (dir, depth, prefix) => {
    if (depth > maxDepth) return
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    entries.sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name))
    for (const e of entries) {
      if (e.name.startsWith('.')) continue
      if (e.isDirectory()) {
        if (depth === 0 && e.name === ARCHIVE_DIR) {
          lines.push(`${prefix}${e.name}/（已淡忘的旧记忆，不参与检索；确有需要时 memory_read ${e.name}/<原路径>）`)
          continue
        }
        lines.push(`${prefix}${e.name}/`)
        walk(join(dir, e.name), depth + 1, prefix + '  ')
      } else if (e.name.endsWith('.md')) {
        let size = 0
        try {
          size = statSync(join(dir, e.name)).size
        } catch {}
        lines.push(`${prefix}${e.name} (${size}B)`)
      }
    }
  }
  walk(root, 0, '')
  return lines.length ? lines.join('\n') : '（记忆目录为空）'
}

/** 归一化并防止越界读取。 */
function safeJoin(root, rel) {
  const target = resolve(root, rel)
  if (target !== root && !target.startsWith(root + sep)) return null
  return target
}

/**
 * 关键词搜索：query 按空白切成多个词，文件须包含全部词；返回含任一词的行（path:line）。
 * 跳过 archive/。
 * @returns { text, files } files 为命中的相对路径（供提取日志）
 */
function searchMemory(root, query, limit, maxFiles) {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return { text: '（空查询）', files: [] }
  const hits = []
  const files = []
  let scanned = 0
  const walk = (dir) => {
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const e of entries) {
      if (hits.length >= limit || scanned >= maxFiles) return
      if (e.name.startsWith('.')) continue
      const full = join(dir, e.name)
      if (e.isDirectory()) {
        if (dir === root && e.name === ARCHIVE_DIR) continue
        walk(full)
        continue
      }
      if (!e.name.endsWith('.md')) continue
      scanned += 1
      let text
      try {
        text = readFileSync(full, 'utf8')
      } catch {
        continue
      }
      const lower = text.toLowerCase()
      if (!terms.every((t) => lower.includes(t))) continue
      const rel = full.slice(root.length + 1).replace(/\\/g, '/')
      files.push(rel)
      const lines = text.split(/\r?\n/)
      for (let i = 0; i < lines.length && hits.length < limit; i += 1) {
        const line = lines[i].toLowerCase()
        if (terms.some((t) => line.includes(t))) hits.push(`${rel}:${i + 1}: ${lines[i].trim().slice(0, 240)}`)
      }
    }
  }
  walk(root)
  const text = hits.length ? hits.join('\n') : `（没有命中「${query}」；换个说法或拆成更短的词再试）`
  return { text, files }
}

/** 追加提取日志；核心区文件常驻上下文，不算"被想起"。写失败不影响工具结果。 */
function logRecall(file, paths, config, kind) {
  const deep = paths.filter((p) => !config.coreFiles.includes(p))
  if (deep.length === 0) return
  const ts = new Date().toISOString()
  try {
    mkdirSync(dirname(file), { recursive: true })
    appendFileSync(file, deep.map((path) => JSON.stringify({ ts, path, kind })).join('\n') + '\n', 'utf8')
  } catch (err) {
    console.warn(`[letta-memory] 提取日志写入失败：${err.message}`)
  }
}

/** 统一的字符串输出声明。 */
const TEXT_OUTPUT = {
  schema: { type: 'string' },
  render: (_args, value) => [{ type: 'text', text: value }],
}

/**
 * 注册核心区段落与记忆工具。
 * @param ctx 宿主上下文
 * @param rawConfig 插件行 config
 */
export function apply(ctx, rawConfig = {}) {
  const config = { ...DEFAULTS }
  for (const [k, v] of Object.entries(rawConfig ?? {})) if (v !== undefined && v !== null) config[k] = v

  const root = resolveRoot(config)
  if (!root) {
    console.warn('[letta-memory] 未配置 memoryDir（也没有 LETTA_MEMORY_DIR），插件不生效')
    return
  }
  if (!existsSync(root)) console.warn(`[letta-memory] 记忆目录不存在：${root}（创建后自动生效）`)
  const inbox = resolveInbox(config)
  if (inbox === root || inbox.startsWith(root + sep)) {
    console.warn(`[letta-memory] 收件箱 ${inbox} 位于 MemFS 内，会被 Letta 提交进 git；请改到 MemFS 之外`)
  }
  const recallLog = join(dirname(inbox), 'recall.jsonl')

  // text 为函数：每次组装求值；interpolate:false 防止记忆里的 "{{" 被当成提示词变量导致组装失败。
  ctx.systemPrompt.section({
    name: 'letta:core-memory',
    order: config.order,
    interpolate: false,
    text: createCoreCache(root, config),
  })

  if (!config.enableTools) return

  ctx.tools.register({
    name: 'memory_list',
    description: '列出 Letta 长期记忆目录中的文件树（常驻核心之外的深水区：events/ people/ topics/ 等）。',
    parameters: { type: 'object', properties: {} },
    output: TEXT_OUTPUT,
    async execute() {
      return `根目录：${root}\n\n${renderTree(root)}`
    },
  })

  ctx.tools.register({
    name: 'memory_read',
    description: '读取 Letta 长期记忆中的一个 .md 文件（相对记忆根目录的路径）。',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: '相对路径，例如 events/2026-10-01.md' },
      },
      required: ['path'],
    },
    output: TEXT_OUTPUT,
    async execute(args) {
      const target = safeJoin(root, args.path)
      if (!target) return '拒绝：路径越界。'
      if (!existsSync(target)) return `不存在：${args.path}`
      const text = readFileSync(target, 'utf8')
      logRecall(recallLog, [target.slice(root.length + 1).replace(/\\/g, '/')], config, 'read')
      return text.length > 20000 ? text.slice(0, 20000) + '\n…（已截断）' : text
    },
  })

  ctx.tools.register({
    name: 'memory_search',
    description: '在 Letta 长期记忆中做关键词检索，返回 path:line 命中片段。多个关键词用空格分隔（同时出现才算命中）。',
    parameters: {
      type: 'object',
      properties: {
        query: { type: 'string', description: '关键词，空格分隔；中文按子串匹配，不做分词' },
        limit: { type: 'number', description: '最多返回条数，默认 10，上限 40' },
      },
      required: ['query'],
    },
    output: TEXT_OUTPUT,
    async execute(args) {
      const limit = Math.min(Math.max(args.limit ?? 10, 1), 40)
      const { text, files } = searchMemory(root, args.query, limit, config.maxScanFiles)
      logRecall(recallLog, files, config, 'search')
      return text
    },
  })

  ctx.tools.register({
    name: 'memory_note',
    description:
      '把一条值得长期保留的信息写进记忆收件箱（append-only，下次整合时由 Letta 合并进长期记忆）。' +
      '以下情况都应该记：对方说出的稳定事实（称呼、作息、家人、工作）、偏好与雷点、有日期的重要事件、' +
      '约定、关系变化、对方对你说话方式/人设的要求。一条只写一件事，用第三人称陈述句，带时间。不要记寒暄和你自己的推测。',
    parameters: {
      type: 'object',
      properties: {
        text: { type: 'string', description: '一句话事实，例如"10 月 31 日：对方说不吃香菜"' },
        tags: { type: 'array', items: { type: 'string' }, description: '可选标签，如 ["偏好","饮食"]；人设相关用 "persona"' },
      },
      required: ['text'],
    },
    output: TEXT_OUTPUT,
    async execute(args) {
      mkdirSync(dirname(inbox), { recursive: true })
      const record = { ts: new Date().toISOString(), text: args.text, tags: args.tags ?? [], source: 'dsh' }
      appendFileSync(inbox, JSON.stringify(record) + '\n', 'utf8')
      return `已入队：${record.text.slice(0, 80)}`
    },
  })
}
