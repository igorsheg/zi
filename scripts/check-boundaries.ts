const rules = [
  { glob: "packages/coding-agent/src/**/*.{ts,tsx}", banned: ["@opentui/", "@openzi/tui", "react"] },
  { glob: "packages/tui/src/**/*.{ts,tsx}", banned: ["@earendil-works/pi-"] },
]

const violations: string[] = []
for (const rule of rules) {
  for await (const file of new Bun.Glob(rule.glob).scan(".")) {
    const source = await Bun.file(file).text()
    for (const dependency of rule.banned) {
      if (source.includes(`from \"${dependency}`) || source.includes(`from '${dependency}`) || source.includes(`import \"${dependency}`)) {
        violations.push(`${file}: ${dependency}`)
      }
    }
  }
}

if (violations.length > 0) throw new Error(`Package boundary violations:\n${violations.join("\n")}`)
