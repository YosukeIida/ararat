// Why not the REA CLI: every CLI call starts a new Ghidra session and loads the target again.
import { readdirSync, readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { join } from "node:path";

const REA = process.env.HOME + "/workspace/github.com/morluto/rea";
const { Client } = await import(REA + "/node_modules/@modelcontextprotocol/client/dist/index.mjs");
const { StdioClientTransport } = await import(REA + "/node_modules/@modelcontextprotocol/client/dist/stdio.mjs");

const box = process.argv[2];
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [REA + "/scripts/rea.mjs", "mcp"],
  env: process.env,
  stderr: "inherit",
});
const client = new Client({ name: "ararat-yab-driver", version: "0" });
await client.connect(transport);
const tools = await client.listTools();
writeFileSync(join(box, "tools.json"), JSON.stringify(tools, null, 1));
console.log("ready", tools.tools.length);

const timeout = 4 * 60 * 60 * 1000;
for (;;) {
  const reqs = readdirSync(box).filter((f) => /^req-.*\.json$/.test(f)).sort();
  for (const f of reqs) {
    const id = f.slice(4, -5);
    const busy = join(box, `run-${id}.json`);
    renameSync(join(box, f), busy);
    let out;
    try {
      const { name, arguments: args } = JSON.parse(readFileSync(busy, "utf8"));
      // Why not the SDK default: it cancels after 60 s, before Ghidra finishes its first load.
      out = await client.callTool({ name, arguments: args }, { timeout, maxTotalTimeout: timeout, resetTimeoutOnProgress: true });
    } catch (e) {
      out = { error: String(e?.stack ?? e) };
    }
    writeFileSync(join(box, `res-${id}.json`), JSON.stringify(out, null, 1));
    console.log("done", id, out.error ? "error" : "ok");
  }
  if (existsSync(join(box, "stop"))) break;
  await new Promise((r) => setTimeout(r, 500));
}
await client.close();
