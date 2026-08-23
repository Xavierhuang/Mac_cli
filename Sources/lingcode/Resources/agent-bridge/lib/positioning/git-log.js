'use strict';
const { execFileSync } = require('node:child_process');

// Generated code or a vendored-dependency bump can make one commit's file list
// enormous. The default 1 MB would throw, and a throw here used to be reported
// to the user as "no commit history" on a repo with full history.
const MAX_BUFFER = 64 * 1024 * 1024;

/**
 * Run git with path quoting disabled. Without core.quotePath=false git emits
 * non-ASCII paths octal-escaped and wrapped in literal quotes, which turns
 * `src/café/x.js` into `"src/caf\303\251/x.js"` — the leading quote then becomes
 * part of the first path segment and invents a theme called `"src`.
 */
function git(cwd, args) {
  return execFileSync('git', ['-c', 'core.quotePath=false', ...args], {
    cwd, encoding: 'utf8', maxBuffer: MAX_BUFFER, stdio: ['ignore', 'pipe', 'ignore'],
  });
}

/** Absolute path to the repository root, or null if `cwd` is not in a repo. */
function repoRoot(cwd) {
  try {
    return git(cwd, ['rev-parse', '--show-toplevel']).trim() || null;
  } catch (_) {
    return null;
  }
}

/**
 * Read the last `limit` non-merge commits with their changed file paths,
 * newest first. Returns [] when `cwd` is not a repo or has no commits.
 *
 * Two git calls per commit rather than one parsed stream: a single stream needs
 * a record separator, and no byte is safe as one because commit subjects are
 * arbitrary. A crafted subject containing the separator used to split into two
 * records, fabricating a commit with an invented sha and date. Commit subjects
 * are not read at all now — nothing downstream used them, and carrying them was
 * the whole reason a parser existed.
 */
function readCommits(cwd, limit = 20) {
  const root = repoRoot(cwd);
  if (!root) return [];
  const n = Number.isInteger(limit) && limit > 0 ? limit : 20;

  let header;
  try {
    // %cd, not %ad: ordering is by commit date, so author date would misreport
    // the window for rebased or cherry-picked history.
    header = git(root, ['log', `-n${n}`, '--no-merges', '--format=%h%x09%cd', '--date=short']);
  } catch (_) {
    return [];
  }

  return header.split('\n').map((l) => l.trim()).filter(Boolean).map((row) => {
    const [sha, date] = row.split('\t');
    let files = [];
    try {
      files = git(root, ['show', '--name-only', '--format=', sha])
        .split('\n').map((s) => s.trim()).filter(Boolean);
    } catch (_) {
      files = [];
    }
    return { sha, date, files };
  });
}

/** Every tracked file, repo-root-relative. [] if `cwd` is not a repo. */
function listTrackedFiles(cwd) {
  const root = repoRoot(cwd);
  if (!root) return [];
  try {
    return git(root, ['ls-files']).split('\n').filter(Boolean);
  } catch (_) {
    return [];
  }
}

module.exports = { readCommits, listTrackedFiles, repoRoot };
