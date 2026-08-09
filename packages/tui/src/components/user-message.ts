import { BoxRenderable, type RenderContext } from "@opentui/core"

import type { Theme } from "../theme.js"

export const userMessageChromeRows = 3

export function createUserMessageSurface(ctx: RenderContext, theme: Theme): BoxRenderable {
  return createSurface(ctx, theme.surface.userMessage)
}

export function createPendingUserMessageSurface(ctx: RenderContext): BoxRenderable {
  return createSurface(ctx)
}

export function formatUserMessageContent(
  content: string | readonly { readonly text?: string; readonly mimeType?: string }[]
): string {
  if (typeof content === "string") return content
  let output = ""
  let imageCount = 0
  let previousWasImage = false
  for (const part of content) {
    if (part.text !== undefined) {
      if (previousWasImage && output && !/\s$/.test(output) && !/^\s/.test(part.text)) output += " "
      output += part.text
      previousWasImage = false
      continue
    }
    if (!part.mimeType) continue
    if (output && !/\s$/.test(output)) output += " "
    output += `[image #${++imageCount}]`
    previousWasImage = true
  }
  return output
}

function createSurface(ctx: RenderContext, backgroundColor?: Theme["surface"]["userMessage"]): BoxRenderable {
  return new BoxRenderable(ctx, {
    width: "100%",
    paddingTop: 1,
    paddingBottom: 1,
    paddingLeft: 1,
    paddingRight: 1,
    marginTop: 0,
    marginBottom: 1,
    ...(backgroundColor === undefined ? {} : { backgroundColor }),
    flexDirection: "column",
    flexShrink: 0
  })
}
