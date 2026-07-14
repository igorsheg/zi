import { SyntaxStyle } from "@opentui/core"
import { createContext, type ReactNode, use, useEffect, useMemo } from "react"

type Color = `#${string}`

export interface Theme {
  surface: { app: Color; panel: Color; userMessage: Color; composer: Color }
  text: {
    primary: Color
    muted: Color
    dim: Color
    accent: Color
    success: Color
    error: Color
    warning: Color
    thinking: Color
    custom: Color
    toolOutput: Color
    shell: Color
  }
  border: { default: Color; active: Color; muted: Color }
  markdown: {
    heading: Color
    link: Color
    linkUrl: Color
    code: Color
    codeBlock: Color
    quote: Color
    rule: Color
    listBullet: Color
  }
  syntax: {
    comment: Color
    keyword: Color
    function: Color
    variable: Color
    string: Color
    number: Color
    type: Color
    operator: Color
    punctuation: Color
  }
  diff: { added: Color; removed: Color; context: Color }
}

// Zi is the P0 visual acceptance reference. Keep this palette synchronized with
// igorsheg/zi src/tui/screen.zig at the commit pinned in docs/reference-pins.md.
export const ziTheme: Theme = {
  surface: { app: "#090E13", panel: "#0D1218", userMessage: "#0D1218", composer: "#090E13" },
  text: {
    primary: "#C5C9C7",
    muted: "#7F8381",
    dim: "#6A6E6C",
    accent: "#7AA89F",
    success: "#87A987",
    error: "#E46876",
    warning: "#E6C384",
    thinking: "#7F8381",
    custom: "#938AA9",
    toolOutput: "#7F8381",
    shell: "#E6C384"
  },
  border: { default: "#6A6E6C", active: "#7FB4CA", muted: "#535755" },
  markdown: {
    heading: "#E6C384",
    link: "#7FB4CA",
    linkUrl: "#6A6E6C",
    code: "#7AA89F",
    codeBlock: "#A5A9A7",
    quote: "#7F8381",
    rule: "#535755",
    listBullet: "#7AA89F"
  },
  syntax: {
    comment: "#535755",
    keyword: "#BEC2C0",
    function: "#B2B6B4",
    variable: "#A5A9A7",
    string: "#9B9690",
    number: "#9B9690",
    type: "#7F8381",
    operator: "#6A6E6C",
    punctuation: "#626664"
  },
  diff: { added: "#98BB6C", removed: "#E46876", context: "#535755" }
}

interface ThemeContextValue {
  theme: Theme
  syntaxStyle: SyntaxStyle
}

const ThemeContext = createContext<ThemeContextValue | undefined>(undefined)

export function ThemeProvider({ theme, children }: { theme: Theme; children: ReactNode }) {
  const syntaxStyle = useMemo(() => createSyntaxStyle(theme), [theme])
  const value = useMemo(() => ({ theme, syntaxStyle }), [theme, syntaxStyle])

  useEffect(() => () => syntaxStyle.destroy(), [syntaxStyle])

  return <ThemeContext value={value}>{children}</ThemeContext>
}

export function useTheme(): Theme {
  return useThemeContext().theme
}

export function useSyntaxStyle(): SyntaxStyle {
  return useThemeContext().syntaxStyle
}

function useThemeContext(): ThemeContextValue {
  const value = use(ThemeContext)
  if (!value) throw new Error("Theme hooks must be used inside ThemeProvider")
  return value
}

function createSyntaxStyle(theme: Theme): SyntaxStyle {
  return SyntaxStyle.fromStyles({
    default: { fg: theme.text.primary },
    comment: { fg: theme.syntax.comment, italic: true },
    keyword: { fg: theme.syntax.keyword },
    function: { fg: theme.syntax.function },
    variable: { fg: theme.syntax.variable },
    string: { fg: theme.syntax.string },
    symbol: { fg: theme.syntax.string },
    number: { fg: theme.syntax.number },
    boolean: { fg: theme.syntax.number },
    type: { fg: theme.syntax.type },
    operator: { fg: theme.syntax.operator },
    punctuation: { fg: theme.syntax.punctuation },
    conceal: { fg: theme.text.dim },
    "markup.heading": { fg: theme.markdown.heading, bold: true },
    "markup.heading.1": { fg: theme.markdown.heading, bold: true, underline: true },
    "markup.heading.2": { fg: theme.markdown.heading, bold: true },
    "markup.heading.3": { fg: theme.markdown.heading, bold: true },
    "markup.heading.4": { fg: theme.markdown.heading, bold: true },
    "markup.heading.5": { fg: theme.markdown.heading, bold: true },
    "markup.heading.6": { fg: theme.markdown.heading, bold: true },
    "markup.strong": { fg: theme.text.primary, bold: true },
    "markup.italic": { fg: theme.text.primary, italic: true },
    "markup.list": { fg: theme.markdown.listBullet },
    "markup.quote": { fg: theme.markdown.quote, italic: true },
    "markup.raw": { fg: theme.markdown.code },
    "markup.raw.block": { fg: theme.markdown.codeBlock },
    "markup.raw.inline": { fg: theme.markdown.code },
    "markup.link": { fg: theme.markdown.link, underline: true },
    "markup.link.label": { fg: theme.markdown.link, underline: true },
    "markup.link.url": { fg: theme.markdown.linkUrl, underline: true },
    "markup.strikethrough": { fg: theme.text.muted }
  })
}
