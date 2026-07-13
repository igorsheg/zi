import assert from "node:assert/strict";
import { Writable } from "node:stream";
import test from "node:test";
import { FrameDecoder } from "../src/framing.ts";
import { MAX_QUEUED_FRAMES, SerializedFrameWriter } from "../src/transport.ts";

class SlowSink extends Writable {
  readonly chunks: Buffer[] = [];
  readonly releases: Array<() => void> = [];

  constructor() {
    super({ highWaterMark: 1 });
  }

  override _write(chunk: Buffer, _encoding: BufferEncoding, callback: (error?: Error | null) => void): void {
    this.chunks.push(Buffer.from(chunk));
    this.releases.push(callback);
  }

  releaseOne(): void {
    const release = this.releases.shift();
    assert.ok(release);
    release();
  }
}

test("serializes frames and waits for stream backpressure", async () => {
  const sink = new SlowSink();
  const writer = new SerializedFrameWriter(sink);
  let firstDone = false;
  let secondDone = false;
  const first = writer.send({ sequence: 1 }).then(() => { firstDone = true; });
  const second = writer.send({ sequence: 2 }).then(() => { secondDone = true; });

  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(sink.chunks.length, 1);
  assert.equal(firstDone, false);
  assert.equal(secondDone, false);

  sink.releaseOne();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(firstDone, true);
  assert.equal(sink.chunks.length, 2);
  assert.equal(secondDone, false);

  sink.releaseOne();
  await Promise.all([first, second]);

  const values: unknown[] = [];
  const decoder = new FrameDecoder((body) => values.push(JSON.parse(body.toString("utf8")) as unknown));
  for (const chunk of sink.chunks) decoder.push(chunk);
  decoder.finish();
  assert.deepEqual(values, [{ sequence: 1 }, { sequence: 2 }]);
});

test("rejects writes at the bounded queue capacity", async () => {
  const sink = new SlowSink();
  const writer = new SerializedFrameWriter(sink);
  const pending: Array<Promise<void>> = [];
  for (let index = 0; index < MAX_QUEUED_FRAMES; index += 1) {
    pending.push(writer.send({ index }));
  }
  await assert.rejects(writer.send({ overflow: true }), /queue is full/);

  while (pending.some(() => sink.releases.length > 0)) {
    sink.releaseOne();
    await new Promise((resolve) => setImmediate(resolve));
    if (sink.releases.length === 0 && sink.chunks.length === MAX_QUEUED_FRAMES) break;
  }
  while (sink.releases.length > 0) {
    sink.releaseOne();
    await new Promise((resolve) => setImmediate(resolve));
  }
  await Promise.all(pending);
});

test("close rejects queued writes", async () => {
  const sink = new SlowSink();
  const writer = new SerializedFrameWriter(sink);
  const first = writer.send({ sequence: 1 });
  const second = writer.send({ sequence: 2 });
  writer.close(new Error("stopped"));
  await assert.rejects(first, /stopped/);
  await assert.rejects(second, /stopped/);
});
