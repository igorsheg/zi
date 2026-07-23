import { mkdtemp, open, rm } from "node:fs/promises"
import { release, tmpdir } from "node:os"
import { join } from "node:path"

export const maxPastedTextBytes = 1024 * 1024
export const maxCopiedTextBytes = 4 * 1024 * 1024
export const maxClipboardImageBytes = Math.floor((4.5 * 1024 * 1024 * 3) / 4)

const maxClipboardImageOutputBytes = Math.ceil((maxClipboardImageBytes * 4) / 3) + 1024
const maxClipboardTypeBytes = 64 * 1024
const listTimeoutMs = 1_000
const readTimeoutMs = 3_000
const writeTimeoutMs = 3_000
const powershellTimeoutMs = 5_000

export type ClipboardContent =
  | { readonly type: "text"; readonly text: string }
  | { readonly type: "image"; readonly bytes: Uint8Array; readonly mimeType: string }

export interface ClipboardReader {
  read(signal: AbortSignal): Promise<ClipboardContent | undefined>
}

export type ClipboardWriteResult =
  | { readonly type: "copied"; readonly route: "native" | "osc52" | "native_and_osc52" }
  | { readonly type: "unavailable" }
  | { readonly type: "too_large"; readonly maxBytes: number }

export interface ClipboardWriter {
  write(text: string, signal: AbortSignal): Promise<ClipboardWriteResult>
}

export interface ClipboardWriteCommandOptions {
  readonly input: Uint8Array
  readonly timeoutMs: number
  readonly signal: AbortSignal
}

export type ClipboardWriteCommand = (
  command: string,
  args: readonly string[],
  options: ClipboardWriteCommandOptions
) => Promise<boolean>

export interface ClipboardCommandOptions {
  readonly maxBytes: number
  readonly timeoutMs: number
  readonly signal: AbortSignal
}

export type ClipboardCommand = (
  command: string,
  args: readonly string[],
  options: ClipboardCommandOptions
) => Promise<Uint8Array | undefined>

export class ClipboardContentTooLargeError extends Error {}

export class SystemClipboardWriter implements ClipboardWriter {
  readonly #osc52: (text: string) => boolean
  readonly #command: ClipboardWriteCommand
  readonly #platform: NodeJS.Platform
  readonly #release: string
  readonly #env: Readonly<Record<string, string | undefined>>

  constructor(
    osc52: (text: string) => boolean,
    command: ClipboardWriteCommand = runClipboardWriteCommand,
    platform: NodeJS.Platform = process.platform,
    systemRelease: string = release(),
    env: Readonly<Record<string, string | undefined>> = process.env
  ) {
    this.#osc52 = osc52
    this.#command = command
    this.#platform = platform
    this.#release = systemRelease
    this.#env = env
  }

