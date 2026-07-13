import { spawn } from "node:child_process";
import { access } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const compiler = resolve(packageRoot, "node_modules/typescript/bin/tsc");
try {
  await access(compiler);
} catch {
  console.error("Zi extension host dependencies are missing; run: npm --prefix extensions/host ci");
  process.exit(1);
}

const child = spawn(process.execPath, [compiler, "--noEmit", "--project", resolve(packageRoot, "tsconfig.json")], {
  cwd: packageRoot,
  stdio: "inherit",
});
child.once("error", (error) => {
  console.error(error);
  process.exit(1);
});
child.once("exit", (code, signal) => {
  process.exitCode = code ?? (signal === null ? 1 : 128);
});
