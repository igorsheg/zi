// Adapted from @cloudflare/codemode 0.5.1 (MIT), commit 413011e5b282ce215598223d4c2df5e9dbfaff03.

import * as acorn from "acorn"

export function normalizeCode(code: string): string {
  const source = stripCodeFences(code.trim()).trim()
  if (!source) return "async () => {}"

  try {
    const ast = acorn.parse(source, { ecmaVersion: "latest", sourceType: "module" })
    if (ast.body.length === 1 && ast.body[0]?.type === "ExpressionStatement") {
      const expression = ast.body[0].expression
      if (expression.type === "ArrowFunctionExpression") return source
    }
    if (ast.body.length === 1 && ast.body[0]?.type === "ExportDefaultDeclaration") {
      const declaration = ast.body[0].declaration
      return normalizeCode(source.slice(declaration.start, declaration.end))
    }
    if (ast.body.length === 1 && ast.body[0]?.type === "FunctionDeclaration") {
      const declaration = ast.body[0]
      const name = declaration.id?.name ?? "codeModeFunction"
      return `async () => {\n${source}\nreturn ${name}();\n}`
    }
    const last = ast.body.at(-1)
    if (last?.type === "ExpressionStatement") {
      const before = source.slice(0, last.start)
      const expression = source.slice(last.expression.start, last.expression.end)
      return `async () => {\n${before}return (${expression});\n}`
    }
    return `async () => {\n${source}\n}`
  } catch {
    return `async () => {\n${source}\n}`
  }
}

function stripCodeFences(code: string): string {
  const match = /^```(?:js|javascript|typescript|ts)?\s*\n([\s\S]*?)```\s*$/.exec(code)
  return match?.[1] ?? code
}
