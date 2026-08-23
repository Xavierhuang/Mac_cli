'use strict';
const { themesForFiles, themeForPath } = require('./themes');

/**
 * Aggregate commits into per-theme counts plus the themes that exist in the
 * working tree but saw no commits in the window. That second list is the
 * interesting one: "onboarding untouched" is the observation a user reacts to.
 *
 * `treeFiles` is the output of `git ls-files` — pass [] to skip untouched
 * detection.
 */
function summarize(commits, treeFiles) {
  const counts = new Map();
  for (const c of commits) {
    for (const t of themesForFiles(c.files)) {
      counts.set(t, (counts.get(t) || 0) + 1);
    }
  }

  // Descending by count, then alphabetical — stable output matters because this
  // block gets committed to PRODUCT.md and would otherwise churn the diff.
  const byTheme = [...counts.entries()]
    .map(([theme, commitCount]) => ({ theme, commits: commitCount }))
    .sort((a, b) => b.commits - a.commits || a.theme.localeCompare(b.theme));

  const inTree = new Set();
  for (const f of treeFiles || []) {
    const t = themeForPath(f);
    if (t) inTree.add(t);
  }
  const untouched = [...inTree].filter((t) => !counts.has(t)).sort();

  const dates = commits.map((c) => c.date).filter(Boolean).sort();
  const window = dates.length
    ? { from: dates[0], to: dates[dates.length - 1], commits: commits.length }
    : null;

  return { totalCommits: commits.length, byTheme, untouched, window };
}

module.exports = { summarize };
