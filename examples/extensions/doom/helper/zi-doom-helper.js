#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");
const https = require("node:https");

const OUT_COLS = 100;
const OUT_ROWS = 31;
const FPS = 35;
const KEY_HOLD_MS = 140;

const DoomKeys = {
  right: 0xae,
  left: 0xac,
  up: 0xad,
  down: 0xaf,
  strafe_l: 0xa0,
  strafe_r: 0xa1,
  use: 0xa2,
  fire: 0xa3,
  escape: 27,
  enter: 13,
  tab: 9,
  backspace: 127,
  pause: 0xff,
  equals: 0x3d,
  minus: 0x2d,
  shift: 0x80 + 0x36,
};

function usage() {
  process.stderr.write(`zi-doom-helper\n\nUsage:\n  zi-doom-helper [--wad PATH] [--download-wad PATH] [--smoke]\n\nStdout protocol:\n  CELLS <cols> <rows> <byte_len>\\n<fg_rgb bg_rgb cells>\n\nStdin protocol:\n  KEY <action> <key> <ctrl> <alt> <shift> <quoted-text>\n`);
}

function argValue(args, name) {
  const idx = args.indexOf(name);
  if (idx < 0) return null;
  return args[idx + 1] || null;
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const file = fs.createWriteStream(dest);
    const get = (u) => https.get(u, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode || 0) && res.headers.location) {
        res.resume();
        get(new URL(res.headers.location, u).toString()).on("error", reject);
        return;
      }
      if (res.statusCode !== 200) {
        reject(new Error(`download failed: HTTP ${res.statusCode}`));
        res.resume();
        return;
      }
      res.pipe(file);
      file.on("finish", () => file.close(resolve));
    });
    get(url).on("error", reject);
  });
}

async function ensureWad(defaultPath) {
  if (fs.existsSync(defaultPath)) return defaultPath;
  const url = "https://distro.ibiblio.org/slitaz/sources/packages/d/doom1.wad";
  process.stderr.write(`Downloading shareware DOOM WAD to ${defaultPath}\n`);
  await download(url, defaultPath);
  return defaultPath;
}

async function loadDoom(wadPath) {
  const root = path.resolve(__dirname, "..");
  const buildDir = path.join(root, "doom", "build");
  const doomJsPath = path.join(buildDir, "doom.js");
  const doomJsCode = fs.readFileSync(doomJsPath, "utf8");
  const moduleExports = { exports: {} };
  const nativeRequire = createRequire(doomJsPath);
  const moduleFunc = new Function("module", "exports", "__dirname", "__filename", "require", doomJsCode);
  moduleFunc(moduleExports, moduleExports.exports, buildDir, doomJsPath, nativeRequire);
  const createDoomModule = moduleExports.exports;
  const wadArray = Array.from(new Uint8Array(fs.readFileSync(wadPath)));
  const mod = await createDoomModule({
    locateFile: (p) => p.endsWith(".wasm") ? path.join(buildDir, p) : p,
    print: () => {},
    printErr: (s) => { if (s) process.stderr.write(String(s) + "\n"); },
    preRun: [(m) => {
      m.FS_createPath("/", "doom", true, true);
      m.FS_createDataFile("/doom", "doom1.wad", wadArray, true, false);
    }],
  });

  const args = ["doom", "-iwad", "/doom/doom1.wad"];
  const ptrs = args.map((s) => {
    const ptr = mod._malloc(s.length + 1);
    for (let i = 0; i < s.length; i++) mod.setValue(ptr + i, s.charCodeAt(i), "i8");
    mod.setValue(ptr + s.length, 0, "i8");
    return ptr;
  });
  const argv = mod._malloc(ptrs.length * 4);
  ptrs.forEach((ptr, i) => mod.setValue(argv + i * 4, ptr, "i32"));
  mod._doomgeneric_Create(args.length, argv);
  ptrs.forEach((ptr) => mod._free(ptr));
  mod._free(argv);

  return {
    mod,
    width: mod._DG_GetScreenWidth(),
    height: mod._DG_GetScreenHeight(),
    frameBufferPtr: mod._DG_GetFrameBuffer(),
  };
}

function mapKey(ev) {
  const key = ev.key;
  const text = ev.text || "";
  let keys;
  switch (key) {
    case "left": keys = [DoomKeys.left]; break;
    case "right": keys = [DoomKeys.right]; break;
    case "up": keys = [DoomKeys.up]; break;
    case "down": keys = [DoomKeys.down]; break;
    case "w": case "W": keys = [DoomKeys.up]; break;
    case "s": case "S": keys = [DoomKeys.down]; break;
    case "a": case "A": keys = [DoomKeys.strafe_l]; break;
    case "d": case "D": keys = [DoomKeys.strafe_r]; break;
    case "space": keys = [DoomKeys.use]; break;
    case "enter": keys = [DoomKeys.enter]; break;
    case "tab": keys = [DoomKeys.tab]; break;
    case "backspace": keys = [DoomKeys.backspace]; break;
    case "f": case "F": keys = [DoomKeys.fire]; break;
    case "=": case "+": keys = [DoomKeys.equals]; break;
    case "-": keys = [DoomKeys.minus]; break;
    default:
      if (text.length === 1) keys = [text.toLowerCase().charCodeAt(0)];
      else if (key.length === 1) keys = [key.toLowerCase().charCodeAt(0)];
      else keys = [];
  }
  if (ev.shift && keys.length && !keys.includes(DoomKeys.shift) && isMovementKey(key)) {
    keys = keys.concat(DoomKeys.shift);
  }
  return keys;
}

