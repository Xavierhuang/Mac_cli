// cloud-deploy-tools.mjs — LOCAL (client-side) MCP tools for the lingcode-cloud proxy.
//
// Every other lingcode-cloud tool is served by the remote account MCP endpoint and
// simply forwarded by lingcode-cloud-mcp.mjs. Deploy can't work that way: publishing
// an app means reading the user's BUILT OUTPUT off local disk, and the remote server
// has no access to it. So these tools are implemented here, inside the stdio proxy,
// which already runs on the user's machine with their token.
//
// Division of labour: the AGENT runs the build (it has Bash and knows the project's
// framework). These tools only package the finished directory, upload it, and report
// the URL. That deliberately keeps the ~1700 lines of framework detection and
// OpenNext/wrangler reshaping in CloudDeployService.swift out of scope — the static
// tier is what an agent can drive correctly today.
//
// Wire protocol matched to LingCode/Services/Deploy/CloudDeployService.swift `upload()`:
// a gzip'd tar of the directory CONTENTS as the raw request body (not multipart),
// POST to create / PUT /:id to redeploy, `{ id, url }` back.

import { spawn } from 'node:child_process';
import { readdir, stat, readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { realpath } from 'node:fs/promises';
import path from 'node:path';

// Server-side limits, mirrored from website/server/cloud-apps.js so the agent gets a
// clear local failure instead of eating a round-trip and a 4xx it can't act on.
export const MAX_FILES = 2000;
export const TITLE_MAX = 120;
// nginx caps /api/ bodies at 60m; stay under it with room for headers.
export const MAX_BUNDLE_BYTES = 55 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Project-kind detection
// ---------------------------------------------------------------------------
//
// Without this the only discriminator is "does the directory contain index.html",
// which is a BUNDLE check, not a PROJECT check. An agent pointed at an iOS or
// Android repo would run a full build and then be told "Bundle has no index.html
// at its root" — true, useless, and hiding the real answer (Cloud hosts web apps).
//
// RULE TABLE — evaluated in this order, first match wins. Mirrored in
// CloudDeployService.nativeProjectKind(for:) (the Deploy button is Swift, this tool
// is Node — no shared runtime), and the two must change together.
//
//   mobile-web  flutter in pubspec.yaml | expo dep | capacitor | ionic  → deploy + SAY SO
//   native-ios      *.xcodeproj / *.xcworkspace / Package.swift          → refuse early
//   native-android  settings.gradle / build.gradle / AndroidManifest.xml → refuse early
//   native-rn       react-native dep without expo                        → refuse early
//   other       everything else → deploy
//
// mobile-web is FIRST. A Flutter or Expo project also carries android/ and ios/
// folders, and a Capacitor project is a genuine web app — in every case the useful
// outcome is to deploy the web build while naming what it is, never to let the
// native folders shadow it into a refusal.
//
// There is deliberately NO positive "is this a web project" rule here, though the
// Swift side has one. Whether the REPO looks like a web project is the wrong
// question — a native repo can hold a real web app in web/ or apps/site/. deployApp
// asks the precise question instead: does the directory being deployed contain the
// entry HTML? That is both more accurate and one less copy of Swift's framework
// list to drift out of sync.

export const PROJECT_KIND = {
  mobileWeb: 'mobile-web',
  nativeIOS: 'native-ios',
  nativeAndroid: 'native-android',
  nativeRN: 'native-rn',
  other: 'other',
};

const NATIVE_KINDS = new Set([PROJECT_KIND.nativeIOS, PROJECT_KIND.nativeAndroid, PROJECT_KIND.nativeRN]);
export function isNativeKind(kind) { return NATIVE_KINDS.has(kind); }

async function exists(p) { try { await access(p); return true; } catch { return false; } }

async function readJSONIfAny(p) {
  try { return JSON.parse(await readFile(p, 'utf8')); } catch { return null; }
}

/**
 * Classify the project at `workspace`. Filesystem reads only — no network, no
 * spawning. Returns `{ kind, marker, label }` where `marker` is the file or
 * dependency that decided it, so a refusal can say WHY rather than just "no".
 */
export async function detectProjectKind(workspace) {
  const at = (...p) => path.join(workspace, ...p);
  const entries = await readdir(workspace).catch(() => []);
  const pkg = await readJSONIfAny(at('package.json'));
  const deps = {
    ...((pkg && pkg.dependencies) || {}),
    ...((pkg && pkg.devDependencies) || {}),
  };
  const hasDep = (n) => Object.prototype.hasOwnProperty.call(deps, n);

  // --- mobile-web (first: native folders must not shadow a real web target) ---
  if (await exists(at('pubspec.yaml'))) {
    const spec = await readFile(at('pubspec.yaml'), 'utf8').catch(() => '');
    // `flutter:` as its own key — `flutter_lints` in dependencies is not Flutter.
    if (/^\s*flutter\s*:/m.test(spec)) {
      return { kind: PROJECT_KIND.mobileWeb, marker: 'pubspec.yaml', label: 'Flutter' };
    }
  }
  if (hasDep('expo') || hasDep('expo-router')) {
    return { kind: PROJECT_KIND.mobileWeb, marker: 'expo dependency', label: 'Expo' };
  }
  const capacitorConfig = entries.find((e) => /^capacitor\.config\.(json|ts|js|mjs)$/.test(e));
  if (capacitorConfig || hasDep('@capacitor/core')) {
    return { kind: PROJECT_KIND.mobileWeb, marker: capacitorConfig || '@capacitor/core dependency', label: 'Capacitor' };
  }
  if (entries.includes('ionic.config.json')) {
    return { kind: PROJECT_KIND.mobileWeb, marker: 'ionic.config.json', label: 'Ionic' };
  }

  // --- native ---
  const xcode = entries.find((e) => e.endsWith('.xcodeproj') || e.endsWith('.xcworkspace'));
  if (xcode || entries.includes('Package.swift')) {
    return { kind: PROJECT_KIND.nativeIOS, marker: xcode || 'Package.swift', label: 'Xcode / Swift' };
  }
  const gradle = entries.find((e) => /^(settings|build)\.gradle(\.kts)?$/.test(e));
  if (gradle) {
    return { kind: PROJECT_KIND.nativeAndroid, marker: gradle, label: 'Android (Gradle)' };
  }
  // Conventional manifest locations. A full recursive scan would be the thorough
  // answer, but it costs a walk of the whole tree on every deploy for a case the
  // gradle files above already cover in practice.
  for (const rel of [['AndroidManifest.xml'], ['app', 'src', 'main', 'AndroidManifest.xml'], ['android', 'app', 'src', 'main', 'AndroidManifest.xml']]) {
    if (await exists(at(...rel))) {
      return { kind: PROJECT_KIND.nativeAndroid, marker: rel.join('/'), label: 'Android (Gradle)' };
    }
  }
  if (hasDep('react-native')) {
    return { kind: PROJECT_KIND.nativeRN, marker: 'react-native dependency', label: 'React Native' };
  }

  return { kind: PROJECT_KIND.other, marker: null, label: null };
}

/** The refusal an agent sees for a native project, naming the evidence and the way out. */
export function nativeRefusalMessage(detected, indexPath) {
  const target = detected.kind === PROJECT_KIND.nativeIOS
    ? 'Build and ship it through Xcode (or the app\'s iOS ship flow) instead.'
    : detected.kind === PROJECT_KIND.nativeAndroid
      ? 'Build it with Gradle and ship the APK/AAB instead.'
      : 'Ship it through the React Native / Xcode / Gradle build instead.';
  return (
    `LingCode Cloud hosts web apps. This looks like a ${detected.label} project ` +
    `(found ${detected.marker}), and the directory you gave me has no ${indexPath} at its root, ` +
    `so there is nothing here the static tier can serve.\n` +
    `${target}\n` +
    `If this repo DOES contain a web app (say in web/ or apps/site/), build it and pass ` +
    `that build's output directory as dir.`
  );
}

// ---------------------------------------------------------------------------
// Pure helpers (exported for tests)
// ---------------------------------------------------------------------------

/** Derive the API origin from the account MCP URL, so dev and prod stay in step. */
export function apiOriginFromMcpUrl(mcpUrl) {
  try { return new URL(mcpUrl).origin; } catch { return 'https://lingcode.dev'; }
}

/**
 * Percent-encode EVERY non-alphanumeric byte. Two reasons this is strict rather
 * than `encodeURIComponent`: the server decodes with `decodeURIComponent` either
 * way, and a title reaching us from the model must never be able to carry CR/LF
 * into a header. Mirrors Swift's `addingPercentEncoding(withAllowedCharacters: .alphanumerics)`.
 */
export function encodeHeaderValue(s) {
  return Array.from(Buffer.from(String(s ?? ''), 'utf8'))
    .map((b) => {
      const c = String.fromCharCode(b);
      return /[A-Za-z0-9]/.test(c) ? c : '%' + b.toString(16).toUpperCase().padStart(2, '0');
    })
    .join('');
}

/**
 * Resolve `rel` inside `workspace`, refusing anything that escapes it — including
 * via a symlink, which is why this resolves real paths rather than just checking
 * for `..`. Throws with an agent-actionable message.
 */
export async function resolveWithin(workspace, rel) {
  const wsReal = await realpath(workspace);
  const within = (p) => p === wsReal || p.startsWith(wsReal + path.sep);

  // Lexical check FIRST. Otherwise `../../etc` on a machine without that path
  // fails as "No such directory", which sends the agent looking for a typo when
  // the real answer is that the path escapes the workspace.
  const candidate = path.resolve(wsReal, rel || '.');
  if (!within(candidate)) {
    throw new Error(`Refusing to package ${rel}: it resolves outside the workspace (${candidate}).`);
  }

  let real;
  try {
    real = await realpath(candidate);
  } catch {
    throw new Error(`No such directory: ${rel} (resolved to ${candidate})`);
  }
  // Second check against the REAL path — catches a symlink pointing outward,
  // which the lexical check above cannot see.
  if (!within(real)) {
    throw new Error(`Refusing to package ${rel}: it resolves outside the workspace (${real}).`);
  }
  return real;
}

/** POST to create, PUT /:id to redeploy — matches CloudDeployService.upload(). */
export function uploadTarget(origin, appId) {
  return appId
    ? { method: 'PUT', url: `${origin}/api/account/cloud-apps/${encodeURIComponent(appId)}` }
    : { method: 'POST', url: `${origin}/api/account/cloud-apps` };
}

// ---------------------------------------------------------------------------
// Bundle inspection
// ---------------------------------------------------------------------------

/**
 * Walk `dir` counting regular files and bytes. Symlinked directories are counted
 * as entries but not descended into — tar stores them as links and the server's
 * extract keeps only regular files, so descending would over-count.
 */
export async function walkBundle(dir) {
  const files = [];
  let totalBytes = 0;
  async function visit(abs, rel) {
    let entries;
    try { entries = await readdir(abs, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const childRel = rel ? `${rel}/${e.name}` : e.name;
      if (e.isSymbolicLink()) { files.push(childRel); continue; }
      if (e.isDirectory()) { await visit(path.join(abs, e.name), childRel); continue; }
      if (!e.isFile()) continue;
      files.push(childRel);
      try { totalBytes += (await stat(path.join(abs, e.name))).size; } catch { /* raced away */ }
    }
  }
  await visit(dir, '');
  return { files, totalBytes };
}

/** Fail locally, with the reason, rather than uploading something the server will reject. */
export function preflightBundle({ files, totalBytes, indexPath }) {
  if (!files.length) {
    throw new Error('That directory is empty — build the app first, then pass its output directory.');
  }
  if (!files.includes(indexPath)) {
    const roots = files.filter((f) => !f.includes('/')).slice(0, 12);
    throw new Error(
      `Bundle has no ${indexPath} at its root. Root entries: ${roots.join(', ') || '(none)'}. ` +
      `Pass the built output directory (e.g. dist/, build/, out/), not the project root.`
    );
  }
  if (files.length > MAX_FILES) {
    throw new Error(`Bundle has ${files.length} files; the limit is ${MAX_FILES}. Did you point at a directory containing node_modules?`);
  }
  if (totalBytes > MAX_BUNDLE_BYTES) {
    throw new Error(`Bundle is ${(totalBytes / 1048576).toFixed(1)} MB; the limit is ${(MAX_BUNDLE_BYTES / 1048576).toFixed(0)} MB.`);
  }
}

/**
 * `tar -czf - -C <dir> .` → Buffer. COPYFILE_DISABLE=1 is load-bearing, not
 * decoration: without it macOS tar bundles AppleDouble `._*` sidecars, which is
 * exactly what produced Cloudflare error 10021 on the worker tier. (The Swift
 * `packageTarGz` omits it; `packageSubdir` sets it. This follows the correct one.)
 */
export function tarGzDirectory(dir, { spawnImpl = spawn } = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawnImpl('/usr/bin/tar', ['-czf', '-', '-C', dir, '.'], {
      env: { ...process.env, COPYFILE_DISABLE: '1' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const chunks = [];
    let stderr = '';
    let bytes = 0;
    proc.stdout.on('data', (c) => {
      bytes += c.length;
      if (bytes > MAX_BUNDLE_BYTES) {
        proc.kill('SIGKILL');
        reject(new Error(`Archive exceeded ${(MAX_BUNDLE_BYTES / 1048576).toFixed(0)} MB while packaging.`));
        return;
      }
      chunks.push(c);
    });
    proc.stderr.on('data', (c) => { stderr += String(c); });
    proc.on('error', (e) => reject(new Error(`Could not run tar: ${e.message}`)));
    proc.on('close', (code) => {
      if (code !== 0) return reject(new Error(`tar failed (exit ${code}). ${stderr.slice(0, 300)}`));
      resolve(Buffer.concat(chunks));
    });
  });
}

// ---------------------------------------------------------------------------
// App-id store — <workspace>/.lingcode/apps.json
// ---------------------------------------------------------------------------
//
// The Mac app remembers the deployed app id in UserDefaults (CloudDeployStore
// `lastAppId`), which an agent cannot see. Left alone, the agent would POST a
// brand-new app on every deploy while the Deploy button kept PUTting the old one:
// two diverging apps and the 25-app cap burning down. Both sides now read this
// file. It stays OUT of git (the `.lingcode/.gitignore` allowlist covers only
// project.json / product-journey.json), so it matches the previous per-machine
// semantics rather than silently changing what collaborators redeploy.

export function appsFilePath(workspace) {
  return path.join(workspace, '.lingcode', 'apps.json');
}

export async function readAppRecord(workspace) {
  try {
    const raw = await readFile(appsFilePath(workspace), 'utf8');
    const parsed = JSON.parse(raw);
    return (parsed && typeof parsed === 'object' && parsed.static) || null;
  } catch { return null; }
}

export async function writeAppRecord(workspace, record) {
  const dir = path.join(workspace, '.lingcode');
  await mkdir(dir, { recursive: true });
  // Mirror ProjectManifestStore.ensureDirectory: this directory holds transcripts,
  // attachments and agent memory, so it must carry its ignore file even when the
  // Mac app has never created it.
  const ignore = path.join(dir, '.gitignore');
  try {
    await access(ignore);
  } catch {
    await writeFile(
      ignore,
      '# Keep only safe portable manifests in git; everything else here is local.\n*\n!.gitignore\n!project.json\n!product-journey.json\n',
      'utf8'
    );
  }
  let existing = {};
  try { existing = JSON.parse(await readFile(appsFilePath(workspace), 'utf8')) || {}; } catch { /* first write */ }
  existing.static = { ...(existing.static || {}), ...record };
  await writeFile(appsFilePath(workspace), JSON.stringify(existing, null, 2) + '\n', 'utf8');
  return existing.static;
}

// ---------------------------------------------------------------------------
// Tool descriptors
// ---------------------------------------------------------------------------

export const LOCAL_TOOLS = [
  {
    name: 'deploy_app',
    description:
      "Publish this project's BUILT frontend to LingCode Cloud static hosting and return its public URL. " +
      "Run the project's own build first (npm run build, etc.) — this tool uploads, it does not build. " +
      "Pass `dir` as the build OUTPUT directory (dist/, build/, out/, .next/out), never the project root. " +
      "Re-deploying is automatic: the app id is remembered per workspace, so later calls update the SAME app and URL. " +
      "Creating a NEW app publishes a world-readable URL, so the first deploy returns a preview and requires confirm=true; " +
      "re-deploys of an existing app apply directly. Static sites only — an SSR/Next.js app on the Worker tier still needs the Mac app's Deploy button. " +
      'A native iOS/Android/React Native project with no web build is refused before any packaging happens; Flutter, Expo, Capacitor and Ionic deploy their web build and say so in the preview.',
    inputSchema: {
      type: 'object',
      properties: {
        dir: { type: 'string', description: 'Build output directory, relative to the workspace root (e.g. "dist").' },
        title: { type: 'string', description: `Human-readable app name (max ${TITLE_MAX} chars). Defaults to the workspace folder name.` },
        appId: { type: 'string', description: 'Redeploy this specific app id. Omit to use the remembered one, or to create a new app.' },
        indexPath: { type: 'string', description: 'Entry HTML file at the bundle root. Defaults to index.html.' },
        confirm: { type: 'boolean', description: 'Set true to actually create a NEW public app after reviewing the preview.' },
      },
      required: ['dir'],
    },
  },
  {
    name: 'list_apps',
    description:
      'List the static apps deployed to LingCode Cloud that this account owns or collaborates on, with their live URLs, sizes and roles. ' +
      'Use this to find an existing app id before re-deploying, or to check the per-account app cap.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'rollback_app',
    description:
      "Roll a deployed app's CODE back to an earlier retained version. Call with only `appId` to list the available versions; " +
      'call again with `version` to apply. The rollback is logged as a new forward version, so it is itself reversible. ' +
      "Touches served code only — never the managed database's data.",
    inputSchema: {
      type: 'object',
      properties: {
        appId: { type: 'string', description: 'The app to roll back. Defaults to this workspace\'s remembered app.' },
        version: { type: 'integer', description: 'Version number to restore. Omit to list what is available.' },
      },
    },
  },
];

const LOCAL_TOOL_NAMES = new Set(LOCAL_TOOLS.map((t) => t.name));
export function isLocalTool(name) { return LOCAL_TOOL_NAMES.has(name); }

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

const ok = (text) => ({ content: [{ type: 'text', text }] });
const fail = (text) => ({ content: [{ type: 'text', text }], isError: true });

function authHeaders(ctx) {
  return {
    authorization: 'Bearer ' + ctx.token,
    'x-lingcode-project': ctx.project || 'default',
    ...(ctx.projectId ? { 'x-lingcode-project-id': ctx.projectId } : {}),
  };
}

/** Turn the server's `{ ok:false, error, message }` into something the agent can act on. */
async function readError(res) {
  const text = await res.text().catch(() => '');
  let body = null;
  try { body = JSON.parse(text); } catch { /* not json */ }
  const code = (body && body.error) || `http_${res.status}`;
  const msg = (body && body.message) || text.slice(0, 300) || res.statusText;
  if (res.status === 401) return `Not signed in to LingCode Cloud (${code}). Ask the user to sign in from the app.`;
  if (code === 'rate_limited') return `Deploy rate limit reached: ${msg}`;
  if (code === 'cap_reached') return `Account app cap reached (${(body && body.cap) || '?'}). Delete an app or redeploy an existing one with appId.`;
  return `${code}: ${msg}`;
}

async function deployApp(args, ctx) {
  const workspace = ctx.workspace;
  const indexPath = (args.indexPath || 'index.html').replace(/^\.?\//, '');

  const detected = await detectProjectKind(workspace);

  // For a native project the build directory usually does not exist at all. The
  // native refusal is a far more useful answer than "No such directory: dist".
  let dir;
  try {
    dir = await resolveWithin(workspace, args.dir);
  } catch (e) {
    if (isNativeKind(detected.kind)) return fail(nativeRefusalMessage(detected, indexPath));
    throw e;
  }

  // A native repo can still hold a real web app (an Xcode project beside web/dist).
  // So the question that decides this is not "does the REPO look native" but "is the
  // thing being deployed a web bundle" — which is also what the Swift side concludes
  // via its monorepo-aware bestWebConfig scan.
  if (isNativeKind(detected.kind) && !(await exists(path.join(dir, indexPath)))) {
    return fail(nativeRefusalMessage(detected, indexPath));
  }

  const { files, totalBytes } = await walkBundle(dir);
  preflightBundle({ files, totalBytes, indexPath });

  const remembered = await readAppRecord(workspace);
  const appId = args.appId || (remembered && remembered.appId) || null;
  const title = String(args.title || remembered?.title || path.basename(workspace)).slice(0, TITLE_MAX);

  // Creating a NEW app publishes a world-readable URL. Preview first, mirroring
  // deploy_backend_manifest's preview → approve → apply.
  if (!appId && !args.confirm) {
    // A mobile project with a web target deploys normally, but the user should
    // learn from the preview that what goes live is the WEB build of their mobile
    // app — not the app itself. The confirm gate is the only place they see this
    // before the URL is public.
    const mobileNote = detected.kind === PROJECT_KIND.mobileWeb
      ? `\n  NOTE:      ${detected.label} project (found ${detected.marker}) — this publishes its WEB build, not the mobile app.`
      : '';
    return ok(
      `Preview — this will CREATE A NEW PUBLIC app on LingCode Cloud:\n` +
      `  directory: ${path.relative(workspace, dir) || '.'}\n` +
      `  entry:     ${indexPath}\n` +
      `  files:     ${files.length}\n` +
      `  size:      ${(totalBytes / 1024).toFixed(0)} KB\n` +
      `  title:     ${title}${mobileNote}\n\n` +
      `The resulting URL is world-readable. Show this to the user, get their approval, ` +
      `then call deploy_app again with confirm=true. (Re-deploys of an existing app skip this step.)`
    );
  }

  const tgz = await tarGzDirectory(dir, ctx);
  const { method, url } = uploadTarget(ctx.origin, appId);
  const res = await ctx.fetchImpl(url, {
    method,
    headers: {
      ...authHeaders(ctx),
      'content-type': 'application/gzip',
      'x-app-title': encodeHeaderValue(title),
      'x-app-index': encodeHeaderValue(indexPath),
    },
    body: tgz,
  });

  if (!res.ok) {
    // A remembered id that 404s means the app was deleted elsewhere; say so
    // explicitly, because the fix (drop the id and create a new one) is not obvious.
    if (appId && (res.status === 404 || res.status === 403)) {
      return fail(
        `${await readError(res)}\n\nThe remembered app id ${appId} is no longer usable. ` +
        `Call deploy_app again without appId (and with confirm=true) to publish a new app.`
      );
    }
    return fail(await readError(res));
  }

  const body = await res.json().catch(() => null);
  if (!body || !body.id || !body.url) return fail('Server returned an unexpected response (no id/url).');

  await writeAppRecord(workspace, { appId: body.id, title, url: body.url, indexPath, updatedAt: Date.now() });

  return ok(
    `${appId ? 'Re-deployed' : 'Deployed'} "${title}" — ${files.length} files, ${(totalBytes / 1024).toFixed(0)} KB.\n` +
    `Live at: ${body.url}\n` +
    `App id:  ${body.id} (remembered in .lingcode/apps.json; later deploys update this same app)`
  );
}

async function listApps(_args, ctx) {
  const res = await ctx.fetchImpl(`${ctx.origin}/api/account/cloud-apps`, { headers: authHeaders(ctx) });
  if (!res.ok) return fail(await readError(res));
  const body = await res.json().catch(() => null);
  const items = (body && body.items) || [];
  if (!items.length) return ok('No apps deployed yet.');
  const lines = items.map((a) => `- ${a.title} — ${a.url}\n  id=${a.id} role=${a.role} files=${a.file_count} bytes=${a.total_bytes}`);
  return ok(`${items.length} app(s), cap ${body.cap}:\n${lines.join('\n')}`);
}

async function rollbackApp(args, ctx) {
  const remembered = await readAppRecord(ctx.workspace);
  const appId = args.appId || (remembered && remembered.appId);
  if (!appId) return fail('No app id given and none remembered for this workspace. Call list_apps to find one.');

  if (args.version === undefined || args.version === null) {
    const res = await ctx.fetchImpl(`${ctx.origin}/api/account/cloud-apps/${encodeURIComponent(appId)}/deployments`, { headers: authHeaders(ctx) });
    if (!res.ok) return fail(await readError(res));
    const body = await res.json().catch(() => null);
    const items = (body && body.items) || [];
    const lines = items.map((d) => `- v${d.version}${d.version === body.current ? ' (live)' : ''} — ${d.file_count} files, ${d.total_bytes} bytes, ${new Date(d.created_at).toISOString()}`);
    return ok(`App ${appId} — ${items.length} retained version(s), ${body.retained} kept:\n${lines.join('\n')}\n\nCall rollback_app again with a version to restore it.`);
  }

  const res = await ctx.fetchImpl(`${ctx.origin}/api/account/cloud-apps/${encodeURIComponent(appId)}/rollback`, {
    method: 'POST',
    headers: { ...authHeaders(ctx), 'content-type': 'application/json' },
    body: JSON.stringify({ version: args.version }),
  });
  if (!res.ok) return fail(await readError(res));
  const body = await res.json().catch(() => null);
  return ok(`Rolled app ${appId} back to v${args.version}${body && body.version ? ` (now live as v${body.version})` : ''}.`);
}

const HANDLERS = { deploy_app: deployApp, list_apps: listApps, rollback_app: rollbackApp };

/**
 * Run a local tool. Never throws — every failure comes back as an MCP tool result
 * with isError, so the agent can read the reason and correct itself.
 */
export async function callLocalTool(name, args, ctx) {
  const handler = HANDLERS[name];
  if (!handler) return fail(`Unknown local tool: ${name}`);
  if (!ctx.token) return fail('Not signed in to LingCode Cloud — no token available to this workspace.');
  try {
    return await handler(args || {}, ctx);
  } catch (e) {
    return fail(String((e && e.message) || e));
  }
}
