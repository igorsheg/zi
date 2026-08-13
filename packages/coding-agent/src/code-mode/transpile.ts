import { generate } from "yuku-codegen"
import { parse } from "yuku-parser"

const functionPrefix = "async () => {\n"

export function transpileCodeBody(code: string): string {
  const source = `${functionPrefix}${code}\n}`
  const parsed = parse(source, { lang: "ts", preserveParens: false, semanticErrors: true, sourceType: "script" })
  const syntaxError = parsed.diagnostics[0]
  if (syntaxError) throw new Error(syntaxError.message)

  const wrapper = parsed.program.body[0]
  if (
    wrapper?.type === "ExpressionStatement" &&
    wrapper.expression.type === "ArrowFunctionExpression" &&
    wrapper.expression.body.type === "BlockStatement"
  ) {
    const statements = wrapper.expression.body.body
    const statement = statements.length === 1 ? statements[0] : undefined
    if (
      statement?.type === "ExpressionStatement" &&
      statement.expression.type === "ArrowFunctionExpression" &&
      statement.expression.async
    ) {
      throw new Error("Code must be an async function body, not an async arrow function")
    }
  }

  const output = generate(parsed.program, { comments: "all", strip: true })
  const stripError = output.errors[0]
  if (stripError) throw new Error(`Code must use erasable TypeScript; ${stripError.message}`)
  if (!output.code.startsWith("async")) throw new Error("Code transpilation did not produce an async function")
  return output.code.replace(/;\s*$/, "")
}
