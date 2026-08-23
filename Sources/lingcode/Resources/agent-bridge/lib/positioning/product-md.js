'use strict';
const fs = require('node:fs');
const path = require('node:path');

const PRODUCT_MD = 'PRODUCT.md';
const STATED_HEADING = '## Stated';
const OBSERVED_HEADING = '## Observed';

/**
 * The four questions, in the order `/positioning` asks them. Question 4 is the
 * one users skip and the only one that can generate a disagreement later, so a
 * thesis without it is rejected rather than saved half-finished.
 */
const FIELDS = [
  { key: 'for', label: 'For' },
  { key: 'instead', label: 'Instead of us they use' },
  { key: 'wedge', label: 'Wedge' },
  { key: 'notCompeting', label: 'Explicitly not competing on' },
];

// Answers that pass a presence check while meaning "I skipped this". Applied to
// question 4 only: "nothing" is a real answer to what users do today (the spec
// reads it as "they do not have the problem"), but as an exclusion it is empty.
const NON_ANSWERS = new Set([
  'nothing', 'none', 'na', 'nil', 'tbd', 'unknown', 'unsure', 'idk',
  'notsure', 'everything', 'anything', 'dunno',
]);

/**
 * Locate every `##` section, ignoring headings inside fenced code blocks. A user
 * writing `## Stated` by hand may paste a fenced markdown example; treating the
 * text inside it as a heading would silently truncate their section.
 */
function findSections(md) {
  const lines = String(md).split('\n');
  const sections = [];
  let inFence = false;

  for (let i = 0; i < lines.length; i++) {
    if (/^\s*(```|~~~)/.test(lines[i])) {
      inFence = !inFence;
      continue;
    }
    if (!inFence && /^##\s+/.test(lines[i])) {
      sections.push({ heading: lines[i].trim(), start: i });
    }
  }
  for (let i = 0; i < sections.length; i++) {
    sections[i].end = i + 1 < sections.length ? sections[i + 1].start : lines.length;
  }
  return { lines, sections };
}

/** Exactly one trailing newline, so regeneration never churns the diff. */
function normalize(md) {
  return md.replace(/\n+$/, '') + '\n';
}

/**
 * Insert or replace one `##` section, leaving every other byte of the document
 * alone. This is what keeps the two halves of PRODUCT.md independently owned:
 * regenerating `## Observed` must not disturb a hand-edited `## Stated`.
 *
 * `opts.before` names a section to insert ahead of when this one is absent.
 */
function upsertSection(md, heading, body, opts = {}) {
  const bodyLines = normalize(String(body)).replace(/\n$/, '').split('\n');

  if (!String(md).trim()) return normalize(bodyLines.join('\n'));

  const { lines, sections } = findSections(md);
  const target = sections.find((s) => s.heading === heading);

  if (target) {
    return normalize([
      ...lines.slice(0, target.start),
      ...bodyLines,
      '',
      ...lines.slice(target.end),
    ].join('\n'));
  }

  const anchor = opts.before && sections.find((s) => s.heading === opts.before);
  if (anchor) {
    return normalize([
      ...lines.slice(0, anchor.start),
      ...bodyLines,
      '',
      ...lines.slice(anchor.start),
    ].join('\n'));
  }

  return normalize([...lines, ...bodyLines].join('\n'));
}

/**
 * Check a thesis before it reaches disk. Enforcement lives here rather than in
 * the skill prompt because a prompt-level rule degrades silently on weaker
 * models, and the spec is explicit that a positioning with no "not this" cannot
 * produce a contradiction — which makes the rest of the system inert.
 */
function validateStated(answers) {
  const a = answers || {};
  const missing = [];

  for (const { key } of FIELDS) {
    const value = String(a[key] == null ? '' : a[key]).trim();
    if (!value) {
      missing.push(key);
      continue;
    }
    if (key === 'notCompeting' && NON_ANSWERS.has(value.toLowerCase().replace(/[^a-z0-9]/gi, ''))) {
      missing.push(key);
    }
  }

  if (!missing.length) return { ok: true, missing: [], message: '' };

  const labels = missing.map((k) => FIELDS.find((f) => f.key === k).label);
  const message =
    `PRODUCT.md not written. The thesis is missing: ${labels.join(', ')}.` +
    (missing.includes('notCompeting')
      ? '\n\n"Explicitly not competing on" needs a real exclusion — something you are' +
        ' deliberately not doing. Without one, no future request can ever contradict' +
        ' this thesis, and the agent has nothing to flag.'
      : '');

  return { ok: false, missing, message };
}

/** Render the user-owned half. */
function renderStated(answers) {
  const lines = [
    STATED_HEADING,
    '',
    '<!-- yours to edit — the agent reads this and never rewrites it -->',
    '',
  ];
  for (const { key, label } of FIELDS) {
    lines.push(`${label}: ${String(answers[key]).trim()}`);
  }
  return lines.join('\n') + '\n';
}

/**
 * Write PRODUCT.md at `dir`, updating only the sections supplied. Validation
 * runs before anything touches disk, so a rejected thesis leaves no file behind.
 */
function writeProductMd(dir, { stated, observed } = {}) {
  if (stated) {
    const result = validateStated(stated);
    if (!result.ok) throw new Error(result.message);
  }

  const file = path.join(dir, PRODUCT_MD);
  let md = '';
  try {
    md = fs.readFileSync(file, 'utf8');
  } catch (_) {
    md = '';
  }

  if (stated) {
    md = upsertSection(md, STATED_HEADING, renderStated(stated), { before: OBSERVED_HEADING });
  }
  if (observed) {
    md = upsertSection(md, OBSERVED_HEADING, observed);
  }

  // Write-then-rename so an interrupted run cannot leave a half-written thesis.
  const tmp = path.join(dir, `.${PRODUCT_MD}.tmp`);
  fs.writeFileSync(tmp, md, 'utf8');
  fs.renameSync(tmp, file);
  return file;
}

module.exports = {
  upsertSection,
  validateStated,
  renderStated,
  writeProductMd,
  findSections,
  PRODUCT_MD,
  STATED_HEADING,
  OBSERVED_HEADING,
  FIELDS,
};
