import assert from "node:assert/strict";
import test from "node:test";
import {
  encodeFrame,
  FrameDecoder,
  FrameError,
  MAX_BODY_BYTES,
  MAX_HEADER_BYTES,
  MAX_JSON_DEPTH,
} from "../src/framing.ts";

const firstBody = Buffer.from('{"jsonrpc":"2.0","method":"host/ping"}');
const secondBody = Buffer.from('{"jsonrpc":"2.0","id":"z:1","result":{}}');

function decode(chunks: readonly Uint8Array[]): Buffer[] {
  const bodies: Buffer[] = [];
  const decoder = new FrameDecoder((body) => bodies.push(body));
  for (const chunk of chunks) decoder.push(chunk);
  decoder.finish();
  return bodies;
}

test("decodes a frame split at every byte boundary", () => {
  const frame = encodeFrame(firstBody);
  for (let split = 1; split < frame.length; split += 1) {
    const bodies = decode([frame.subarray(0, split), frame.subarray(split)]);
    assert.deepEqual(bodies, [firstBody]);
  }
});

test("decodes one-byte chunks and multiple frames in one chunk", () => {
  const joined = Buffer.concat([encodeFrame(firstBody), encodeFrame(secondBody)]);
  assert.deepEqual(decode([...joined].map((byte) => Uint8Array.of(byte))), [firstBody, secondBody]);
  assert.deepEqual(decode([joined]), [firstBody, secondBody]);
});

test("accepts a header exactly at the byte bound", () => {
  const prefix = "Content-Length:";
  const padding = " ".repeat(MAX_HEADER_BYTES - prefix.length - 1);
  const frame = Buffer.from(`${prefix}${padding}2\r\n\r\n{}`);
  assert.deepEqual(decode([frame]), [Buffer.from("{}")]);
});

test("rejects malformed Content-Length headers", () => {
  const malformed = [
    "Other: 2\r\n\r\n{}",
    "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
    "Content-Length: -1\r\n\r\n",
    "Content-Length: 01\r\n\r\n{}",
    `Content-Length: ${MAX_BODY_BYTES + 1}\r\n\r\n`,
    `${"x".repeat(MAX_HEADER_BYTES + 1)}\r\n\r\n`,
  ];

  for (const raw of malformed) {
    const decoder = new FrameDecoder(() => assert.fail("unexpected frame"));
    assert.throws(() => decoder.push(Buffer.from(raw)), FrameError);
    assert.throws(() => decoder.push(Buffer.from("{}")), /terminal/);
  }
});

test("rejects invalid UTF-8, JSON, and non-object JSON", () => {
  for (const body of [Buffer.from([0xff]), Buffer.from("{"), Buffer.from("[]")]) {
    const decoder = new FrameDecoder(() => assert.fail("unexpected frame"));
    assert.throws(() => decoder.push(encodeFrame(body)), FrameError);
  }
});

test("rejects JSON beyond the structural depth bound", () => {
  const body = Buffer.from(`{"value":${"[".repeat(MAX_JSON_DEPTH)}0${"]".repeat(MAX_JSON_DEPTH)}}`);
  const decoder = new FrameDecoder(() => assert.fail("unexpected frame"));
  assert.throws(() => decoder.push(encodeFrame(body)), /nesting exceeds limit/);
});

test("rejects truncated headers and bodies", () => {
  const frame = encodeFrame(firstBody);
  for (const truncated of [Buffer.from("Content-Length: 2\r\n"), frame.subarray(0, frame.length - 1)]) {
    const decoder = new FrameDecoder(() => assert.fail("unexpected frame"));
    decoder.push(truncated);
    assert.throws(() => decoder.finish(), /truncated/);
  }
});
