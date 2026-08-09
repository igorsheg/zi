import { Type } from "typebox"
import { Compile } from "typebox/compile"

/**
 * TypeBox-backed guards for the primitive JSON shapes Zi validates at its process and file
 * boundaries. The same checks were previously re-implemented inline in a dozen modules; these
 * compiled checkers are the single owner of that behavior.
 *
 * Number guards compose TypeBox's numeric checks with `Number.isSafeInteger`/`Number.isFinite`
 * because JSON Schema integers accept unsafe integers (for example 2 ** 53).
 */
const record = Compile(Type.Record(Type.String(), Type.Unknown()))
const stringRecord = Compile(Type.Record(Type.String(), Type.String()))
const nonNegativeInteger = Compile(Type.Integer({ minimum: 0 }))
const positiveInteger = Compile(Type.Integer({ minimum: 1 }))
const numberGuard = Compile(Type.Number())
const nonNegativeNumber = Compile(Type.Number({ minimum: 0 }))

export function isRecord(value: unknown): value is Record<string, unknown> {
  return record.Check(value)
}

export function isStringRecord(value: unknown): value is Record<string, string> {
  return stringRecord.Check(value)
}

export function isNonNegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && nonNegativeInteger.Check(value)
}

export function isPositiveInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && positiveInteger.Check(value)
}

export function isFiniteNumber(value: unknown): value is number {
  return numberGuard.Check(value)
}

export function isNonNegativeFinite(value: unknown): value is number {
  return nonNegativeNumber.Check(value)
}
