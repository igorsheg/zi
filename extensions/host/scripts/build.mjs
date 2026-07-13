import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MAX_BUNDLE_BYTES = 8 * 1024 * 1024;
const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outputArg = process.argv[2];
const digestArg = process.argv[3];
if (outputArg === undefined || outputArg.length === 0 || digestArg === undefined || digestArg.length === 0) {
  console.error("usage: node scripts/build.mjs <output-path> <digest-zig-path>");
  process.exit(2);
}

let build;
try {
  ({ build } = await import("esbuild"));
} catch {
  console.error("Zi extension host dependencies are missing; run: npm --prefix extensions/host ci");
  process.exit(1);
}

const outputPath = resolve(process.cwd(), outputArg);
const digestPath = resolve(process.cwd(), digestArg);
await mkdir(dirname(outputPath), { recursive: true });
await mkdir(dirname(digestPath), { recursive: true });
await build({
  absWorkingDir: packageRoot,
  entryPoints: ["src/main.ts"],
  outfile: outputPath,
  bundle: true,
  platform: "node",
  format: "esm",
  target: ["node22.19"],
  sourcemap: "inline",
  sourcesContent: true,
  legalComments: "none",
  charset: "utf8",
  treeShaking: true,
  banner: {
    js: [
      "// Zi extension host protocol 1.0",
      'import { createRequire as __ziCreateRequire } from "node:module";',
      "const require = __ziCreateRequire(import.meta.url);",
    ].join("\n"),
  },
  logLevel: "warning",
});

const bytes = await readFile(outputPath);
if (bytes.byteLength > MAX_BUNDLE_BYTES) {
  await rm(outputPath, { force: true });
  console.error(`extension host bundle exceeds ${MAX_BUNDLE_BYTES} bytes`);
  process.exit(1);
}

const digest = createHash("sha256").update(bytes).digest();
const literals = [...digest].map((byte) => `0x${byte.toString(16).padStart(2, "0")}`).join(", ");
await writeFile(digestPath, `pub const digest = [_]u8{ ${literals} };\n`);