  async write(text: string, signal: AbortSignal): Promise<ClipboardWriteResult> {
    signal.throwIfAborted()
    if (Buffer.byteLength(text) > maxCopiedTextBytes) return { type: "too_large", maxBytes: maxCopiedTextBytes }
    const input = new TextEncoder().encode(text)

    let osc52 = false
    try {
      osc52 = this.#osc52(text)
    } catch {}

    signal.throwIfAborted()
    const native = isRemoteSession(this.#env) ? false : await this.#writeNative(input, signal)
    if (native && osc52) return { type: "copied", route: "native_and_osc52" }
    if (native) return { type: "copied", route: "native" }
    if (osc52) return { type: "copied", route: "osc52" }
    return { type: "unavailable" }
  }

  async #writeNative(input: Uint8Array, signal: AbortSignal): Promise<boolean> {
    if (this.#platform === "darwin") return this.#run("pbcopy", [], input, writeTimeoutMs, signal)
    if (this.#platform === "win32") return this.#writeWindows(input, signal)
    if (this.#platform !== "linux") return false

    if (isWsl(this.#release, this.#env) && (await this.#writeWindows(input, signal))) return true
    if (this.#env.TERMUX_VERSION && (await this.#run("termux-clipboard-set", [], input, writeTimeoutMs, signal))) {
      return true
    }
    if (
      isWayland(this.#env) &&
      (await this.#run("wl-copy", ["--type", "text/plain;charset=utf-8"], input, writeTimeoutMs, signal))
    ) {
      return true
    }
    if (!this.#env.DISPLAY) return false
    if (await this.#run("xclip", ["-selection", "clipboard", "-in"], input, writeTimeoutMs, signal)) return true
    return this.#run("xsel", ["--clipboard", "--input"], input, writeTimeoutMs, signal)
  }

  #writeWindows(input: Uint8Array, signal: AbortSignal): Promise<boolean> {
    const script =
      "[Console]::InputEncoding = [System.Text.Encoding]::UTF8; Set-Clipboard -Value ([Console]::In.ReadToEnd())"
    return this.#run(
      "powershell.exe",
      ["-NonInteractive", "-NoProfile", "-Command", script],
      input,
      powershellTimeoutMs,
      signal
    )
  }

  #run(
    command: string,
    args: readonly string[],
    input: Uint8Array,
    timeoutMs: number,
    signal: AbortSignal
  ): Promise<boolean> {
    signal.throwIfAborted()
    return this.#command(command, args, { input, timeoutMs, signal })
  }
}

export class SystemClipboardReader implements ClipboardReader {
  readonly #command: ClipboardCommand
  readonly #platform: NodeJS.Platform
  readonly #release: string
  readonly #env: Readonly<Record<string, string | undefined>>

  constructor(
    command: ClipboardCommand = runClipboardCommand,
    platform: NodeJS.Platform = process.platform,
    systemRelease: string = release(),
    env: Readonly<Record<string, string | undefined>> = process.env
  ) {
    this.#command = command
    this.#platform = platform
    this.#release = systemRelease
    this.#env = env
  }

  async read(signal: AbortSignal): Promise<ClipboardContent | undefined> {
    signal.throwIfAborted()
    if (this.#platform === "darwin") return (await this.#readMacImage(signal)) ?? this.#readMacText(signal)
    if (this.#platform === "win32") return (await this.#readWindowsImage(signal)) ?? this.#readWindowsText(signal)
    if (this.#platform !== "linux") return undefined

    const image = await this.#readLinuxImage(signal)
    if (image) return image
    if (isWsl(this.#release, this.#env)) {
      const windowsImage = await this.#readWindowsImage(signal)
      if (windowsImage) return windowsImage
    }
    return (
      (await this.#readLinuxText(signal)) ??
      (isWsl(this.#release, this.#env) ? this.#readWindowsText(signal) : undefined)
    )
  }

  async #readMacImage(signal: AbortSignal): Promise<ClipboardContent | undefined> {
    const directory = await mkdtemp(join(tmpdir(), "zi-clipboard-"))
    const path = join(directory, "clipboard.png")
    const escapedPath = path.replaceAll("\\", "\\\\").replaceAll('"', '\\"')
    try {
      const result = await this.#command(
        "osascript",
        [
          "-e",
          'set imageData to the clipboard as "PNGf"',
          "-e",
          `set fileRef to open for access POSIX file "${escapedPath}" with write permission`,
          "-e",
          "set eof fileRef to 0",
          "-e",
          "write imageData to fileRef",
          "-e",
          "close access fileRef"
        ],
        { maxBytes: 1024, timeoutMs: readTimeoutMs, signal }
      )
      if (!result) return undefined
      const bytes = await readBoundedFile(path, maxClipboardImageBytes)
      return imageContent(bytes)
    } catch (cause) {
      if (cause instanceof ClipboardContentTooLargeError || signal.aborted) throw cause
      return undefined
    } finally {
      await rm(directory, { recursive: true, force: true }).catch(() => {})
    }
  }

  async #readMacText(signal: AbortSignal): Promise<ClipboardContent | undefined> {
    return textContent(
      await this.#command("pbpaste", [], { maxBytes: maxPastedTextBytes, timeoutMs: readTimeoutMs, signal })
    )
  }

  async #readWindowsImage(signal: AbortSignal): Promise<ClipboardContent | undefined> {
    const script = [
      "Add-Type -AssemblyName System.Windows.Forms",
      "$img = [System.Windows.Forms.Clipboard]::GetImage()",
      "if ($img) {",
      "$stream = New-Object System.IO.MemoryStream",
      "$img.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)",
      "[Console]::Out.Write([System.Convert]::ToBase64String($stream.ToArray()))",
      "}"
    ].join("; ")
    const output = await this.#command("powershell.exe", ["-NonInteractive", "-NoProfile", "-Command", script], {
      maxBytes: maxClipboardImageOutputBytes,
      timeoutMs: powershellTimeoutMs,
      signal
    })
    if (!output) return undefined
    const encoded = new TextDecoder().decode(output).trim()
    if (!encoded || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) return undefined
    const bytes = Buffer.from(encoded, "base64")
    if (bytes.byteLength > maxClipboardImageBytes) {
      throw new ClipboardContentTooLargeError("Clipboard image exceeds the 4.5 MiB encoded image limit")
    }
    return imageContent(bytes)
  }

  async #readWindowsText(signal: AbortSignal): Promise<ClipboardContent | undefined> {
    const script = "$value = Get-Clipboard -Raw; if ($null -ne $value) { [Console]::Out.Write($value) }"
    return textContent(
      await this.#command("powershell.exe", ["-NonInteractive", "-NoProfile", "-Command", script], {
        maxBytes: maxPastedTextBytes,
        timeoutMs: powershellTimeoutMs,
        signal
      })
    )
  }

  async #readLinuxImage(signal: AbortSignal): Promise<ClipboardContent | undefined> {
    if (isWayland(this.#env)) {
      const types = await this.#command("wl-paste", ["--list-types"], {
        maxBytes: maxClipboardTypeBytes,
        timeoutMs: listTimeoutMs,
        signal
      })
      const mimeType = selectClipboardImageMimeType(types)
      if (mimeType) {
        const bytes = await this.#command("wl-paste", ["--type", mimeType, "--no-newline"], {
          maxBytes: maxClipboardImageBytes,
          timeoutMs: readTimeoutMs,
          signal
        })
        const content = imageContent(bytes)
        if (content) return content
      }
    }

    const types = await this.#command("xclip", ["-selection", "clipboard", "-t", "TARGETS", "-o"], {
      maxBytes: maxClipboardTypeBytes,
      timeoutMs: listTimeoutMs,
      signal
    })
    const mimeType = selectClipboardImageMimeType(types)
    if (!mimeType) return undefined
    return imageContent(
      await this.#command("xclip", ["-selection", "clipboard", "-t", mimeType, "-o"], {
        maxBytes: maxClipboardImageBytes,
        timeoutMs: readTimeoutMs,
        signal
      })
    )
  }

  async #readLinuxText(signal: AbortSignal): Promise<ClipboardContent | undefined> {
    if (this.#env.TERMUX_VERSION) {
      return textContent(
        await this.#command("termux-clipboard-get", [], {
          maxBytes: maxPastedTextBytes,
          timeoutMs: readTimeoutMs,
          signal
        })
      )
    }
    if (isWayland(this.#env)) {
      const wayland = textContent(
        await this.#command("wl-paste", ["--type", "text/plain;charset=utf-8", "--no-newline"], {
          maxBytes: maxPastedTextBytes,
          timeoutMs: readTimeoutMs,
          signal
        })
      )
      if (wayland) return wayland
    }
    const xclip = textContent(
      await this.#command("xclip", ["-selection", "clipboard", "-t", "UTF8_STRING", "-o"], {
        maxBytes: maxPastedTextBytes,
        timeoutMs: readTimeoutMs,
        signal
      })
    )
    if (xclip) return xclip
    return textContent(
      await this.#command("xsel", ["--clipboard", "--output"], {
        maxBytes: maxPastedTextBytes,
        timeoutMs: readTimeoutMs,
        signal
      })
    )
  }
}

