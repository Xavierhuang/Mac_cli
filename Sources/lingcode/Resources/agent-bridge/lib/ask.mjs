// ask.mjs — `lingcode ask` one-shot subcommand.

import process from 'node:process'

import { streamOnce } from './agent.mjs'
import { discoverAll, expandCommand } from './plugins.mjs'
import { readStdin } from './render.mjs'

export async function cmdAsk(args) {
  let providerOverride = null
  const positional = []
  const imagePaths = []
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--provider' && args[i + 1]) {
      providerOverride = args[i + 1]
      i++
    } else if (args[i] === '--image' && args[i + 1]) {
      imagePaths.push(args[i + 1])
      i++
    } else {
      positional.push(args[i])
    }
  }
  let prompt = positional.join(' ').trim()
  if (prompt === '-' || prompt === '') {
    prompt = (await readStdin()).trim()
  }
  if (!prompt) {
    console.error('lingcode ask: empty prompt.')
    process.exit(64)
  }
  // Allow one-shot use of custom slash commands: `lingcode ask "/review foo.swift"`
  // expands the same way the REPL does.
  const plugins = await discoverAll(process.cwd())
  if (prompt.startsWith('/')) {
    const expanded = expandCommand(plugins.commands, prompt)
    if (expanded !== null) prompt = expanded
  }
  try {
    await streamOnce(prompt, { providerOverride, plugins, imagePaths })
  } catch (error) {
    process.stderr.write(`lingcode: ${error.message}\n`)
    process.exit(1)
  }
}
