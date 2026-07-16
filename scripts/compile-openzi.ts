import { mkdir } from "node:fs/promises"
import { dirname, resolve } from "node:path"

export interface CompileOpenZiOptions {
  readonly outfile: string
  readonly version: string
}

// Pi AI 0.80.6 keeps Node-only OAuth flows behind a variable import so browser
// bundlers cannot discover them. Standalone Bun builds need literal imports;
// fail-closed rewrite counting and the compiled OAuth test pin this seam until
// Pi AI exposes a supported Node/Bun bundling entrypoint.
const bundledOAuthLoader = `
export const loadAnthropicOAuth = async () => (await import("./anthropic.js")).anthropicOAuth
export const loadOpenAICodexOAuth = async () => (await import("./openai-codex.js")).openaiCodexOAuth
export const loadGitHubCopilotOAuth = async () => (await import("./github-copilot.js")).githubCopilotOAuth
`

export async function compileOpenZi(options: CompileOpenZiOptions): Promise<void> {
  if (!options.version || options.version.length > 128 || /[\r\n]/.test(options.version)) {
    throw new Error("OpenZi build versions must contain 1 to 128 characters on one line")
  }

  const root = resolve(import.meta.dirname, "..")
  await compileStandalone(resolve(root, "packages/cli/src/main.ts"), options.outfile, {
    "process.env.OPENZI_BUILD_VERSION": JSON.stringify(options.version)
  })
  await verifyOpenZi(options.outfile, options.version)
}

export async function compileStandalone(
  entrypoint: string,
  outfile: string,
  define: Readonly<Record<string, string>> = {}
): Promise<void> {
  let oauthLoaderRewrites = 0
  await mkdir(dirname(outfile), { recursive: true })
  await Bun.build({
    entrypoints: [entrypoint],
    target: "bun",
    format: "esm",
    minify: { syntax: true, whitespace: true, identifiers: false },
    packages: "bundle",
    conditions: ["bun", "node"],
    define: { ...define },
    plugins: [compiledOAuthPlugin(() => oauthLoaderRewrites++)],
    compile: {
      outfile,
      autoloadDotenv: false,
      autoloadBunfig: false,
      autoloadTsconfig: false,
      autoloadPackageJson: false
    }
  })
  if (oauthLoaderRewrites !== 1) {
    throw new Error(`Expected to replace one Pi AI OAuth loader, replaced ${oauthLoaderRewrites}`)
  }
}

function compiledOAuthPlugin(onRewrite: () => void): Bun.BunPlugin {
  return {
    name: "openzi-compiled-oauth",
    setup(builder) {
      builder.onLoad({ filter: /[\\/]@earendil-works[\\/]pi-ai[\\/]dist[\\/]utils[\\/]oauth[\\/]load\.js$/ }, () => {
        onRewrite()
        return { contents: bundledOAuthLoader, loader: "js" }
      })
    }
  }
}

async function verifyOpenZi(executable: string, version: string): Promise<void> {
  const child = Bun.spawn([executable, "--version"], { stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  if (exitCode !== 0 || stdout !== `openzi ${version}\n` || stderr !== "") {
    throw new Error(`Compiled executable failed its version smoke test (exit ${exitCode}): ${stderr || stdout}`)
  }
}
