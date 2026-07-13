import { realpath } from "node:fs/promises"
import { resolve } from "node:path"

const queues = new Map<string, Promise<void>>()
let registration = Promise.resolve()

export async function withFileMutation<T>(path: string, mutate: () => Promise<T>): Promise<T> {
  const registered = registration.then(async () => {
    const key = await realpath(path).catch(() => resolve(path))
    const current = queues.get(key) ?? Promise.resolve()
    let release!: () => void
    const next = new Promise<void>((done) => (release = done))
    const tail = current.then(() => next)
    queues.set(key, tail)
    return { key, current, tail, release }
  })
  registration = registered.then(
    () => undefined,
    () => undefined,
  )

  const item = await registered
  await item.current
  try {
    return await mutate()
  } finally {
    item.release()
    if (queues.get(item.key) === item.tail) queues.delete(item.key)
  }
}
