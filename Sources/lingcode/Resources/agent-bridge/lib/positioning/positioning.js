'use strict';
const { repoRoot } = require('./git-log');
const { observe } = require('./observe');
const { writeProductMd, PRODUCT_MD, FIELDS } = require('./product-md');

// Flag names map onto the four questions `/positioning` asks. Separate flags
// rather than a JSON blob: a model emits `--for "..."` reliably and the shell
// handles the quoting, where nested JSON on a command line invites escaping bugs.
const FLAGS = {
  '--for': 'for',
  '--instead': 'instead',
  '--wedge': 'wedge',
  '--not-competing': 'notCompeting',
};

const USAGE = `usage: lingcode positioning <command>

  observe [--limit N]     Regenerate the '## Observed' section of ${PRODUCT_MD}
                          from git history. Never touches '## Stated'.

  stated --for X --instead Y --wedge Z --not-competing W
                          Write the '## Stated' section. Rejected unless all
                          four answers are present, including a real exclusion.

${PRODUCT_MD} is written at the repository root.`;

function parseFlags(argv) {
  const values = {};
  const unknown = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    if (FLAGS[arg]) {
      values[FLAGS[arg]] = argv[i + 1];
      i++;
    } else if (arg === '--limit') {
      values.limit = argv[i + 1];
      i++;
    } else {
      unknown.push(arg);
    }
  }
  return { values, unknown };
}

function runObserve(argv, cwd) {
  const root = repoRoot(cwd);
  if (!root) {
    return {
      code: 1,
      stdout: '',
      stderr: `positioning: ${cwd} is not a git repository. ${PRODUCT_MD} lives at a repo root, and '## Observed' is derived from commit history.\n`,
    };
  }

  const { values } = parseFlags(argv);
  const limit = parseInt(values.limit, 10) || 20;
  const block = observe(root, limit);
  const file = writeProductMd(root, { observed: block });

  return { code: 0, stdout: `${block}\nWritten to ${file}\n`, stderr: '' };
}

function runStated(argv, cwd) {
  const root = repoRoot(cwd) || cwd;
  const { values, unknown } = parseFlags(argv);

  if (unknown.length) {
    return { code: 2, stdout: '', stderr: `positioning: unknown option ${unknown[0]}\n\n${USAGE}\n` };
  }

  const answers = {};
  for (const { key } of FIELDS) answers[key] = values[key];

  try {
    const file = writeProductMd(root, { stated: answers });
    return { code: 0, stdout: `Thesis written to ${file}\n`, stderr: '' };
  } catch (err) {
    return { code: 1, stdout: '', stderr: `${err.message}\n` };
  }
}

/**
 * Run one positioning command. Returns a result rather than writing to the
 * process streams so the behaviour is testable without spawning.
 */
function run(argv, cwd) {
  const [command, ...rest] = argv;

  if (!command) return { code: 2, stdout: '', stderr: `${USAGE}\n` };
  if (command === 'observe') return runObserve(rest, cwd);
  if (command === 'stated') return runStated(rest, cwd);

  return { code: 2, stdout: '', stderr: `positioning: unknown command '${command}'\n\n${USAGE}\n` };
}

if (require.main === module) {
  const result = run(process.argv.slice(2), process.cwd());
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  process.exit(result.code);
}

module.exports = { run, USAGE };
