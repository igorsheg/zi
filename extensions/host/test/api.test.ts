import assert from "node:assert/strict";
import test from "node:test";
import {
  activateExtension,
  runPromptCommand,
  type RegisteredPromptCommand,
  type ZiExtensionApi,
} from "../src/api.ts";

test("activation transaction registers and invokes a bounded prompt command", async () => {
  let captured: ZiExtensionApi | undefined;
  const commands = new Map<string, RegisteredPromptCommand>();
  await activateExtension({
    default(zi: ZiExtensionApi) {
      captured = zi;
      zi.commands.registerPrompt({
        name: "review",
        description: "Review changes",
        run: ({ args, cwd }) => ({ prompt: `Review ${args} in ${cwd}` }),
      });
    },
  }, "/extension.ts", commands);

  const command = commands.get("review");
  assert.ok(command);
  assert.deepEqual(
    await runPromptCommand(command, "concurrency", "/repo", new AbortController().signal),
    { prompt: "Review concurrency in /repo" },
  );
  assert.throws(() => captured?.commands.registerPrompt({
    name: "late",
    description: "Late command",
    run: () => ({ prompt: "late" }),
  }), /closed/);
});

test("activation rejects duplicate and malformed prompt commands", async () => {
  const commands = new Map<string, RegisteredPromptCommand>();
  await assert.rejects(
    activateExtension({
      default(zi: ZiExtensionApi) {
        zi.commands.registerPrompt({ name: "bad_name", description: "Bad", run: () => ({ prompt: "x" }) });
      },
    }, "/bad.ts", commands),
    /name/,
  );

  await activateExtension({
    default(zi: ZiExtensionApi) {
      zi.commands.registerPrompt({ name: "same", description: "First", run: () => ({ prompt: "x" }) });
    },
  }, "/first.ts", commands);
  await assert.rejects(
    activateExtension({
      default(zi: ZiExtensionApi) {
        zi.commands.registerPrompt({ name: "same", description: "Second", run: () => ({ prompt: "x" }) });
      },
    }, "/second.ts", commands),
    /duplicate/,
  );
});
