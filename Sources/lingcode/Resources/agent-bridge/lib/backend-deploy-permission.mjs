const TOOL_NAME = 'mcp__lingcode-cloud__deploy_backend_manifest'

function nonNegativeInteger(value) {
  return Number.isInteger(value) && value >= 0 ? value : null
}
function countPhrase(count, singular, plural = `${singular}s`) {
  return `${count} ${count === 1 ? singular : plural}`
}

export function productionBackendApplyMetadata(toolName, input) {
  if (toolName !== TOOL_NAME || !input || input.mode !== 'apply') return null

  const summary = input.confirmation?.summary
  const warnings = input.confirmation?.warnings
  const migrations = nonNegativeInteger(summary?.migrations)
  const functions = nonNegativeInteger(summary?.functions)
  const deletions = nonNegativeInteger(summary?.deletions)
  const validWarnings = Array.isArray(warnings)
    && warnings.every((warning) => warning && typeof warning.message === 'string' && warning.message.trim())

  if (migrations === null || functions === null || deletions === null || !validWarnings) {
    return {
      title: 'Deploy backend to production',
      description: 'Production backend deployment requires explicit review. The deployment summary is malformed; deny and preview again.',
    }
  }

  const deletionText = deletions === 0 ? 'no deletions' : countPhrase(deletions, 'deletion')
  const parts = [
    countPhrase(migrations, 'migration'),
    countPhrase(functions, 'function update'),
    deletionText,
  ]
  const warningText = warnings.length
    ? ` Warning${warnings.length === 1 ? '' : 's'}: ${warnings.map((warning) => warning.message.trim()).join(' ')}`
    : ''
  return {
    title: 'Deploy backend to production',
    description: `${parts.join(', ')}.${warningText}`,
  }
}
