export type ExtensionFactory = (zi: ZiExtension) => void | Promise<void>;

export interface ZiExtension {
  readonly apiVersion: 1;
  readonly commands: CommandRegistrar;
}

export interface CommandRegistrar {
  registerPrompt(definition: PromptCommandDefinition): void;
}

export interface PromptCommandDefinition {
  readonly name: string;
  readonly description: string;
  run(context: PromptCommandContext): PromptCommandResult | Promise<PromptCommandResult>;
}

export interface PromptCommandContext {
  readonly args: string;
  readonly cwd: string;
  readonly signal: AbortSignal;
}

export interface PromptCommandResult {
  readonly prompt: string;
}
