import type { Writable } from "node:stream";
import { once } from "node:events";
import { encodeFrame, MAX_BODY_BYTES } from "./framing.ts";

export const MAX_QUEUED_FRAMES = 32;
export const MAX_QUEUED_BYTES = 16 * 1024 * 1024;

interface QueuedFrame {
  readonly bytes: Buffer;
  readonly resolve: () => void;
  readonly reject: (error: unknown) => void;
}

export class SerializedFrameWriter {
  readonly #stream: Writable;
  readonly #write: Writable["write"];
  readonly #queue: QueuedFrame[] = [];
  #pendingFrames = 0;
  #pendingBytes = 0;
  #active: QueuedFrame | undefined;
  #writing = false;
  #closed = false;

  constructor(stream: Writable) {
    this.#stream = stream;
    this.#write = stream.write.bind(stream);
  }

  send(value: object): Promise<void> {
    if (this.#closed) return Promise.reject(new Error("transport is closed"));
    const body = Buffer.from(JSON.stringify(value), "utf8");
    if (body.length > MAX_BODY_BYTES) return Promise.reject(new Error("frame body exceeds limit"));
    const frame = encodeFrame(body);
    if (this.#pendingFrames >= MAX_QUEUED_FRAMES || this.#pendingBytes + frame.length > MAX_QUEUED_BYTES) {
      return Promise.reject(new Error("transport queue is full"));
    }

    const completion = new Promise<void>((resolve, reject) => {
      this.#queue.push({ bytes: frame, resolve, reject });
      this.#pendingFrames += 1;
      this.#pendingBytes += frame.length;
    });
    if (!this.#writing) void this.#drain();
    return completion;
  }

  close(reason: Error = new Error("transport is closed")): void {
    if (this.#closed) return;
    this.#closed = true;
    if (this.#active !== undefined) this.#active.reject(reason);
    for (const frame of this.#queue) frame.reject(reason);
    this.#queue.length = 0;
    this.#pendingFrames = 0;
    this.#pendingBytes = 0;
  }

  async #drain(): Promise<void> {
    this.#writing = true;
    try {
      while (!this.#closed) {
        const frame = this.#queue.shift();
        if (frame === undefined) return;
        this.#active = frame;
        try {
          if (!this.#write(frame.bytes)) await once(this.#stream, "drain");
          if (this.#closed || this.#active !== frame) return;
          this.#active = undefined;
          this.#pendingFrames -= 1;
          this.#pendingBytes -= frame.bytes.length;
          frame.resolve();
        } catch (error) {
          this.close(error instanceof Error ? error : new Error(String(error)));
          return;
        }
      }
    } finally {
      this.#writing = false;
    }
  }
}