export function detectClipboardImageMimeType(bytes: Uint8Array): string | undefined {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return "image/png"
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg"
  if (
    bytes.length >= 6 &&
    bytes[0] === 0x47 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x38 &&
    (bytes[4] === 0x37 || bytes[4] === 0x39) &&
    bytes[5] === 0x61
  ) {
    return "image/gif"
  }
  if (
    bytes.length >= 12 &&
    bytes[0] === 0x52 &&
    bytes[1] === 0x49 &&
    bytes[2] === 0x46 &&
    bytes[3] === 0x46 &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return "image/webp"
  }
  return undefined
}

export function selectClipboardImageMimeType(bytes: Uint8Array | undefined): string | undefined {
  if (!bytes) return undefined
  const types = new Set(
    new TextDecoder()
      .decode(bytes)
      .split(/\r?\n/)
      .map(type => type.split(";")[0]!.trim().toLowerCase())
  )
  return ["image/png", "image/jpeg", "image/webp", "image/gif"].find(candidate => types.has(candidate))
}

export async function runClipboardWriteCommand(
  command: string,
  args: readonly string[],
  options: ClipboardWriteCommandOptions
): Promise<boolean> {
  options.signal.throwIfAborted()
  let child: ReturnType<typeof spawnClipboardWriteProcess>
  try {
    child = spawnClipboardWriteProcess(command, args, options.input)
  } catch {
    return false
  }

  let timedOut = false
  const stop = () => child.kill(9)
  const timeout = setTimeout(() => {
    timedOut = true
    child.kill(9)
  }, options.timeoutMs)
  options.signal.addEventListener("abort", stop, { once: true })
  try {
    const exitCode = await child.exited
    if (options.signal.aborted) throw options.signal.reason
    return !timedOut && exitCode === 0
  } finally {
    clearTimeout(timeout)
    options.signal.removeEventListener("abort", stop)
  }
}

