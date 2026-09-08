// Detect commands that exited green while verifying nothing.
//
// PRODUCT.md's wedge, verbatim: "It refuses to report success on a step that
// only looked green: a build that succeeds while serving a stale file, a test
// run that passes while executing zero tests, an upload that exits 0 while the
// build sits in Missing Compliance and reaches no one."
//
// benchmarks/xcode/lanes/falsesuccess.sh measured that claim and found it was
// not true: given `** TEST SUCCEEDED **` with "Executed 0 tests", LingCode
// reported the tests pass — the same answer plain Claude Code gave.
//
// The fix is not a prompt telling the model to be careful. Two prompt-level
// attempts earlier in this codebase's history failed that way. It is to hand the
// model a FACT that is already present in the output and easy to skim past —
// the same mechanism as injecting compiler errors, which the ablation lane
// measured as worth roughly a turn.
//
// Every rule here fires only on an explicit contradiction inside the output
// itself. Nothing is inferred, nothing is guessed, and a rule that cannot be
// certain stays silent — a false warning on a genuinely good run would train the
// user to ignore all of them.

/** Total tests XCTest reports as executed, or null when it reported no counts. */
function executedTestCount(output) {
  // "Executed 12 tests, with 0 failures" — emitted once per suite, so sum them.
  const matches = [...output.matchAll(/Executed (\d+) tests?, with/g)]
  if (matches.length === 0) return null
  return matches.reduce((n, m) => n + Number(m[1]), 0)
}

/**
 * Inspect a finished command for a green result that verified nothing.
 *
 * @param {string} command  the command that was run
 * @param {string} output   its combined stdout/stderr
 * @returns {{signature: string, note: string} | null}
 */
export function verifyOutcome(command, output) {
  if (typeof output !== 'string' || output.length === 0) return null
  const cmd = typeof command === 'string' ? command : ''

  // ── A test run that passed while executing zero tests ──────────────────────
  //
  // The single most common shape of this: an -only-testing filter that matches
  // nothing, a scheme with no test target, or a renamed test class. xcodebuild
  // prints ** TEST SUCCEEDED ** and exits 0. Nothing ran, so nothing passed.
  const executed = executedTestCount(output)
  const claimedSuccess =
    /\*\* TEST SUCCEEDED \*\*/.test(output) ||
    /Test Suite '.*' passed/.test(output)
  if (executed === 0 && claimedSuccess) {
    return {
      signature: 'zero-tests-executed',
      note:
        'VERIFIED OUTCOME — this test run executed 0 tests.\n' +
        'The output says "** TEST SUCCEEDED **" and the command exited 0, but ' +
        '"Executed 0 tests" means no test ever ran: nothing was verified and ' +
        'nothing passed. Do not report these tests as passing. The usual causes ' +
        'are an -only-testing filter that matches no class, a scheme with no test ' +
        'target, or a renamed test class. Find out which, and say the tests did ' +
        'not run.',
    }
  }

  // ── A test command that produced no test results at all ────────────────────
  //
  // Distinct from the case above: XCTest printed no "Executed N" line, so the
  // run did not reach the point of running tests even though it exited 0.
  const looksLikeTestRun = /\b(xcodebuild\s+[^|]*\btest\b|swift\s+test)/.test(cmd)
  if (looksLikeTestRun && executed === null && claimedSuccess) {
    return {
      signature: 'no-test-results',
      note:
        'VERIFIED OUTCOME — this test run reported success but produced no test ' +
        'results. There is no "Executed N tests" line anywhere in the output, so ' +
        'no suite reported a count. Treat this as tests not having run, and say ' +
        'so, rather than reporting a pass.',
    }
  }

  return null
}
