import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { FrameDecoder } from "./framing.ts";
import { createExtensionLoader } from "./loader.ts";
import { decodeEnvelope, PROTOCOL_MAJOR, PROTOCOL_MINOR, type Envelope, type RequestEnvelope } from "./protocol.ts";
import { SerializedFrameWriter } from "./transport.ts";

const transportStdout = process.stdout;
const writer = new SerializedFrameWriter(transportStdout);
const loadExtension = createExtensionLoader();
const MAX_ACTIVE_DISPATCHES = 32;
const MAX_DIAGNOSTIC_BYTES = 16 * 1024 * 1024;
const MAX_EXTENSIONS = 128;
const MAX_EXTENSION_PATH_BYTES = 16 * 1024;
const HOST_VERSION = "1.0.0";
const runtimeHostSha = createHash("sha256").update(await readFile(fileURLToPath(import.meta.url))).digest("hex");
let activeDispatches = 0;
let diagnosticBytes = 0;
let nextNodeRequestId = 0;
let handshakeComplete = false;
let modulesLoaded = false;
let hostPublished = false;
let shuttingDown = false;
let failed = false;
const pendingNodeRequests = new Map<string, {
  readonly resolve: (value: unknown) => void;
  readonly reject: (error: Error) => void;
}>();
const activeZigRequests = new Map<string, AbortController>();

reserveStdoutForTransport();

const decoder = new FrameDecoder((body) => {
  if (activeDispatches === MAX_ACTIVE_DISPATCHES) {
    failHost(new Error("inbound request capacity exceeded"));
    return;
  }
  const envelope = decodeEnvelope(body);
  activeDispatches += 1;
  void dispatch(envelope)
    .catch(failHost)
    .finally(() => { activeDispatches -= 1; });
});

process.stdin.on("data", (chunk: Buffer) => {
  try {
    decoder.push(chunk);
  } catch (error) {
    failHost(error);
  }
});
process.stdin.on("end", () => {
  try {
    decoder.finish();
    if (!shuttingDown) failHost(new Error("protocol input ended"));
  } catch (error) {
    failHost(error);
  }
});
process.stdin.on("error", failHost);
process.stdin.resume();

async function dispatch(envelope: Envelope): Promise<void> {
  if (!("method" in envelope)) {
    const pending = pendingNodeRequests.get(envelope.id);
    if (pending === undefined) throw new Error(`unknown response ID: ${envelope.id}`);
    pendingNodeRequests.delete(envelope.id);
    if (envelope.error !== undefined) pending.reject(new Error(envelope.error.message));
    else pending.resolve(envelope.result);
    return;
  }
  if (!("id" in envelope)) {
    dispatchNotification(envelope.method, envelope.params);
    return;
  }
  const request = envelope as RequestEnvelope;
  const controller = new AbortController();
  activeZigRequests.set(request.id, controller);
  try {
    await dispatchRequest(request, controller.signal);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await writer.send({ jsonrpc: "2.0", id: request.id, error: { code: -32000, message: message.slice(0, 4096) } });
  } finally {
    activeZigRequests.delete(request.id);
  }
}

function dispatchNotification(method: string, params: unknown): void {
  switch (method) {
    case "host/cancel": {
      const id = asRecord(params).id;
      if (typeof id !== "string" || !/^z:(0|[1-9][0-9]*)$/.test(id)) throw new Error("invalid cancellation ID");
      activeZigRequests.get(id)?.abort();
      return;
    }
    case "host/initialized":
      if (!modulesLoaded || hostPublished) throw new Error("invalid host activation notification");
      hostPublished = true;
      return;
    default:
      throw new Error(`unknown notification: ${method}`);
  }
}

async function dispatchRequest(request: RequestEnvelope, signal: AbortSignal): Promise<void> {
  switch (request.method) {
    case "host/initialize": {
      if (handshakeComplete) throw new Error("host is already initialized");
      const params = decodeInitializeParams(request.params);
      handshakeComplete = true;
      await respond(request.id, {
        protocol: { major: PROTOCOL_MAJOR, minor: PROTOCOL_MINOR },
        nodeVersion: testOverride("ZI_EXTENSION_HOST_TEST_NODE_VERSION") ?? process.versions.node,
        runtimeName: process.release.name,
        hostVersion: HOST_VERSION,
        hostSha: testOverride("ZI_EXTENSION_HOST_TEST_HOST_SHA") ?? runtimeHostSha,
        generationNonce: testOverride("ZI_EXTENSION_HOST_TEST_NONCE") ?? params.generationNonce,
      });
      return;
    }
    case "host/loadExtensions": {
      if (!handshakeComplete || modulesLoaded) throw new Error("invalid extension initialization state");
      const paths = decodeExtensionPaths(request.params);
      for (const path of paths) await loadExtension(path);
      modulesLoaded = true;
      await respond(request.id, { initialized: true });
      return;
    }
    case "host/ping":
      requirePublishedHost();
      await respond(request.id, { pong: true });
      return;
    case "host/testNested": {
      requireTestProbe();
      requirePublishedHost();
      const value = await callZig("host/test/echo", request.params ?? null);
      await respond(request.id, { nested: value });
      return;
    }
    case "host/testWait":
      requireTestProbe();
      requirePublishedHost();
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(resolve, 60_000);
        signal.addEventListener("abort", () => {
          clearTimeout(timer);
          reject(new Error("canceled"));
        }, { once: true });
      });
      await respond(request.id, { waited: true });
      return;
    case "host/testSpin":
      requireTestProbe();
      requirePublishedHost();
      while (true) { /* deliberate integration-test probe */ }
    case "host/testCrash":
      requireTestProbe();
      requirePublishedHost();
      process.exit(17);
    case "host/testMalformed": {
      requireTestProbe();
      requirePublishedHost();
      const { writeSync } = await import("node:fs");
      writeSync(1, "x".repeat(1100));
      return;
    }
    case "host/shutdown":
      shuttingDown = true;
      for (const [id, controllerValue] of activeZigRequests) {
        if (id !== request.id) controllerValue.abort();
      }
      for (const pending of pendingNodeRequests.values()) pending.reject(new Error("host is shutting down"));
      pendingNodeRequests.clear();
      await respond(request.id, { stopped: true });
      process.stdin.destroy();
      return;
    default:
      await writer.send({
        jsonrpc: "2.0",
        id: request.id,
        error: { code: -32601, message: "method not found" },
      });
  }
}

