import { access } from "node:fs/promises";
import { fixtureValue } from "fixture-package";

export async function probe(path: string): Promise<string> {
  await access(path);
  return fixtureValue;
}
