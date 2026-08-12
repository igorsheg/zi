import { StyledText, type TextChunk } from "@opentui/core"

import type { DiagramCanvas, DiagramCanvasRun, DiagramCanvasRunOptions } from "./canvas.js"

export function renderDiagramGridStyledText<Style extends string, Metadata extends object = object>(
  grid: DiagramCanvas<Style, Metadata>,
  fg: (run: DiagramCanvasRun<Style, Metadata>) => TextChunk["fg"],
  bg?: (run: DiagramCanvasRun<Style, Metadata>) => TextChunk["bg"],
  options?: DiagramCanvasRunOptions<Style, Metadata>
): StyledText {
  const chunks: TextChunk[] = []

  grid.forEachRun(
    run => {
      const foreground = fg(run)
      const background = bg?.(run)
      chunks.push({
        __isChunk: true,
        text: run.text,
        ...(foreground === undefined ? {} : { fg: foreground }),
        ...(background === undefined ? {} : { bg: background })
      })
    },
    () => {
      chunks.push({ __isChunk: true, text: "\n" })
    },
    options
  )

  return new StyledText(chunks)
}
