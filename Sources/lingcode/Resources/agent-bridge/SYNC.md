# agent-bridge resources

These files are **copies** of the canonical bridge in
[`LingCode/agent-bridge/`](../../../../../LingCode/agent-bridge/). They're
duplicated here so SwiftPM can bundle them as resources of the `lingcode`
executable target — that's what makes the standalone CLI work without
LingCode.app installed.

## When upstream changes, re-sync:

```bash
cp ../../../../../LingCode/agent-bridge/{bridge.mjs,sdk-bundle.mjs,package.json,zod-bundle.mjs,rtk.mjs,lingcode-cloud-mcp.mjs} \
   .
rm -rf lib && mkdir lib && cp -R ../../../../../LingCode/agent-bridge/lib/. lib/
find lib -name '*.test.mjs' -delete
```

(Run from this directory, or use the equivalent absolute paths.)

`build-cli-standalone.sh` does this automatically before each release build.
**`zod-bundle.mjs` is required for the in-process `lingcode-memory` MCP server
(memory_save, skill_propose, session_search). If it's missing the bridge falls
back to no-MCP — those tools silently won't register.**
