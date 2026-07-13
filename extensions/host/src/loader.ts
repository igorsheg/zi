import { createJiti } from "jiti/static";

export type LoadedModule = Record<string, unknown>;

export function createExtensionLoader(): (modulePath: string) => Promise<LoadedModule> {
  const jiti = createJiti(import.meta.url, {
    fsCache: false,
    moduleCache: false,
  });

  return async (modulePath: string): Promise<LoadedModule> => {
    const loaded = await jiti.import(modulePath);
    if (typeof loaded !== "object" || loaded === null) {
      throw new TypeError(`extension module did not export an object: ${modulePath}`);
    }
    return loaded as LoadedModule;
  };
}