function isMovementKey(key) {
  return key === "w" || key === "W" || key === "a" || key === "A" || key === "s" || key === "S" || key === "d" || key === "D" || key === "up" || key === "down" || key === "left" || key === "right";
}

const heldKeys = new Map();
function pushHeld(engine, ev) {
  const now = Date.now();
  for (const doomKey of mapKey(ev)) {
    if (!heldKeys.has(doomKey)) engine.mod._DG_PushKeyEvent(1, doomKey);
    heldKeys.set(doomKey, now + KEY_HOLD_MS);
  }
}

function releaseExpiredKeys(engine) {
  const now = Date.now();
  for (const [doomKey, until] of heldKeys) {
    if (until <= now) {
      engine.mod._DG_PushKeyEvent(0, doomKey);
      heldKeys.delete(doomKey);
    }
  }
}

function fillCellFrame(engine, out) {
  const heap = engine.mod.HEAPU32;
  const src = engine.frameBufferPtr >>> 2;
  const x_step = engine.width / OUT_COLS;
  const y_step = engine.height / (OUT_ROWS * 2);
  let dst = 0;
  for (let row = 0; row < OUT_ROWS; row++) {
    const sy1 = Math.floor(row * 2 * y_step);
    const sy2 = Math.floor((row * 2 + 1) * y_step);
    const row1 = src + sy1 * engine.width;
    const row2 = src + sy2 * engine.width;
    for (let col = 0; col < OUT_COLS; col++) {
      const sx = Math.floor(col * x_step);
      const upper = heap[row1 + sx];
      const lower = heap[row2 + sx];
      out[dst++] = (upper >> 16) & 0xff;
      out[dst++] = (upper >> 8) & 0xff;
      out[dst++] = upper & 0xff;
      out[dst++] = (lower >> 16) & 0xff;
      out[dst++] = (lower >> 8) & 0xff;
      out[dst++] = lower & 0xff;
    }
  }
}

function writeAll(stream, chunk) {
  return new Promise((resolve, reject) => {
    const ok = stream.write(chunk, (err) => err ? reject(err) : resolve());
    if (!ok) stream.once("error", reject);
  });
}

function parseLuaQuotedString(value) {
  if (!value || value.length < 2 || value[0] !== '"') return "";
  let out = "";
  for (let i = 1; i < value.length - 1; i++) {
    const ch = value[i];
    if (ch !== "\\") { out += ch; continue; }
    const next = value[++i];
    if (next === "n") out += "\n";
    else if (next === "r") out += "\r";
    else if (next === "t") out += "\t";
    else if (next === "\\" || next === '"') out += next;
    else if (/[0-9]/.test(next || "")) {
      let digits = next;
      while (i + 1 < value.length - 1 && digits.length < 3 && /[0-9]/.test(value[i + 1])) digits += value[++i];
      out += String.fromCharCode(Number(digits) || 0);
    }
  }
  return out;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) { usage(); return; }
  const root = path.resolve(__dirname, "..");
  const defaultWad = path.join(root, "doom1.wad");
  const downloadPath = argValue(args, "--download-wad");
  if (downloadPath) { await ensureWad(path.resolve(downloadPath)); return; }
  if (args.includes("--smoke")) { process.stderr.write("ok\n"); return; }

  const wad = path.resolve(argValue(args, "--wad") || await ensureWad(defaultWad));
  const engine = await loadDoom(wad);
  process.stderr.write(`DOOM loaded: ${engine.width}x${engine.height}\n`);

  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    input += chunk;
    for (;;) {
      const nl = input.indexOf("\n");
      if (nl < 0) break;
      const line = input.slice(0, nl).trim();
      input = input.slice(nl + 1);
      const m = /^KEY\s+(\S+)\s+(\S+)\s+([01])\s+([01])\s+([01])\s+(.*)$/.exec(line);
      if (m) pushHeld(engine, {
        action: m[1],
        key: m[2],
        ctrl: m[3] === "1",
        alt: m[4] === "1",
        shift: m[5] === "1",
        text: parseLuaQuotedString(m[6]),
      });
      else {
        const legacy = /^KEY\s+(.+)$/.exec(line);
        if (legacy) pushHeld(engine, { action: "press", key: legacy[1], ctrl: false, alt: false, shift: false, text: "" });
      }
    }
  });

  const cells = Buffer.allocUnsafe(OUT_COLS * OUT_ROWS * 6);
  const frameDelayMs = 1000 / FPS;
  const writeFrame = async () => {
    const start = Date.now();
    try {
      releaseExpiredKeys(engine);
      engine.mod._doomgeneric_Tick();
      fillCellFrame(engine, cells);
      await writeAll(process.stdout, `CELLS ${OUT_COLS} ${OUT_ROWS} ${cells.length}\n`);
      await writeAll(process.stdout, cells);
    } catch (err) {
      process.stderr.write(`DOOM stopped: ${err && err.stack || err}\n`);
      process.exit(0);
    }
    setTimeout(writeFrame, Math.max(0, frameDelayMs - (Date.now() - start)));
  };
  writeFrame();
}

main().catch((err) => {
  process.stderr.write(String(err && err.stack || err) + "\n");
  process.exit(1);
});