export async function runClipboardCommand(
  command: string,
  args: readonly string[],
  options: ClipboardCommandOptions
): Promise<Uint8Array | undefined> {
  options.signal.throwIfAborted()
  let child: ReturnType<typeof spawnClipboardProcess>
  try {
    child = spawnClipboardProcess(command, args)
  } catch {
    return undefined
  }

  let timedOut = false
  let exceeded = false
  const stop = () => child.kill(9)
  const timeout = setTimeout(() => {
    timedOut = true
    child.kill(9)
  }, options.timeoutMs)
  options.signal.addEventListener("abort", stop, { once: true })

  const chunks: Uint8Array[] = []
  let bytes = 0
  const reader = child.stdout.getReader()
  try {
    while (true) {
      // Stream order is authoritative and the byte bound is enforced before retaining each chunk.
      // oxlint-disable-next-line no-await-in-loop
      const next = await reader.read()
      if (next.done) break
      bytes += next.value.byteLength
      if (bytes > options.maxBytes) {
        exceeded = true
        child.kill(9)
        break
      }
      chunks.push(next.value)
    }
    const exitCode = await child.exited
    if (options.signal.aborted) throw options.signal.reason
    if (exceeded) throw new ClipboardContentTooLargeError("Clipboard content exceeds the supported size limit")
    if (timedOut || exitCode !== 0) return undefined
    return joinBytes(chunks, bytes)
  } finally {
    clearTimeout(timeout)
    options.signal.removeEventListener("abort", stop)
    reader.releaseLock()
  }
}

function spawnClipboardWriteProcess(command: string, args: readonly string[], input: Uint8Array) {
  return Bun.spawn([command, ...args], { stdin: input, stdout: "ignore", stderr: "ignore" })
}

function spawnClipboardProcess(command: string, args: readonly string[]) {
  return Bun.spawn([command, ...args], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
}

function imageContent(bytes: Uint8Array | undefined): ClipboardContent | undefined {
  if (!bytes || bytes.byteLength === 0) return undefined
  const mimeType = detectClipboardImageMimeType(bytes)
  return mimeType ? { type: "image", bytes, mimeType } : undefined
}

function textContent(bytes: Uint8Array | undefined): ClipboardContent | undefined {
  if (!bytes || bytes.byteLength === 0) return undefined
  const text = new TextDecoder().decode(bytes)
  return text ? { type: "text", text } : undefined
}

function isWayland(env: Readonly<Record<string, string | undefined>>): boolean {
  return Boolean(env.WAYLAND_DISPLAY) || env.XDG_SESSION_TYPE === "wayland"
}

function isRemoteSession(env: Readonly<Record<string, string | undefined>>): boolean {
  return Boolean(env.SSH_CLIENT || env.SSH_CONNECTION || env.SSH_TTY)
}

function isWsl(systemRelease: string, env: Readonly<Record<string, string | undefined>>): boolean {
  return Boolean(env.WSL_DISTRO_NAME || env.WSLENV) || /microsoft|wsl/i.test(systemRelease)
}

async function readBoundedFile(path: string, maxBytes: number): Promise<Uint8Array> {
  const file = await open(path, "r")
  try {
    const stat = await file.stat()
    if (stat.size > maxBytes)
      throw new ClipboardContentTooLargeError("Clipboard image exceeds the supported size limit")
    const bytes = new Uint8Array(stat.size)
    const result = await file.read(bytes, 0, bytes.length, 0)
    return bytes.subarray(0, result.bytesRead)
  } finally {
    await file.close()
  }
}

function joinBytes(chunks: readonly Uint8Array[], length: number): Uint8Array {
  if (chunks.length === 1) return chunks[0]!
  const output = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    output.set(chunk, offset)
    offset += chunk.byteLength
  }
  return output
}
