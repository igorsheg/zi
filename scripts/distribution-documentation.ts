import { cp, lstat, readdir, rm } from "node:fs/promises"
import { join } from "node:path"

import {
  productDocumentationContractPaths,
  publicProductDocumentationFiles
} from "../packages/coding-agent/src/product-documentation.js"

export const distributionDocumentationEntries = Object.freeze([
  "README.md",
  "LICENSE",
  "THIRD_PARTY_NOTICES.md",
  "docs",
  "examples"
] as const)

export async function copyDistributionDocumentation(root: string, destination: string): Promise<void> {
  for (const entry of distributionDocumentationEntries) {
    const target = join(destination, entry)
    // Build destinations may retain an older documentation tree between builds.
    // oxlint-disable-next-line no-await-in-loop
    await rm(target, { recursive: true, force: true })
    // oxlint-disable-next-line no-await-in-loop
    await cp(join(root, entry), target, { recursive: true })
  }
  await assertDistributionDocumentation(destination)
}

export async function assertDistributionDocumentation(root: string): Promise<void> {
  const readme = await lstat(join(root, "README.md"))
  const license = await lstat(join(root, "LICENSE"))
  const notices = await lstat(join(root, "THIRD_PARTY_NOTICES.md"))
  const docs = await lstat(join(root, "docs"))
  const examples = await lstat(join(root, "examples"))
  if (!readme.isFile() || !license.isFile() || !notices.isFile() || !docs.isDirectory() || !examples.isDirectory()) {
    throw new Error(`Zi distribution documentation is incomplete: ${root}`)
  }

  const docsEntries = (await readdir(join(root, "docs"), { withFileTypes: true })).toSorted((left, right) =>
    left.name.localeCompare(right.name)
  )
  const containsOnlyPublicGuides =
    docsEntries.length === publicProductDocumentationFiles.length &&
    docsEntries.every((entry, index) => entry.isFile() && entry.name === publicProductDocumentationFiles[index])
  if (!containsOnlyPublicGuides) {
    throw new Error(`Zi distribution docs must contain only public consumer guides: ${root}`)
  }

  for (const path of productDocumentationContractPaths) {
    // These entry points are the model-facing self-customization contract.
    // oxlint-disable-next-line no-await-in-loop
    const entry = await lstat(join(root, path))
    if (!entry.isFile()) throw new Error(`Zi distribution documentation is missing ${path}: ${root}`)
  }
}
