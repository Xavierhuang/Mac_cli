'use strict';

// Directory names that describe layout rather than subject matter. A commit in
// `src/team/` is about teams; a commit in `src/` is about nothing in particular.
//
// Test and build directories are on this list because they are layers too: a
// repo that keeps `test/ai/` and `test/audio/` is telling you about ai and
// audio, not about testing. Validation against lingplay ranked "touched test"
// as its loudest claim, which described where files live rather than what the
// work was about.
const STRUCTURAL = new Set([
  'src', 'app', 'lib', 'source', 'packages', 'apps', 'components',
  'test', 'tests', 'spec', 'specs', '__tests__', 'e2e',
  'dist', 'build', 'out', 'target', 'node_modules', 'vendor',
]);

// Directory names that are build artifacts wearing a folder's clothes. Every
// commit to an Xcode project touches the .xcodeproj bundle, so counting it
// produces "2 of 2 commits touched Roomlet.xcodeproj" — true, and worthless.
const BUNDLE = /\.(xcodeproj|xcworkspace|app|framework|bundle|playground|lproj)$/i;

/**
 * Fold a test target into the subject it tests: `EventDiscoveryTests` is not a
 * separate concern from `EventDiscovery`, and splitting them halves the count
 * for the thing the user actually worked on.
 */
function normalizeTheme(name) {
  // Plural only: `EventDiscoveryTests` is a test target for EventDiscovery, but
  // `SmokeTest` is a subject in its own right.
  const folded = name.replace(/Tests$/, '');
  return folded || name;
}

/**
 * The theme of a path is its first segment that names a subject rather than a
 * layer. Deterministic and explainable on purpose: a user must be able to look
 * at "11 commits touched team" and check it by reading the paths themselves.
 * Returns null for build artifacts and for files sitting above any subject.
 */
function themeForPath(p) {
  const parts = String(p).split('/').filter(Boolean);
  if (parts.some((seg) => BUNDLE.test(seg))) return null;
  let i = 0;
  while (i < parts.length - 1 && STRUCTURAL.has(parts[i].toLowerCase())) i++;
  if (i >= parts.length - 1) return null;
  return normalizeTheme(parts[i]);
}

/** Unique, sorted themes across a commit's changed files. */
function themesForFiles(files) {
  const set = new Set();
  for (const f of files || []) {
    const t = themeForPath(f);
    if (t) set.add(t);
  }
  return [...set].sort();
}

module.exports = { themeForPath, themesForFiles, STRUCTURAL, BUNDLE };
