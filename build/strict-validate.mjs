// strict-validate.mjs — validate a repaired session log with the REAL dsh
// persistence decoding (decodeStorageRecord from @deepseek-ai/dsh-session),
// mirroring SessionLogScanner.consumeEventLine's contiguity contract.
//
// Usage: node strict-validate.mjs <session.jsonl.zstd> [path-to-dsh-session-pkg]
// The optional second argument is the directory of the @deepseek-ai/dsh-session
// package (its lib/types/chunk-rows.js is imported). When omitted, common
// locations are probed (npm global install of @deepseek-ai/dsh, etc.).
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { zstdDecompressSync } from "node:zlib";

const path = process.argv[2];
if (!path) {
  console.error("usage: node strict-validate.mjs <session.jsonl.zstd> [dsh-session-package-dir]");
  process.exit(2);
}

function candidatePkgDirs() {
  const dirs = [];
  if (process.env.DSH_PKG) dirs.push(process.env.DSH_PKG);
  const home = process.env.USERPROFILE ?? process.env.HOME ?? "";
  const appdata = process.env.APPDATA ?? "";
  if (appdata) {
    dirs.push(join(appdata, "npm", "node_modules", "@deepseek-ai", "dsh", "node_modules", "@deepseek-ai", "dsh-session"));
  }
  if (home) {
    dirs.push(
      join(home, ".local", "share", "dsh", "node_modules", "@deepseek-ai", "dsh-session"),
      join(home, ".dsh", "profiles", "node_modules", "@deepseek-ai", "dsh-session")
    );
  }
  // dsh-portable extracted runtime layout
  if (appdata) {
    dirs.push(join(appdata, "Local", "dsh-exe"));
  }
  return dirs;
}

let chunkRowsUrl = null;
const explicit = process.argv[3];
const candidates = explicit ? [explicit] : candidatePkgDirs();
for (const dir of candidates) {
  const candidate = join(dir, "lib", "types", "chunk-rows.js");
  if (existsSync(candidate)) {
    chunkRowsUrl = pathToFileURL(candidate).href;
    break;
  }
}
if (chunkRowsUrl === null) {
  console.error("could not locate @deepseek-ai/dsh-session; pass its directory as the second argument or set DSH_PKG");
  process.exit(2);
}
const { decodeStorageRecord } = await import(chunkRowsUrl);

const buf = readFileSync(path);
const ZSTD_MAGIC = 4247762216;
const frames = [];
let offset = 0;
while (offset < buf.length) {
  const start = offset;
  if (buf.length - offset < 4) break;
  if (buf.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error("bad magic");
  offset += 4;
  const descriptor = buf.readUInt8(offset);
  offset += 1;
  const contentSizeFlag = descriptor >>> 6;
  const singleSegment = (descriptor & 32) !== 0;
  const checksum = (descriptor & 4) !== 0;
  const dictionaryFlag = descriptor & 3;
  const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
  const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
  const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
  if (buf.length - offset < remainingHeaderBytes) break;
  offset += remainingHeaderBytes;
  for (;;) {
    if (buf.length - offset < 3) break;
    const blockHeader = buf.readUIntLE(offset, 3);
    offset += 3;
    const lastBlock = (blockHeader & 1) !== 0;
    const blockType = blockHeader >>> 1 & 3;
    const blockSize = blockHeader >>> 3;
    if (blockType === 3) throw new Error("reserved block");
    const payloadBytes = blockType === 1 ? 1 : blockSize;
    if (buf.length - offset < payloadBytes) break;
    offset += payloadBytes;
    if (lastBlock) break;
  }
  if (checksum) {
    if (buf.length - offset < 4) break;
    offset += 4;
  }
  frames.push(buf.subarray(start, offset));
}
let all = "";
for (const f of frames) all += zstdDecompressSync(f).toString("utf8");
const lines = all.split("\n");
const header = JSON.parse(lines[0]);
console.log(`lines: ${lines.length}, header: ${header.type ?? "?"} id=${header.id ?? "?"}`);

const events = [];
let skipped = 0;
for (let i = 1; i < lines.length; i++) {
  const line = lines[i];
  if (line.trim() === "") continue;
  let decoded;
  try {
    decoded = decodeStorageRecord(JSON.parse(line));
  } catch (e) {
    skipped++;
    console.log(`UNPARSABLE line ${i + 1}: ${e.message.slice(0, 100)}`);
    continue;
  }
  for (const ev of decoded) {
    if (ev.seq !== events.length) {
      console.log(`SEQ MISMATCH line ${i + 1}: expected ${events.length}, got ${ev.seq} (${ev.type})`);
      process.exit(1);
    }
    events.push(ev);
  }
}
console.log(
  `strict scan OK: ${events.length} events, last seq ${events[events.length - 1]?.seq} (unparsable rows skipped: ${skipped})`
);
for (const [label, pred] of [
  ["turn/end", (e) => e.type === "turn/end"],
  ["user/message", (e) => e.type === "user/message"],
  ["assistant/message", (e) => e.type === "assistant/message"],
  ["tool/result", (e) => e.type === "tool/result"],
  ["session/end-seed", (e) => e.type === "session/end-seed"],
]) {
  console.log(`${label}: ${events.filter(pred).length}`);
}
