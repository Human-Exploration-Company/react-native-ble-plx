import { cp, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { strict as assert } from "node:assert";
import pkg from "../package.json";

const root = fileURLToPath(new URL("../", import.meta.url));
const directory = await mkdtemp(join(tmpdir(), "ble-plx-package-"));
async function run(command: string[], cwd: string): Promise<void> {
  const child = Bun.spawn(command, {
    cwd,
    stdin: "ignore",
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await child.exited;
  if (code !== 0) throw new Error(`${command.join(" ")} exited with ${code}`);
}

try {
  await run([process.execPath, "pm", "pack", "--destination", directory], root);
  const consumer = join(directory, "consumer");
  await mkdir(consumer);
  await Bun.write(
    join(consumer, "package.json"),
    JSON.stringify({
      name: "ble-plx-packed-consumer",
      private: true,
      type: "module",
      dependencies: {
        "react-native-ble-plx": `file:${join(directory, `${pkg.name}-${pkg.version}.tgz`)}`,
        "@expo/config-plugins": pkg.dependencies["@expo/config-plugins"],
        expo: pkg.devDependencies.expo,
        react: pkg.devDependencies.react,
        "react-native": pkg.devDependencies["react-native"],
      },
      patchedDependencies: pkg.patchedDependencies,
    }),
  );
  await cp(join(root, "patches"), join(consumer, "patches"), {
    recursive: true,
  });
  await cp(
    join(root, "scripts/plugin-consumer.ts"),
    join(consumer, "verify.mts"),
  );
  await run([process.execPath, "install", "--ignore-scripts"], consumer);
  for (const path of Object.values(pkg.patchedDependencies)) {
    assert.equal(
      await Bun.file(join(consumer, "node_modules", pkg.name, path)).text(),
      await Bun.file(join(root, path)).text(),
      "The packed library must ship its Bun loader patch",
    );
  }
  await run([process.execPath, "verify.mts"], consumer);
  await run(["node", "verify.mts"], consumer);
} finally {
  await rm(directory, { recursive: true, force: true });
}
