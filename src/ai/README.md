# ai

Provider-agnostic LLM layer.

This directory should be implemented by reading the live reference package, not by copying this note:

- `.references/pi-mono/packages/ai/src/`
- `.references/pi-mono/packages/ai/test/`

This README is a signpost only. If code and this file disagree, trust the code and the pi-mono reference, then update or delete this file.

## implementation rule

Before adding an `ai` type, event, provider hook, or stream behavior:

1. inspect the matching pi-mono source and tests
2. identify the contract being ported
3. encode the Zig ownership/allocation/error shape
4. add tests for the observed contract

Do not fossilize behavior here before the Zig implementation exists.
