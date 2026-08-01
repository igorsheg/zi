export type ResourceScope = "global" | "project"

export type ResourceKind =
  | "context"
  | "system-prompt"
  | "append-system-prompt"
  | "skill"
  | "prompt-template"
  | "subagent-profile"
  | "discovery"

export type ResourceDiagnostic =
  | { readonly type: "warning"; readonly resource: ResourceKind; readonly path: string; readonly message: string }
  | {
      readonly type: "collision"
      readonly resource: "skill" | "prompt-template" | "subagent-profile"
      readonly name: string
      readonly winnerPath: string
      readonly loserPath: string
    }
  | {
      readonly type: "limit"
      readonly resource: ResourceKind
      readonly limit: number
      readonly path?: string
      readonly message: string
    }

export const maxResourceDiagnostics = 512

export class ResourceDiagnostics {
  readonly #diagnostics: ResourceDiagnostic[] = []
  #truncated = false

  add(diagnostic: ResourceDiagnostic): void {
    if (this.#diagnostics.length < maxResourceDiagnostics - 1) {
      this.#diagnostics.push(diagnostic)
      return
    }
    if (this.#truncated) return
    this.#truncated = true
    this.#diagnostics.push({
      type: "limit",
      resource: "discovery",
      limit: maxResourceDiagnostics,
      message: `Resource diagnostics are limited to ${maxResourceDiagnostics} entries`
    })
  }

  snapshot(): readonly ResourceDiagnostic[] {
    return Object.freeze(this.#diagnostics.map(diagnostic => Object.freeze({ ...diagnostic })))
  }
}
