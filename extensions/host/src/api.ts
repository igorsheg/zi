import type { LoadedModule } from "./loader.ts";

export const MAX_PROMPT_COMMANDS = 32;
export const MAX_COMMAND_NAME_BYTES = 32;
export const MAX_COMMAND_DESCRIPTION_BYTES = 96;
export const MAX_COMMAND_ARGS_BYTES = 4 * 1024;
export const MAX_GENERATED_PROMPT_BYTES = 4 * 1024;

export interface PromptCommandContext {
  readonly args: string;
  readonly cwd: string;
  readonly signal: AbortSignal;
}

export interface PromptCommandResult {
  readonly prompt: string;
}

interface PromptCommandDefinition {
  readonly name: string;
  readonly description: string;
  run(context: PromptCommandContext): PromptCommandResult | Promise<PromptCommandResult>;
}

export interface RegisteredPromptCommand {
  readonly name: string;
  readonly description: string;
  readonly source: string;
  readonly run: PromptCommandDefinition["run"];
}

export interface ZiExtensionApi {
  readonly apiVersion: 1;
  readonly commands: {
    registerPrompt(definition: PromptCommandDefinition): void;
  };
}

export async function activateExtension(
  loaded: LoadedModule,
  source: string,
  commands: Map<string, RegisteredPromptCommand>,
): Promise<void> {
  const factory = loaded.default;
  if (typeof factory !== "function") throw new TypeError(`extension must export a default activation function: ${source}`);
  let accepting = true;
  const api: ZiExtensionApi = Object.freeze({
    apiVersion: 1 as const,
    commands: Object.freeze({
      registerPrompt(definition: PromptCommandDefinition): void {
        if (!accepting) throw new Error("extension registration is closed");
        validatePromptCommand(definition);
        if (commands.size === MAX_PROMPT_COMMANDS) throw new Error("prompt command capacity exceeded");
        if (commands.has(definition.name)) throw new Error(`duplicate prompt command: ${definition.name}`);
        commands.set(definition.name, Object.freeze({
          name: definition.name,
          description: definition.description,
          source,
          run: definition.run,
        }));
      },
    }),
  });
  try {
    await factory(api);
  } finally {
    accepting = false;
  }
}

export async function runPromptCommand(
  command: RegisteredPromptCommand,
  args: unknown,
  cwd: string,
  signal: AbortSignal,
): Promise<PromptCommandResult> {
  if (typeof args !== "string" || Buffer.byteLength(args) > MAX_COMMAND_ARGS_BYTES) {
    throw new Error("invalid prompt command arguments");
  }
  const result = await command.run(Object.freeze({ args, cwd, signal }));
  if (typeof result !== "object" || result === null || typeof result.prompt !== "string") {
    throw new Error("invalid prompt command result");
  }
  const promptBytes = Buffer.byteLength(result.prompt);
  if (promptBytes === 0 || promptBytes > MAX_GENERATED_PROMPT_BYTES) {
    throw new Error("generated prompt exceeds bounds");
  }
  return { prompt: result.prompt };
}

function validatePromptCommand(definition: PromptCommandDefinition): void {
  if (typeof definition !== "object" || definition === null) throw new TypeError("invalid prompt command");
  if (typeof definition.name !== "string" || !/^[a-z][a-z0-9-]*$/.test(definition.name) ||
      Buffer.byteLength(definition.name) > MAX_COMMAND_NAME_BYTES) {
    throw new Error("invalid prompt command name");
  }
  if (typeof definition.description !== "string" || Buffer.byteLength(definition.description) === 0 ||
      Buffer.byteLength(definition.description) > MAX_COMMAND_DESCRIPTION_BYTES) {
    throw new Error("invalid prompt command description");
  }
  if (typeof definition.run !== "function") throw new Error("invalid prompt command handler");
}
