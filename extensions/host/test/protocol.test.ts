import assert from "node:assert/strict";
import test from "node:test";
import { decodeEnvelope, MAX_METHOD_BYTES, MAX_REQUEST_ID_BYTES } from "../src/protocol.ts";

test("validates JSON-RPC version, shape, direction, and bounded discriminators", () => {
  assert.deepEqual(
    decodeEnvelope(Buffer.from('{"jsonrpc":"2.0","id":"n:1","result":{}}')),
    { jsonrpc: "2.0", id: "n:1", result: {} },
  );
  assert.deepEqual(
    decodeEnvelope(Buffer.from('{"jsonrpc":"2.0","id":"z:1","method":"host/ping","params":{}}')),
    { jsonrpc: "2.0", id: "z:1", method: "host/ping", params: {} },
  );
  assert.throws(() => decodeEnvelope(Buffer.from('{"jsonrpc":"1.0"}')), /version/);
  assert.throws(() => decodeEnvelope(Buffer.from('{"jsonrpc":"2.0","id":"z:1","result":{}}')), /request ID/);
  assert.throws(() => decodeEnvelope(Buffer.from('{"jsonrpc":"2.0","id":"n:1","method":"host/ping"}')), /request ID/);
  assert.throws(() => decodeEnvelope(Buffer.from('{"jsonrpc":"2.0","id":"n:1"}')), /response envelope/);
  assert.throws(
    () => decodeEnvelope(Buffer.from('{"jsonrpc":"2.0","id":"n:1","result":{},"error":{"code":1,"message":"x"}}')),
    /response envelope/,
  );
  assert.throws(
    () => decodeEnvelope(Buffer.from(JSON.stringify({ jsonrpc: "2.0", method: "x".repeat(MAX_METHOD_BYTES + 1) }))),
    /method/,
  );
  assert.throws(
    () => decodeEnvelope(Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: `n:${"1".repeat(MAX_REQUEST_ID_BYTES)}`, result: null }))),
    /request ID/,
  );
});
