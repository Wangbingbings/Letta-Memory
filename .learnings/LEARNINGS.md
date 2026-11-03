# Learnings

## [LRN-20261101-001] correction

**Logged**: 2026-11-01
**Priority**: high
**Status**: resolved
**Area**: docs

### Summary
Evaluate the project's intrinsic usefulness before repository publication hygiene when asked about open-source value.

### Details
The user clarified that the initial audit overemphasized licensing, Git setup, and release preparation. Their main concern is whether the memory bridge itself offers useful capabilities, meaningful differentiation, and reliable outcomes.

### Suggested Action
Lead with the problem solved, architectural tradeoffs, memory quality limitations, and evidence needed to establish incremental value over a simpler baseline. Keep publication mechanics secondary.

### Metadata
- Source: user_feedback
- Related Files: README.md, plugin/lib/index.js, scripts/forget-plan.mjs
- Tags: project-evaluation, open-source-value

## [LRN-20261101-002] correction

**Logged**: 2026-11-01
**Priority**: high
**Status**: resolved
**Area**: tests

### Summary
A rejected feature flag does not establish that the corresponding backend capability is unavailable.

### Details
Letta local mode rejected explicit --memfs because that CLI flag requires remoteMemfs. Inspection showed LocalBackend has localMemfs=true and startup automatically enables local memory without the flag. Both experimental agents had native Git memory directories. The prior claim that local native MemFS was unavailable was incorrect. The evaluator chose a separate external directory, so its approval-related commit failure cannot establish failure of native memory commits.

### Suggested Action
Check the exact flag guard, backend capability declarations, automatic startup branches, and actual artifacts before changing an experiment architecture. Keep observation separate from inferred cause and scope findings to the actual path tested.

### Metadata
- Source: conversation
- Related Files: eval/run-model-comparison.mjs, eval/review-model-run.mjs, memory/memory-comparison.md（这些评测脚本与文档已废弃并从仓库移除）
- Tags: capability-checks, experiment-validity, letta, memfs
