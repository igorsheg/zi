export const MAX_HEADER_BYTES = 1024;
export const MAX_BODY_BYTES = 8 * 1024 * 1024;
export const MAX_JSON_DEPTH = 64;
export const MAX_JSON_TOKENS = 262_144;

const HEADER_END = Buffer.from("\r\n\r\n", "ascii");
const CONTENT_LENGTH_PREFIX = "Content-Length:";
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export class FrameError extends Error {
  override readonly name = "FrameError";
}

export type FrameSink = (body: Buffer) => void;

export class FrameDecoder {
  readonly #onFrame: FrameSink;
  readonly #header = Buffer.allocUnsafe(MAX_HEADER_BYTES + HEADER_END.length);
  #headerLength = 0;
  #body: Buffer | undefined;
  #bodyOffset = 0;
  #failed = false;

  constructor(onFrame: FrameSink) {
    this.#onFrame = onFrame;
  }

  push(chunk: Uint8Array): void {
    if (this.#failed) throw new FrameError("decoder is terminal after malformed input");
    let offset = 0;

    try {
      while (offset < chunk.byteLength) {
        if (this.#body !== undefined) {
          offset = this.#copyBody(chunk, offset);
        } else {
          offset = this.#copyHeader(chunk, offset);
        }
      }
    } catch (error) {
      this.#fail();
      throw error;
    }
  }

  finish(): void {
    if (this.#failed) return;
    if (this.#body !== undefined || this.#headerLength !== 0) {
      this.#fail();
      throw new FrameError("truncated frame");
    }
  }

  #copyHeader(chunk: Uint8Array, offset: number): number {
    this.#header[this.#headerLength] = chunk[offset] ?? 0;
    this.#headerLength += 1;
    offset += 1;

    if (this.#headerLength >= HEADER_END.length &&
        this.#header.subarray(this.#headerLength - HEADER_END.length, this.#headerLength).equals(HEADER_END)) {
      const headerLength = this.#headerLength - HEADER_END.length;
      const bodyLength = parseContentLength(this.#header.subarray(0, headerLength));
      this.#headerLength = 0;
      this.#body = Buffer.allocUnsafe(bodyLength);
      this.#bodyOffset = 0;
      if (bodyLength === 0) this.#publishBody();
      return offset;
    }

    if (this.#headerLength > MAX_HEADER_BYTES) {
      const delimiterBytes = this.#headerLength - MAX_HEADER_BYTES;
      if (delimiterBytes > HEADER_END.length ||
          !this.#header.subarray(MAX_HEADER_BYTES, this.#headerLength).equals(HEADER_END.subarray(0, delimiterBytes))) {
        throw new FrameError("header exceeds limit");
      }
    }
    return offset;
  }

  #copyBody(chunk: Uint8Array, offset: number): number {
    const body = this.#body;
    if (body === undefined) throw new FrameError("invalid decoder state");
    const count = Math.min(body.length - this.#bodyOffset, chunk.byteLength - offset);
    body.set(chunk.subarray(offset, offset + count), this.#bodyOffset);
    this.#bodyOffset += count;
    offset += count;
    if (this.#bodyOffset === body.length) this.#publishBody();
    return offset;
  }

  #publishBody(): void {
    const body = this.#body;
    if (body === undefined) throw new FrameError("invalid decoder state");
    validateBody(body);
    this.#body = undefined;
    this.#bodyOffset = 0;
    this.#onFrame(body);
  }

  #fail(): void {
    this.#failed = true;
    this.#headerLength = 0;
    this.#body = undefined;
    this.#bodyOffset = 0;
  }
}

export function encodeFrame(body: Uint8Array): Buffer {
  if (body.byteLength > MAX_BODY_BYTES) throw new FrameError("body exceeds limit");
  const header = Buffer.from(`Content-Length: ${body.byteLength}\r\n\r\n`, "ascii");
  return Buffer.concat([header, body], header.length + body.byteLength);
}

function parseContentLength(header: Buffer): number {
  const text = header.toString("ascii");
  const lines = text.split("\r\n");
  let length: number | undefined;

  for (const line of lines) {
    if (!line.startsWith(CONTENT_LENGTH_PREFIX)) throw new FrameError("unsupported frame header");
    if (length !== undefined) throw new FrameError("duplicate Content-Length");
    const raw = line.slice(CONTENT_LENGTH_PREFIX.length).trim();
    if (!/^(0|[1-9][0-9]*)$/.test(raw)) throw new FrameError("invalid Content-Length");
    const parsed = Number(raw);
    if (!Number.isSafeInteger(parsed) || parsed > MAX_BODY_BYTES) throw new FrameError("body exceeds limit");
    length = parsed;
  }

  if (length === undefined) throw new FrameError("missing Content-Length");
  return length;
}

function validateBody(body: Buffer): void {
  let text: string;
  try {
    text = utf8Decoder.decode(body);
  } catch {
    throw new FrameError("body is not valid UTF-8");
  }

  let value: unknown;
  try {
    value = JSON.parse(text) as unknown;
  } catch {
    throw new FrameError("body is not valid JSON");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new FrameError("JSON body must be an object");
  }
  validateJsonStructure(text);
}

function validateJsonStructure(text: string): void {
  let depth = 0;
  let tokens = 0;
  let inString = false;
  let escaped = false;
  let inPrimitive = false;

  for (const char of text) {
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (inPrimitive) {
      if (char !== "," && char !== "]" && char !== "}" && !isJsonWhitespace(char)) continue;
      inPrimitive = false;
    }

    if (isJsonWhitespace(char)) continue;
    if (char === '"') {
      inString = true;
      tokens += 1;
    } else if (char === "{" || char === "[") {
      depth += 1;
      tokens += 1;
      if (depth > MAX_JSON_DEPTH) throw new FrameError("JSON nesting exceeds limit");
    } else if (char === "}" || char === "]") {
      depth -= 1;
      tokens += 1;
    } else if (char === "," || char === ":") {
      tokens += 1;
    } else {
      inPrimitive = true;
      tokens += 1;
    }
    if (tokens > MAX_JSON_TOKENS) throw new FrameError("JSON token count exceeds limit");
  }
}

function isJsonWhitespace(char: string): boolean {
  return char === " " || char === "\t" || char === "\r" || char === "\n";
}
