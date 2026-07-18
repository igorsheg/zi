import { TreeSitterClient, type SimpleHighlight } from "@opentui/core"

export function createMarkdownTreeSitterClient(
  standalone = process.env.OPENZI_STANDALONE === "1"
): TreeSitterClient | undefined {
  return standalone ? new PlainTextTreeSitterClient() : undefined
}

// Bun 1.3 standalone executables cannot resolve OpenTUI's dynamic parser worker; a failed client retries per highlight.
class PlainTextTreeSitterClient extends TreeSitterClient {
  constructor() {
    super({ dataPath: "" }, { autoStartWorker: false })
  }

  override async highlightOnce(): Promise<{ highlights?: SimpleHighlight[]; warning?: string; error?: string }> {
    return {}
  }

  override async destroy(): Promise<void> {}
}
