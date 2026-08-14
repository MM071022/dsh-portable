// repair-session-log.mjs — repair a dsh session JSONL.zstd log that contains a
// rewound (duplicated seq) block, which makes the persistence reader refuse the
// whole log ("corrupt session log: seq gap in committed region" → 历史加载失败).
//
// Semantics: when a later block rewrites an already-committed seq range (the
// signature of a concurrent/stale writer — e.g. a second `dsh web` server
// appending the same session), the later block is authoritative: the superseded
// committed events at seq >= rewindStart are discarded and the later block is
// adopted as the continuation. A true gap (missing seqs, nothing to adopt) is
// reported and left untouched.
//
// Usage: node repair-session-log.mjs <path-to-session.jsonl.zstd>
// The original file is preserved as <path>.bak-<timestamp>.
import { readFileSync, writeFileSync, renameSync, statSync } from "node:fs";
import { constants as zlibConstants, zstdCompressSync, zstdDecompressSync } from "node:zlib";
import { join } from "node:path";

const path = process.argv[2];
if (!path) {
  console.error("usage: node repair-session-log.mjs <session.jsonl.zstd>");
  process.exit(2);
}

// --- zstd frame scan + decompress -------------------------------------------
// Mirrors @deepseek-ai/dsh-session-persistence-jsonl scanZstdFrames: parses the
// frame header + block headers to find exact frame boundaries (a naive
// magic-byte scan can split a frame whose compressed payload contains the
// magic sequence).
const ZSTD_MAGIC = 4247762216; // 0xFD2FB528

function scanZstdFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (offset < buffer.length) {
    const start = offset;
    if (buffer.length - offset < 4) break; // torn final frame
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) {
      throw new Error(`corrupt Zstandard frame: invalid magic at byte ${offset}`);
    }
    offset += 4;
    if (offset === buffer.length) break;
    const descriptor = buffer.readUInt8(offset);
    offset += 1;
    if ((descriptor & 24) !== 0) throw new Error(`reserved frame-header bit at byte ${offset - 1}`);
    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 32) !== 0;
    const checksum = (descriptor & 4) !== 0;
    const dictionaryFlag = descriptor & 3;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    if (buffer.length - offset < remainingHeaderBytes) break;
    offset += remainingHeaderBytes;
    for (;;) {
      if (buffer.length - offset < 3) break;
      const blockHeader = buffer.readUIntLE(offset, 3);
      offset += 3;
      const lastBlock = (blockHeader & 1) !== 0;
      const blockType = blockHeader >>> 1 & 3;
      const blockSize = blockHeader >>> 3;
      if (blockType === 3) throw new Error(`reserved block type at byte ${offset - 3}`);
      const payloadBytes = blockType === 1 ? 1 : blockSize;
      if (buffer.length - offset < payloadBytes) break;
      offset += payloadBytes;
      if (lastBlock) break;
    }
    if (checksum) {
      if (buffer.length - offset < 4) break;
      offset += 4;
    }
    frames.push(buffer.subarray(start, offset));
  }
  return frames;
}

function decompressAll(buf) {
  let all = "";
  const frames = scanZstdFrames(buf);
  for (const f of frames) {
    try {
      all += zstdDecompressSync(f).toString("utf8");
    } catch (e) {
      throw new Error(`zstd frame decode failed at byte ${f.byteOffset}: ${e.message}`);
    }
  }
  return all;
}

// --- seq range of one JSONL event row ---------------------------------------
function seqRange(line, index) {
  let value;
  try {
    value = JSON.parse(line);
  } catch {
    return null; // unparsable row — leave untouched handling to caller
  }
  if (value === null || typeof value !== "object") return null;
  const tag = value.type;
  if (tag === "text-chunks" || tag === "reasoning-chunks" || tag === "tool-call-chunks") {
    if (!Number.isSafeInteger(value.seq0)) return null;
    const members = tag === "tool-call-chunks" ? value.data?.args : value.data?.texts;
    if (!Array.isArray(members) || members.length === 0) return null;
    return { min: value.seq0, max: value.seq0 + members.length - 1, type: tag };
  }
  if (Number.isSafeInteger(value.seq)) return { min: value.seq, max: value.seq, type: value.type };
  return null; // e.g. the header line
}

