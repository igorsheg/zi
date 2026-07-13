export const PROTOCOL_MAJOR = 1;
export const PROTOCOL_MINOR = 0;
export const MAX_METHOD_BYTES = 128;
export const MAX_REQUEST_ID_BYTES = 64;

export interface RequestEnvelope {
  readonly jsonrpc: "2.0";
  readonly id: string;
  readonly method: string;
  readonly params?: unknown;
}

export interface NotificationEnvelope {
  readonly jsonrpc: "2.0";
  readonly method: string;
  readonly params?: unknown;
}

export interface ResponseEnvelope {
  readonly jsonrpc: "2.0";
  readonly id: string;
  readonly result?: unknown;
  readonly error?: {
    readonly code: number;
    readonly message: string;
  };
}

export type Envelope = RequestEnvelope | NotificationEnvelope | ResponseEnvelope;

export function decodeEnvelope(body: Buffer): Envelope {
  const value = JSON.parse(body.toString("utf8")) as Record<string, unknown>;
  if (value.jsonrpc !== "2.0") throw new Error("unsupported JSON-RPC version");

  if (value.method !== undefined) {
    if (typeof value.method !== "string" || value.method.length === 0 ||
        Buffer.byteLength(value.method) > MAX_METHOD_BYTES) {
      throw new Error("invalid JSON-RPC method");
    }
    if (value.result !== undefined || value.error !== undefined) throw new Error("invalid JSON-RPC request envelope");
    if (value.id !== undefined) validateRequestId(value.id, "z");
    return value as unknown as RequestEnvelope | NotificationEnvelope;
  }

  validateRequestId(value.id, "n");
  const hasResult = Object.hasOwn(value, "result");
  const hasError = Object.hasOwn(value, "error");
  if (hasResult === hasError) throw new Error("invalid JSON-RPC response envelope");
  if (hasError) {
    const error = value.error;
    if (!isRecord(error) || !Number.isSafeInteger(error.code) || typeof error.message !== "string") {
      throw new Error("invalid JSON-RPC error response");
    }
  }
  return value as unknown as ResponseEnvelope;
}

function validateRequestId(value: unknown, origin: "z" | "n"): asserts value is string {
  if (typeof value !== "string" || Buffer.byteLength(value) > MAX_REQUEST_ID_BYTES ||
      !new RegExp(`^${origin}:(0|[1-9][0-9]*)$`).test(value)) {
    throw new Error("invalid JSON-RPC request ID");
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
