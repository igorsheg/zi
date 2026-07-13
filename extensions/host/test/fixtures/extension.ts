import { access } from "node:fs/promises";
import type { ExtensionFactory } from "@zi/extension-api";
import { fixtureValue } from "fixture-package";

const activate: ExtensionFactory = (zi) => {
  zi.commands.registerPrompt({
    name: "fixture-review",
    description: "Generate a fixture review prompt",
    run: ({ args, cwd }) => ({ prompt: `Review ${args} in ${cwd}` }),
  });
};

export default activate;

export async function probe(path: string): Promise<string> {
  await access(path);
  return fixtureValue;
}
