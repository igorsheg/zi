import assert from "node:assert/strict";
import { access, mkdir, rm, symlink } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { createExtensionLoader } from "../src/loader.ts";

const fixtureDir = resolve(dirname(fileURLToPath(import.meta.url)), "fixtures");

test("Jiti loads TypeScript, Node built-ins, and a fixture package", async () => {
  const fixturePackage = resolve(fixtureDir, "fixture-package");
  const linkDir = resolve(fixtureDir, "node_modules");
  const linkPath = resolve(linkDir, "fixture-package");
  await access(fixturePackage);
  await mkdir(linkDir, { recursive: true });
  await rm(linkPath, { force: true, recursive: true });
  await symlink(fixturePackage, linkPath, "junction");
  try {
    const loader = createExtensionLoader();
    const loaded = await loader(resolve(fixtureDir, "extension.ts"));
    assert.equal(typeof loaded.probe, "function");
    const probe = loaded.probe as (path: string) => Promise<string>;
    assert.equal(await probe(fileURLToPath(import.meta.url)), "package-ok");
  } finally {
    await rm(linkPath, { force: true, recursive: true });
  }
});
