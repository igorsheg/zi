export interface BrowserOpener {
  open(url: string): Promise<void>
  dispose(): void
}

export class SystemBrowserOpener implements BrowserOpener {
  readonly #subprocesses = new Set<ReturnType<typeof Bun.spawn>>()
  #disposed = false

  async open(url: string): Promise<void> {
    if (this.#disposed) throw new Error("Browser opener is disposed")
    if (this.#subprocesses.size >= 4) throw new Error("Browser opener process limit reached")
    const parsed = new URL(url)
    let hasControlCharacter = false
    for (const character of url) {
      const codePoint = character.codePointAt(0) ?? 0
      if (codePoint <= 31 || codePoint === 127) {
        hasControlCharacter = true
        break
      }
    }
    if ((parsed.protocol !== "http:" && parsed.protocol !== "https:") || url.length > 8192 || hasControlCharacter) {
      throw new Error("Browser URL must be a bounded HTTP or HTTPS URL")
    }

    const subprocess = Bun.spawn(browserCommand(url), { stdout: "ignore", stderr: "ignore" })
    this.#subprocesses.add(subprocess)
    let timeout: ReturnType<typeof setTimeout> | undefined
    try {
      const result = await Promise.race([
        subprocess.exited.then(exitCode => ({ type: "exited" as const, exitCode })),
        new Promise<{ type: "timeout" }>(resolve => {
          timeout = setTimeout(() => resolve({ type: "timeout" }), 5_000)
        })
      ])
      if (result.type === "timeout") {
        subprocess.kill()
        throw new Error("Browser opener timed out")
      }
      if (result.exitCode !== 0) throw new Error(`Browser opener exited with code ${result.exitCode}`)
    } finally {
      if (timeout) clearTimeout(timeout)
      this.#subprocesses.delete(subprocess)
    }
  }

  dispose(): void {
    if (this.#disposed) return
    this.#disposed = true
    for (const subprocess of this.#subprocesses) subprocess.kill()
    this.#subprocesses.clear()
  }
}

function browserCommand(url: string): string[] {
  switch (process.platform) {
    case "darwin":
      return ["open", url]
    case "win32":
      return ["rundll32", "url.dll,FileProtocolHandler", url]
    default:
      return ["xdg-open", url]
  }
}
