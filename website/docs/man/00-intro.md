---
slug: intro
title: Start here
order: 0
aliases:
  - overview
  - start
  - getting started
  - about
---

# Start here

Most coding agents make the first five minutes feel amazing.

Then the work gets real. You need to know what it changed. You need to continue tomorrow. You need it to follow your repo's rules. You need it to stop forgetting the same instruction.

Zi is built for that part.

It runs in your repo, gives the model a small set of tools, and keeps a session log you can resume.

## Install

```sh
curl -fsSL https://withzi.dev/install | sh
```

Or build it:

```sh
git clone https://github.com/igorsheg/zi
cd zi
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zi --version
```

## Your first run

Open Zi in a project:

```sh
zi
```

Ask it something concrete:

```text
explain how tests are organized in this repo
```

Zi can read files, run shell commands, edit files, write files, and inspect Zig declarations. It works best when you ask for a small piece of real work, then let the session build up context.

## Use the right shape for the job

Interactive work:

```sh
zi
zi "fix the failing build"
```

One answer for a shell script:

```sh
zi -p "write a commit message for the staged diff"
```

Events for another program:

```sh
zi --mode json "summarize this repo"
zi --mode rpc
```

## The core loop

1. Start Zi in the repo.
2. Ask for a small, inspectable piece of work.
3. Watch the tool calls.
4. Resume the session when you need to continue.
5. Move repeated instructions into `AGENTS.md` or a skill.

That last step is the important one. Zi gets better when you stop retyping instructions and start teaching the repo.

## What to read next

- [CLI](cli.html) — choose interactive, text, JSON, or RPC mode
- [Agent context](agent-context.html) — make Zi understand your repo
- [Skills](skills.html) — teach Zi reusable habits
- [Settings](settings.html) — choose provider, model, retry, and compaction defaults
- [Prompts](prompts.html) — replace or extend the system prompt
- [Resources](resources.html) — see where Zi stores files
- [Frontends](frontend.html) — understand the output modes
