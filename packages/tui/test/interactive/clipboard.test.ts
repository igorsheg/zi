import { expect, test } from "bun:test"

import {
  detectClipboardImageMimeType,
  maxCopiedTextBytes,
  selectClipboardImageMimeType,
  SystemClipboardReader,
  SystemClipboardWriter,
  type ClipboardCommand,
  type ClipboardWriteCommand
} from "../../src/interactive/clipboard.js"

const encoder = new TextEncoder()

const png = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
const jpeg = Uint8Array.from([0xff, 0xd8, 0xff])
const gif = encoder.encode("GIF89a")
const webp = Uint8Array.from([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])

test("clipboard image detection trusts supported signatures and prefers portable MIME types", () => {
  expect(detectClipboardImageMimeType(png)).toBe("image/png")
  expect(detectClipboardImageMimeType(jpeg)).toBe("image/jpeg")
  expect(detectClipboardImageMimeType(gif)).toBe("image/gif")
  expect(detectClipboardImageMimeType(webp)).toBe("image/webp")
  expect(detectClipboardImageMimeType(encoder.encode("not an image"))).toBeUndefined()
  expect(selectClipboardImageMimeType(encoder.encode("text/plain\nimage/webp\nimage/png; charset=binary\n"))).toBe(
    "image/png"
  )
})

test("system clipboard reads a Wayland image with bounded typed commands", async () => {
  const calls: Array<{ command: string; args: readonly string[]; maxBytes: number }> = []
  const command: ClipboardCommand = async (name, args, options) => {
    calls.push({ command: name, args, maxBytes: options.maxBytes })
    if (name === "wl-paste" && args[0] === "--list-types") return encoder.encode("text/plain\nimage/png\n")
    if (name === "wl-paste" && args[1] === "image/png") return png
    return undefined
  }
  const reader = new SystemClipboardReader(command, "linux", "6.8.0", { WAYLAND_DISPLAY: "wayland-0" })

  const content = await reader.read(new AbortController().signal)
  expect(content).toEqual({ type: "image", bytes: png, mimeType: "image/png" })
  expect(calls.map(call => [call.command, ...call.args])).toEqual([
    ["wl-paste", "--list-types"],
    ["wl-paste", "--type", "image/png", "--no-newline"]
  ])
  expect(calls.every(call => call.maxBytes > 0)).toBe(true)
})

test("system clipboard falls back from unavailable image targets to Wayland text", async () => {
  const command: ClipboardCommand = async (name, args) => {
    if (name === "wl-paste" && args[0] === "--list-types") return encoder.encode("text/plain\n")
    if (name === "wl-paste" && args[0] === "--type") return encoder.encode("first\r\nsecond")
    return undefined
  }
  const reader = new SystemClipboardReader(command, "linux", "6.8.0", { XDG_SESSION_TYPE: "wayland" })

  const content = await reader.read(new AbortController().signal)
  expect(content).toEqual({ type: "text", text: "first\r\nsecond" })
})

test("system clipboard writes through native Wayland and OSC 52 routes", async () => {
  const calls: Array<{ command: string; args: readonly string[]; text: string; timeoutMs: number }> = []
  const command: ClipboardWriteCommand = async (name, args, options) => {
    calls.push({ command: name, args, text: new TextDecoder().decode(options.input), timeoutMs: options.timeoutMs })
    return name === "wl-copy"
  }
  const osc52: string[] = []
  const writer = new SystemClipboardWriter(
    text => {
      osc52.push(text)
      return true
    },
    command,
    "linux",
    "6.8.0",
    { WAYLAND_DISPLAY: "wayland-0" }
  )

  expect(await writer.write("copy 世界", new AbortController().signal)).toEqual({
    type: "copied",
    route: "native_and_osc52"
  })
  expect(osc52).toEqual(["copy 世界"])
  expect(calls).toEqual([
    { command: "wl-copy", args: ["--type", "text/plain;charset=utf-8"], text: "copy 世界", timeoutMs: 3_000 }
  ])
})

test("system clipboard falls back across local native writers when OSC 52 is unavailable", async () => {
  const calls: string[] = []
  const command: ClipboardWriteCommand = async name => {
    calls.push(name)
    return name === "xsel"
  }
  const writer = new SystemClipboardWriter(() => false, command, "linux", "6.8.0", { DISPLAY: ":0" })

  expect(await writer.write("local", new AbortController().signal)).toEqual({ type: "copied", route: "native" })
  expect(calls).toEqual(["xclip", "xsel"])
})

test("remote clipboard writes avoid the remote host clipboard and use OSC 52 only", async () => {
  const calls: string[] = []
  const command: ClipboardWriteCommand = async name => {
    calls.push(name)
    return true
  }
  const writer = new SystemClipboardWriter(() => true, command, "linux", "6.8.0", { SSH_CONNECTION: "client server" })

  expect(await writer.write("remote", new AbortController().signal)).toEqual({ type: "copied", route: "osc52" })
  expect(calls).toEqual([])
})

test("clipboard writes reject oversized text before attempting a delivery route", async () => {
  let osc52Calls = 0
  let nativeCalls = 0
  const writer = new SystemClipboardWriter(
    () => {
      osc52Calls++
      return true
    },
    async () => {
      nativeCalls++
      return true
    },
    "darwin",
    "23.0.0",
    {}
  )

  expect(await writer.write("x".repeat(maxCopiedTextBytes + 1), new AbortController().signal)).toEqual({
    type: "too_large",
    maxBytes: maxCopiedTextBytes
  })
  expect(osc52Calls).toBe(0)
  expect(nativeCalls).toBe(0)
})
