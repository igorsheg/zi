import { expect, test } from "bun:test"

import { ExitGestureController } from "../../src/interactive/exit-gesture.js"

test("exit gestures own arming, consumption, expiry, and exit requests", () => {
  let exits = 0
  const gestures = new ExitGestureController(() => exits++)

  expect(gestures.clear(100)).toBe("armed")
  gestures.consume()
  expect(gestures.clear(200)).toBe("armed")
  expect(gestures.clear(701)).toBe("armed")
  expect(exits).toBe(0)
  expect(gestures.clear(900)).toBe("exit")
  expect(exits).toBe(1)

  gestures.exit()
  expect(exits).toBe(2)
})
