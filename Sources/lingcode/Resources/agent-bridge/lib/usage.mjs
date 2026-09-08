// usage.mjs — token + cost display after each REPL turn.
//
// Cost estimates use rough USD-per-million-token rates pulled from each
// provider's public pricing page as of late 2025. They drift; treat the
// number as ballpark, not invoice-grade. When a model isn't in the table
// we fall back to '?' for cost and just show token counts.
//
// Pricing format: { in: <USD/M input tokens>, out: <USD/M output tokens> }

const PRICING = {
  // Anthropic — Opus 4.6+ dropped to $5/$25 (was $15/$75 on Opus 4.x originals).
  // Verified against https://platform.claude.com/docs/en/about-claude/models/overview
  // Fable 5.1 matches Fable 5 on input/output; its headline saving is a $0.25/M
  // cache-read rate, which this table doesn't model (no cache-token column).
  'claude-fable-5-1':       { in: 10.00, out: 50.00 },
  'claude-fable-5':         { in: 10.00, out: 50.00 },
  'claude-opus-5':          { in: 5.00,  out: 25.00 },
  'claude-sonnet-5':        { in: 2.00,  out: 10.00 },
  'claude-opus-4-8':        { in: 5.00,  out: 25.00 },
  'claude-opus-4-7':        { in: 5.00,  out: 25.00 },
  'claude-opus-4-6':        { in: 5.00,  out: 25.00 },
  'claude-opus-4-5':        { in: 5.00,  out: 25.00 },
  'claude-opus-4-1':        { in: 15.00, out: 75.00 },
  'claude-opus-4':          { in: 15.00, out: 75.00 },
  'claude-sonnet-4-6':      { in: 3.00,  out: 15.00 },
  'claude-sonnet-4':        { in: 3.00,  out: 15.00 },
  'claude-haiku-4-5':       { in: 1.00,  out: 5.00 },
  'claude-haiku-4':         { in: 1.00,  out: 5.00 },
  'claude-3-5-sonnet':      { in: 3.00,  out: 15.00 },
  'claude-3-5-haiku':       { in: 0.80,  out: 4.00 },

  // OpenAI
  // Verified 2026-09-07; GPT-5.6 rates promotional through >= 2026-11-21.
  'gpt-6-astra':            { in: 10.00, out: 50.00 },
  'gpt-5.6-sol':            { in: 4.00,  out: 20.00 },
  'gpt-5.6-terra':          { in: 2.00,  out: 12.00 },
  'gpt-5.6-luna':           { in: 0.20,  out: 1.20 },
  'gpt-4o':                 { in: 2.50,  out: 10.00 },
  'gpt-4o-mini':            { in: 0.15,  out: 0.60 },
  'gpt-4.1':                { in: 2.00,  out: 8.00 },
  'gpt-4.1-mini':           { in: 0.40,  out: 1.60 },
  'gpt-4-turbo':            { in: 10.00, out: 30.00 },
  'o1':                     { in: 15.00, out: 60.00 },
  'o1-mini':                { in: 3.00,  out: 12.00 },
  'o3-mini':                { in: 1.10,  out: 4.40 },

  // DeepSeek
  'deepseek-chat':          { in: 0.27,  out: 1.10 },
  'deepseek-reasoner':      { in: 0.55,  out: 2.19 },
  'deepseek-v4-flash':      { in: 0.10,  out: 0.40 },
  'deepseek-v4-pro':        { in: 0.40,  out: 1.60 },

  // Gemini
  'gemini-2.0-flash':       { in: 0.10,  out: 0.40 },
  'gemini-1.5-pro':         { in: 1.25,  out: 5.00 },
  'gemini-1.5-flash':       { in: 0.075, out: 0.30 },

  // Groq (cheap fast)
  'llama-3.3-70b-versatile': { in: 0.59, out: 0.79 },
  'llama-3.1-70b-versatile': { in: 0.59, out: 0.79 },
  'llama-3.1-8b-instant':   { in: 0.05,  out: 0.08 },

  // xAI
  'grok-2-latest':          { in: 2.00,  out: 10.00 },

  // Kimi
  'moonshot-v1-32k':        { in: 1.40,  out: 2.10 },
  'moonshot-v1-128k':       { in: 1.68,  out: 2.52 },

  // Mistral
  'mistral-large-latest':   { in: 2.00,  out: 6.00 },
  'codestral-latest':       { in: 0.30,  out: 0.90 },
}

function lookupPricing(model) {
  if (!model) return null
  if (PRICING[model]) return PRICING[model]
  // Allow loose matching: 'gpt-4o-2024-08-06' → 'gpt-4o' etc.
  const lower = model.toLowerCase()
  for (const [key, price] of Object.entries(PRICING)) {
    if (lower.startsWith(key.toLowerCase())) return price
  }
  return null
}

function abbrev(n) {
  if (!Number.isFinite(n)) return '?'
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M'
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'k'
  return String(n)
}

function formatCost(usd) {
  if (!Number.isFinite(usd)) return null
  if (usd < 0.0001) return '<$0.0001'
  if (usd < 0.01) return `$${usd.toFixed(4)}`
  return `$${usd.toFixed(3)}`
}

// Build the dim one-liner shown after each REPL turn / one-shot ask.
// Returns null when there's not enough info to be useful (e.g. provider
// didn't return usage).
export function formatUsageLine({ model, inputTokens, outputTokens, cacheCreateTokens = 0, cacheReadTokens = 0 }) {
  if (!Number.isFinite(inputTokens) && !Number.isFinite(outputTokens)) return null
  const parts = []
  if (Number.isFinite(inputTokens)) parts.push(`in ${abbrev(inputTokens)}`)
  if (Number.isFinite(outputTokens)) parts.push(`out ${abbrev(outputTokens)}`)
  if (cacheReadTokens > 0) parts.push(`cache ${abbrev(cacheReadTokens)}`)
  const price = lookupPricing(model)
  if (price) {
    // Cache reads typically cost 10% of input; cache writes 25% more. Use a
    // simple effective-input model that hugs the conservative side.
    const effectiveIn = (inputTokens || 0) + cacheCreateTokens * 1.25 + cacheReadTokens * 0.1
    const cost = (effectiveIn / 1e6) * price.in + (outputTokens || 0) / 1e6 * price.out
    const formatted = formatCost(cost)
    if (formatted) parts.push(formatted)
  }
  if (model) parts.push(model)
  return parts.join(' · ')
}

// Extract usage info from a claude-agent-sdk `result` message.
export function usageFromAnthropicResult(result) {
  if (!result) return null
  const u = result.usage || result.message?.usage || null
  if (!u) return null
  return {
    model: result.model || null,
    inputTokens: u.input_tokens,
    outputTokens: u.output_tokens,
    cacheCreateTokens: u.cache_creation_input_tokens || 0,
    cacheReadTokens: u.cache_read_input_tokens || 0,
  }
}

// Extract usage info from an OpenAI-compat final SSE chunk (or the
// non-streaming response shape — same field names).
export function usageFromOpenAICompat(usage, model) {
  if (!usage) return null
  return {
    model: model || null,
    inputTokens: usage.prompt_tokens,
    outputTokens: usage.completion_tokens,
  }
}
