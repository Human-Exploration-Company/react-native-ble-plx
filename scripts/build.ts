import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const destination = `${root}app.plugin.js`;
const result = await Bun.build({
  entrypoints: [`${root}app.plugin.ts`],
  target: "node",
  format: "cjs",
  packages: "external",
  banner: "// @generated from app.plugin.ts by bun run build; do not edit.",
});
if (!result.success)
  throw new AggregateError(result.logs, "Config plugin build failed");
const artifact = result.outputs[0];
if (!artifact) throw new Error("Config plugin build produced no output");
const formatter = Bun.spawn(
  [process.execPath, "fmt", "--stdin-filepath", "app.plugin.js"],
  {
    cwd: root,
    stdin: new Response(await artifact.text()),
    stdout: "pipe",
    stderr: "inherit",
  },
);
const output = await new Response(formatter.stdout).text();
if ((await formatter.exited) !== 0)
  throw new Error("Config plugin formatting failed");
if (Bun.argv.includes("--check")) {
  if (
    !(await Bun.file(destination).exists()) ||
    (await Bun.file(destination).text()) !== output
  ) {
    throw new Error("Committed config plugin is stale. Run bun run build.");
  }
} else {
  await Bun.write(destination, output);
}
