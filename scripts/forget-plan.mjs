// 遗忘计划（确定性，0 LLM）：根据事件重要度与"最后一次使用"算出哪些事件该淡忘、哪些该唤回。
// 本脚本只读 MemFS、只写收件箱目录里的提取索引；真正挪文件由 Letta 记忆管家执行（只有 Letta 写 MemFS）。
//
// 规则（Bjork：遗忘 = 降低可提取性，存储仍在）：
//   最后一次使用 = max(事件日期, 最后一次被 memory_read / memory_search 命中)
//   重要度 3：永不淡忘；重要度 2：闲置 > 210 天淡忘；重要度 1：闲置 > 120 天淡忘；缺省按 2
//   淡忘 = events/X.md → archive/events/X.md；已淡忘的被再次读到（闲置清零）→ 唤回 events/
//
// 用法：node forget-plan.mjs --memory-dir <MEMFS> --state-dir <收件箱目录> [--today YYYY-MM-DD] [--recent-days 7]
// 输出（stdout JSON）：{ today, archive:[{from,to}], restore:[{from,to}], recent:[path], stats }
import { existsSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const DAYS_BY_IMPORTANCE = { 1: 120, 2: 210 }
const DEFAULT_IMPORTANCE = 2
const DAY = 86400000

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, cur, i, arr) => (cur.startsWith('--') ? [...acc, [cur.slice(2), arr[i + 1]]] : acc), []),
)
const memDir = args['memory-dir']
const stateDir = args['state-dir']
if (!memDir || !stateDir) {
  console.error('用法：node forget-plan.mjs --memory-dir <MEMFS> --state-dir <收件箱目录> [--today YYYY-MM-DD]')
  process.exit(2)
}
const today = args.today ? new Date(`${args.today}T00:00:00Z`) : new Date(new Date().toISOString().slice(0, 10) + 'T00:00:00Z')
const recentDays = Number(args['recent-days'] ?? 7)

/** 把 recall.jsonl 合并进 recall-index.json（每个路径只留最后一次使用时间）。先改名再读，插件并发追加不丢。 */
function compactRecall() {
  const log = join(stateDir, 'recall.jsonl')
  const processing = join(stateDir, 'recall.processing.jsonl')
  const indexFile = join(stateDir, 'recall-index.json')
  const index = existsSync(indexFile) ? JSON.parse(readFileSync(indexFile, 'utf8')) : {}
  if (!existsSync(processing) && existsSync(log)) renameSync(log, processing)
  if (existsSync(processing)) {
    for (const line of readFileSync(processing, 'utf8').split(/\r?\n/)) {
      if (!line.trim()) continue
      let rec
      try {
        rec = JSON.parse(line)
      } catch {
        continue
      }
      const key = String(rec.path).replace(/^archive\//, '')
      if (!index[key] || rec.ts > index[key]) index[key] = rec.ts
    }
    writeFileSync(indexFile, JSON.stringify(index, null, 1))
    unlinkSync(processing)
  }
  return index
}

/** 读事件文件 frontmatter 里的 importance（1-3），缺省 2。 */
function importanceOf(file) {
  const head = readFileSync(file, 'utf8').replace(/^\uFEFF/, '').match(/^---\r?\n([\s\S]*?)\r?\n---/)
  const m = head && head[1].match(/^importance:\s*([123])\s*$/m)
  return m ? Number(m[1]) : DEFAULT_IMPORTANCE
}

function listMd(dir) {
  return existsSync(dir) ? readdirSync(dir).filter((n) => n.endsWith('.md')) : []
}

const index = compactRecall()
const plan = { today: today.toISOString().slice(0, 10), archive: [], restore: [], recent: [], stats: { events: 0, archived: 0, pinned: 0, undated: 0 } }

for (const [where, dir] of [['events', join(memDir, 'events')], ['archive', join(memDir, 'archive', 'events')]]) {
  for (const name of listMd(dir)) {
    const key = `events/${name}`
    const dated = name.match(/^(\d{4}-\d{2}-\d{2})/)
    if (where === 'events') plan.stats.events += 1
    else plan.stats.archived += 1
    if (!dated) {
      plan.stats.undated += 1 // 没有日期的文件不参与衰减（保守）
      continue
    }
    const eventDay = new Date(`${dated[1]}T00:00:00Z`)
    if (where === 'events' && today - eventDay < recentDays * DAY && eventDay <= today) plan.recent.push(key)

    const importance = importanceOf(join(dir, name))
    if (importance === 3) {
      plan.stats.pinned += 1
      if (where === 'archive') plan.restore.push({ from: `archive/${key}`, to: key })
      continue
    }
    const lastUse = Math.max(eventDay.getTime(), index[key] ? Date.parse(index[key]) : 0)
    const idleDays = Math.floor((today - lastUse) / DAY)
    const fade = idleDays > DAYS_BY_IMPORTANCE[importance]
    if (where === 'events' && fade) plan.archive.push({ from: key, to: `archive/${key}`, importance, idleDays })
    if (where === 'archive' && !fade) plan.restore.push({ from: `archive/${key}`, to: key, importance, idleDays })
  }
}

plan.recent.sort()
process.stdout.write(JSON.stringify(plan, null, 1))
