export interface InvariantRegistryOptions {
  readonly enabled?: boolean
  readonly allow?: readonly string[]
  readonly block?: readonly string[]
}

export interface InvariantContext {
  fail(message: string, details?: unknown): never
  assert(condition: unknown, message: string, details?: unknown): asserts condition
  cleanup(cleanup: () => void): void
}

type InvariantInstaller = (context: InvariantContext) => void | (() => void)

interface Registration {
  readonly cleanups: DisposableStack
}

export class InvariantError extends Error {
  readonly code = "INVARIANT" as const
  readonly owner: string
  readonly details?: unknown

  constructor(owner: string, message: string, details?: unknown) {
    super(`invariant violated by "${owner}": ${message}`)
    this.name = "InvariantError"
    this.owner = owner
    if (details !== undefined) this.details = details
  }
}

function compilePatterns(field: "allow" | "block", sources: readonly string[]): readonly RegExp[] {
  const seen = new Set<string>()
  return sources.map(source => {
    if (source.length === 0 || source.trim() !== source) {
      throw new Error(`invariants: ${field} patterns must be non-blank and have no surrounding whitespace`)
    }
    if (seen.has(source)) {
      throw new Error(`invariants: ${field} contains duplicate regex ${JSON.stringify(source)}`)
    }
    seen.add(source)
    try {
      return new RegExp(source)
    } catch (cause) {
      throw new Error(`invariants: ${field} contains invalid regex ${JSON.stringify(source)}`, { cause })
    }
  })
}

export class InvariantRegistry {
  private readonly enabled: boolean
  private readonly allow: readonly RegExp[]
  private readonly block: readonly RegExp[]
  private readonly registrations = new Map<string, Registration>()
  private disposed = false

  constructor(options: InvariantRegistryOptions = {}) {
    this.enabled = options.enabled ?? true
    this.allow = compilePatterns("allow", options.allow ?? [])
    this.block = compilePatterns("block", options.block ?? [])
  }

  register(owner: string, installer: InvariantInstaller): () => void {
    if (this.disposed) throw new Error("invariants: registry is disposed")
    if (owner.length === 0 || /\s/.test(owner)) {
      throw new Error("invariants: owner must be non-blank and contain no whitespace")
    }
    if (this.registrations.has(owner)) {
      throw new Error(`invariants: owner "${owner}" is already registered`)
    }

    const registration: Registration = { cleanups: new DisposableStack() }
    this.registrations.set(owner, registration)

    const dispose = (): void => {
      if (this.registrations.get(owner) !== registration) return
      this.registrations.delete(owner)
      registration.cleanups.dispose()
    }

    if (!this.selected(owner)) return dispose

    const fail = (message: string, details?: unknown): never => {
      throw new InvariantError(owner, message, details)
    }
    const context: InvariantContext = {
      fail,
      assert(condition: unknown, message: string, details?: unknown): asserts condition {
        if (!condition) fail(message, details)
      },
      cleanup(cleanup): void {
        registration.cleanups.defer(cleanup)
      }
    }

    try {
      const cleanup = installer(context)
      if (cleanup) registration.cleanups.defer(cleanup)
    } catch (error) {
      this.registrations.delete(owner)
      registration.cleanups.dispose()
      throw error
    }

    return dispose
  }

  dispose(): void {
    if (this.disposed) return
    this.disposed = true

    const cleanups = new DisposableStack()
    for (const registration of this.registrations.values()) {
      cleanups.defer(() => registration.cleanups.dispose())
    }
    this.registrations.clear()
    cleanups.dispose()
  }

  private selected(owner: string): boolean {
    return (
      this.enabled &&
      (this.allow.length === 0 || this.allow.some(pattern => pattern.test(owner))) &&
      !this.block.some(pattern => pattern.test(owner))
    )
  }
}
