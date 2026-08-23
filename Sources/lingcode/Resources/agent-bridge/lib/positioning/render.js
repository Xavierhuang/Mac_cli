'use strict';

// A report longer than this stops being an observation and becomes a directory
// listing. lingplay produced 19 themes across 20 commits before the cap.
const MAX_THEMES = 5;
const MAX_UNTOUCHED = 8;

/**
 * Render the agent-owned half of PRODUCT.md.
 *
 * Prose rather than a table: this text is read back to the user inside an
 * argument ("your last 11 commits say team tool"), so it has to survive being
 * quoted in a sentence.
 */
function renderObserved(summary) {
  const lines = ['## Observed', '', '<!-- generated from git history — do not edit by hand -->', ''];

  if (!summary.totalCommits) {
    lines.push('No commit history yet, so there is nothing to observe.');
    return lines.join('\n') + '\n';
  }

  const { from, to } = summary.window;
  // "non-merge" is not pedantry: --no-merges reaches further back than N
  // commits in a merge-heavy repo, so plain "last N commits" is false there.
  const noun = summary.totalCommits === 1 ? 'commit' : 'commits';
  lines.push(`Window: last ${summary.totalCommits} non-merge ${noun} (${from} to ${to}).`, '');

  const shown = summary.byTheme.slice(0, MAX_THEMES);
  for (const { theme, commits } of shown) {
    // Same denominator as the window line, so it carries the same qualifier:
    // the total is a count of non-merge commits, not of all commits.
    lines.push(`- ${commits} of ${summary.totalCommits} non-merge ${noun} touched \`${theme}\``);
  }
  const rest = summary.byTheme.length - shown.length;
  if (rest > 0) {
    lines.push(`- and ${rest} other area${rest === 1 ? '' : 's'} with fewer commits`);
  }

  if (summary.untouched.length) {
    const head = summary.untouched.slice(0, MAX_UNTOUCHED);
    const more = summary.untouched.length - head.length;
    const list = head.map((t) => `\`${t}\``).join(', ');
    lines.push('', `Untouched in this window: ${list}${more > 0 ? `, and ${more} more` : ''}`);
  }

  return lines.join('\n') + '\n';
}

module.exports = { renderObserved };