function decodeInitializeParams(value: unknown): { readonly generationNonce: string } {
  const params = asRecord(value);
  const protocol = asRecord(params.protocol);
  if (protocol.major !== PROTOCOL_MAJOR || protocol.minor !== PROTOCOL_MINOR) {
    throw new Error("unsupported protocol version");
  }
  if (typeof params.hostSha !== "string" || !/^[0-9a-f]{64}$/.test(params.hostSha) ||
      params.hostSha !== runtimeHostSha) {
    throw new Error("host SHA-256 mismatch");
  }
  if (typeof params.ziVersion !== "string" || params.ziVersion.length === 0 || params.ziVersion.length > 128) {
    throw new Error("invalid Zi version");
  }
  if (typeof params.cwd !== "string" || params.cwd.length === 0) throw new Error("invalid cwd");
  if (typeof params.generationNonce !== "string" || !/^[0-9a-f]{32}$/.test(params.generationNonce)) {
    throw new Error("invalid generation nonce");
  }
  return { generationNonce: params.generationNonce };
}

function decodeExtensionPaths(value: unknown): readonly string[] {
  const paths = asRecord(value).extensions;
  if (!Array.isArray(paths) || paths.length === 0 || paths.length > MAX_EXTENSIONS) {
    throw new Error("invalid extension load plan");
  }
  for (const path of paths) {
    if (typeof path !== "string" || !isAbsolute(path) || Buffer.byteLength(path) > MAX_EXTENSION_PATH_BYTES) {
      throw new Error("invalid extension path");
    }
  }
  return paths as string[];
}

function requirePublishedHost(): void {
  if (!hostPublished) throw new Error("host is not active");
}

function requireTestProbe(): void {
  if (process.env.ZI_EXTENSION_HOST_TEST !== "1") throw new Error("test probe disabled");
}

function testOverride(name: string): string | undefined {
  return process.env.ZI_EXTENSION_HOST_TEST === "1" ? process.env[name] : undefined;
}

async function respond(id: string, result: unknown): Promise<void> {
  await writer.send({ jsonrpc: "2.0", id, result });
}

async function callZig(method: string, params: unknown): Promise<unknown> {
  if (pendingNodeRequests.size === 32) throw new Error("Node request capacity exceeded");
  if (nextNodeRequestId === Number.MAX_SAFE_INTEGER) throw new Error("Node request ID exhausted");
  const id = `n:${nextNodeRequestId}`;
  nextNodeRequestId += 1;
  const completion = new Promise<unknown>((resolve, reject) => {
    pendingNodeRequests.set(id, { resolve, reject });
  });
  try {
    await writer.send({ jsonrpc: "2.0", id, method, params });
  } catch (error) {
    pendingNodeRequests.delete(id);
    throw error;
  }
  return completion;
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function failHost(error: unknown): void {
  if (failed) return;
  failed = true;
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  process.stderr.write(`${message.slice(0, 16 * 1024)}\n`);
  writer.close();
  process.exitCode = 1;
  process.stdin.destroy();
}

function reserveStdoutForTransport(): void {
  const diagnosticWrite = ((chunk: unknown, encodingOrCallback?: unknown, callback?: unknown): boolean => {
    const encoding = typeof encodingOrCallback === "string" ? encodingOrCallback as BufferEncoding : undefined;
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk), encoding);
    const remaining = Math.max(0, MAX_DIAGNOSTIC_BYTES - diagnosticBytes);
    const retained = bytes.subarray(0, remaining);
    diagnosticBytes += retained.length;
    if (retained.length !== bytes.length) queueMicrotask(() => failHost(new Error("diagnostic byte limit exceeded")));
    const result = retained.length === 0 || process.stderr.write(retained);
    const done = typeof encodingOrCallback === "function"
      ? encodingOrCallback
      : typeof callback === "function" ? callback : undefined;
    if (done !== undefined) queueMicrotask(() => done());
    return result;
  }) as typeof process.stdout.write;
  process.stdout.write = diagnosticWrite;

  console.log = (...args: unknown[]) => console.error(...args);
  console.info = (...args: unknown[]) => console.error(...args);
  console.debug = (...args: unknown[]) => console.error(...args);
  console.warn = (...args: unknown[]) => console.error(...args);
}