// --- main --------------------------------------------------------------------
const original = readFileSync(path);
const plaintext = decompressAll(original);
const lines = plaintext.split("\n");
// Drop a trailing empty fragment (file ends with "\n").
if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
if (lines.length < 2) {
  console.error("log has no event lines; nothing to do");
  process.exit(0);
}

const headerLine = lines[0];
const headerRange = seqRange(headerLine, 0);
if (headerRange !== null) {
  console.error("first line is not a session header; refusing to repair");
  process.exit(1);
}

const accepted = []; // { line, max }
let nextExpected = 0;
let rewinds = 0;
let repairs = 0;
let firstRewindLine = -1;
let lastRewindLine = -1;

for (let i = 1; i < lines.length; i++) {
  const line = lines[i];
  if (line === "") continue;
  const range = seqRange(line, i + 1);
  if (range === null) {
    // Unparsable/unknown row: leave it in place (matches the reader's fail-open
    // behaviour for ignorable rows); it carries no seq, so accept blindly.
    accepted.push({ line, max: -1 });
    continue;
  }
  if (range.min < nextExpected) {
    // Rewind: a later block supersedes committed events at seq >= range.min.
    rewinds++;
    if (firstRewindLine === -1) firstRewindLine = i + 1;
    lastRewindLine = i + 1;
    let dropped = 0;
    while (accepted.length > 0 && accepted[accepted.length - 1].max >= range.min) {
      accepted.pop();
      dropped++;
    }
    nextExpected = range.min;
    repairs += dropped;
    accepted.push({ line, max: range.max });
    nextExpected = range.max + 1;
    continue;
  }
  if (range.min > nextExpected) {
    console.error(
      `seq gap at line ${i + 1}: expected ${nextExpected}, got ${range.min}; ` +
        "cannot repair automatically — run with a backup and inspect manually"
    );
    process.exit(1);
  }
  accepted.push({ line, max: range.max });
  nextExpected = range.max + 1;
}

console.log(`input: ${lines.length} lines, last seq ${nextExpected - 1}`);
if (rewinds === 0) {
  console.log("no rewound blocks found; log is clean (or only packed-run gaps present)");
  process.exit(0);
}
console.log(`rewound block(s): ${rewinds} (first at line ${firstRewindLine}, last at line ${lastRewindLine}), superseded events dropped: ${repairs}`);

// Re-encode: header frame + event frame, mirroring the writer's layout
// (checksummed frames, like the persistence backend's CHECKSUM_OPTIONS).
function compressFrame(input) {
  return zstdCompressSync(input, { params: { [zlibConstants.ZSTD_c_checksumFlag]: 1 } });
}
const outHeader = Buffer.from(headerLine + "\n", "utf8");
const outEvents = Buffer.from(accepted.map((a) => a.line).join("\n") + "\n", "utf8");
const repaired = Buffer.concat([
  compressFrame(outHeader),
  compressFrame(outEvents),
]);

// Verify the repaired plaintext walks cleanly before committing.
const verifyText = decompressAll(repaired);
const verifyLines = verifyText.split("\n").filter((l) => l.trim() !== "");
let vExpected = 0;
for (let i = 1; i < verifyLines.length; i++) {
  const r = seqRange(verifyLines[i], i + 1);
  if (r === null) continue;
  if (r.min !== vExpected) {
    console.error(`VERIFY FAILED at line ${i + 1}: expected ${vExpected}, got ${r.min}`);
    process.exit(1);
  }
  vExpected = r.max + 1;
}
console.log(`verify: repaired log is seq-contiguous through ${vExpected - 1}`);

// Commit: backup + atomic replace.
const ts = new Date().toISOString().replace(/[:.]/g, "-");
const backup = `${path}.bak-${ts}`;
renameSync(path, backup);
try {
  writeFileSync(path, repaired);
} catch (e) {
  // restore backup on failure
  try { renameSync(backup, path); } catch {}
  throw e;
}
console.log(`repaired: wrote ${path} (${repaired.length} bytes, was ${original.length}); backup at ${backup}`);
