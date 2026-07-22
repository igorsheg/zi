import { expect, test } from "bun:test"

import {
  detectClipboardImageMimeType,
  selectClipboardImageMimeType,
  SystemClipboardReader,
  type ClipboardCommand
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
