'use strict';
const { readCommits, listTrackedFiles, repoRoot } = require('./git-log');
const { summarize } = require('./summarize');
const { renderObserved } = require('./render');

/**
 * Produce the `## Observed` markdown for the repo containing `cwd`.
 *
 * Both git calls are resolved to the repository root first. `git log` reports
 * repo-root-relative paths while `git ls-files` reports cwd-relative ones, so
 * running from a subdirectory used to compare two different namespaces and
 * report directories as untouched that the last commit had just touched.
 */
function observe(cwd, limit = 20) {
  const root = repoRoot(cwd);
  if (!root) return renderObserved({ totalCommits: 0, byTheme: [], untouched: [], window: null });
  return renderObserved(summarize(readCommits(root, limit), listTrackedFiles(root)));
}

if (require.main === module) {
  const cwd = process.argv[2] || process.cwd();
  const limit = parseInt(process.argv[3], 10) || 20;
  process.stdout.write(observe(cwd, limit));
}

module.exports = { observe };
