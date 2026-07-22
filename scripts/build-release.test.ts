import { expect, test } from "bun:test"

import {
  currentReleaseTarget,
  normalizeVersion,
  parseReleaseBuildOptions,
  releaseArchiveName
} from "./build-release.js"

test("release options accept a tag version and an explicit native target", () => {
  expect(parseReleaseBuildOptions(["--version", "v1.2.3-rc.1", "--target", "linux-x64"], {})).toEqual({
    version: "1.2.3-rc.1",
    target: "linux-x64"
  })
})

test("release options use bounded environment inputs", () => {
  expect(parseReleaseBuildOptions([], { ZI_RELEASE_VERSION: "2.0.0", ZI_RELEASE_TARGET: "darwin-arm64" })).toEqual({
    version: "2.0.0",
    target: "darwin-arm64"
  })
  expect(() => parseReleaseBuildOptions([], {})).toThrow("Release version is required")
  expect(() => parseReleaseBuildOptions(["--other"], { ZI_RELEASE_VERSION: "1.0.0" })).toThrow(
    "Unknown release build argument"
  )
})

test("release versions and targets reject unsafe artifact names", () => {
  expect(normalizeVersion("v1.2.3")).toBe("1.2.3")
  expect(() => normalizeVersion("latest")).toThrow("Invalid release version")
  expect(() => normalizeVersion("01.2.3")).toThrow("Invalid release version")
  expect(() => normalizeVersion("1.2.3-rc..1")).toThrow("Invalid release version")
  expect(() => normalizeVersion("1.2.3-01")).toThrow("Invalid release version")
  expect(() => normalizeVersion("1.2.3/../../escape")).toThrow("Invalid release version")
  expect(() => currentReleaseTarget("freebsd", "x64")).toThrow("Unsupported release target")
})

test("release archive names are stable", () => {
  expect(releaseArchiveName({ version: "1.2.3", target: "windows-x64" })).toBe("zi-1.2.3-windows-x64.tar.gz")
})
