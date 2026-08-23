const CLAUDE_EFFORTS = new Set(['low', 'medium', 'high', 'xhigh', 'max'])

export function normalizeClaudeEffort(value) {
  return typeof value === 'string' && CLAUDE_EFFORTS.has(value) ? value : 'high'
}

export function claudeEffortOption(value) {
  return { effort: normalizeClaudeEffort(value) }
}
