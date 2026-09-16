/* ai2pixel Studio — exportadores: GIF89a (LZW validado), ZIP (store), paletas */

function lzw(indices, mcs) {
  const clear = 1 << mcs, end = clear + 1;
  let table = new Map(), nxt = end + 1, w = mcs + 1;
  for (let i = 0; i < clear; i++) table.set(String(i), i);
  const emitted = [[clear, w]];
  let cur = null;
  const reset = () => { table = new Map(); for (let i = 0; i < clear; i++) table.set(String(i), i); nxt = end + 1; w = mcs + 1; };
  for (const k of indices) {
    const wk = cur === null ? String(k) : cur + ',' + k;
    if (table.has(wk)) { cur = wk; continue; }
    emitted.push([table.get(cur), w]);
    if (nxt < 4096) {
      table.set(wk, nxt); nxt++;
      if (nxt > (1 << w) && w < 12) w++;
    } else { emitted.push([clear, w]); reset(); }
    cur = String(k);
  }
  if (cur !== null) emitted.push([table.get(cur), w]);
  emitted.push([end, w]);
  let acc = 0, nb = 0;
  const buf = [];
  for (const [c, cs] of emitted) {
    acc |= c << nb; nb += cs;
    while (nb >= 8) { buf.push(acc & 255); acc >>= 8; nb -= 8; }
  }
  if (nb) buf.push(acc & 255);
  const chunks = [];
  for (let i = 0; i < buf.length; i += 255) {
    const blk = buf.slice(i, i + 255);
    chunks.push(blk.length, ...blk);
  }
  chunks.push(0);
  return new Uint8Array(chunks);
}

export function encodeGif(frames, palette, w, h, delayCs) {
  const n = palette.length;
  const bits = Math.max(1, Math.ceil(Math.log2(Math.max(2, n + 1))));
  const size = 1 << bits;
  const tidx = size - 1;
  const mcs = Math.max(2, bits);
  const out = [];
  const push = (...b) => out.push(...b);
  push(...[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
  push(w & 255, w >> 8, h & 255, h >> 8);
  push(0xF0 | (bits - 1), 0, 0);
  for (let i = 0; i < size; i++) {
    const c = i < n ? palette[i] : [0, 0, 0];
    push(c[0], c[1], c[2]);
  }
  push(0x21, 0xFF, 0x0B, ...[... 'NETSCAPE2.0'].map((c) => c.charCodeAt(0)), 0x03, 0x01, 0x00, 0x00, 0x00);
  for (const f of frames) {
    push(0x21, 0xF9, 0x04);
    push((2 << 2) | 0x01);
    push(delayCs & 255, delayCs >> 8);
    push(tidx);
    push(0);
    push(0x2C, 0, 0, 0, 0, w & 255, w >> 8, h & 255, h >> 8, 0);
    push(mcs);
    const flat = new Array(w * h);
    for (let i = 0; i < w * h; i++) flat[i] = f[i] < 0 ? tidx : f[i];
    out.push(...lzw(flat, mcs));
  }
  push(0x3B);
  return new Uint8Array(out);
}

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();
function crc32(u8) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < u8.length; i++) c = CRC_TABLE[(c ^ u8[i]) & 255] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

export function encodeZip(entries) { // [{name, bytes:Uint8Array}]
  const chunks = [], central = [];
  let offset = 0;
  const enc = new TextEncoder();
  for (const e of entries) {
    const nb = enc.encode(e.name);
    const crc = crc32(e.bytes);
    const lh = new Uint8Array(30 + nb.length);
    const dv = new DataView(lh.buffer);
    dv.setUint32(0, 0x04034b50, true); dv.setUint16(4, 20, true); dv.setUint16(6, 0, true);
    dv.setUint16(8, 0, true); dv.setUint16(10, 0, true); dv.setUint16(12, 0, true);
    dv.setUint32(14, crc, true); dv.setUint32(18, e.bytes.length, true); dv.setUint32(22, e.bytes.length, true);
    dv.setUint16(26, nb.length, true); dv.setUint16(28, 0, true);
    lh.set(nb, 30);
    chunks.push(lh, e.bytes);
    const ch = new Uint8Array(46 + nb.length);
    const cv = new DataView(ch.buffer);
    cv.setUint32(0, 0x02014b50, true); cv.setUint16(4, 20, true); cv.setUint16(6, 20, true);
    cv.setUint16(8, 0, true); cv.setUint16(10, 0, true); cv.setUint16(12, 0, true); cv.setUint16(14, 0, true);
    cv.setUint32(16, crc, true); cv.setUint32(20, e.bytes.length, true); cv.setUint32(24, e.bytes.length, true);
    cv.setUint16(28, nb.length, true);
    cv.setUint32(42, offset, true);
    ch.set(nb, 46);
    central.push(ch);
    offset += lh.length + e.bytes.length;
  }
  const cdSize = central.reduce((a, c) => a + c.length, 0);
  const eo = new Uint8Array(22);
  const ev = new DataView(eo.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, entries.length, true); ev.setUint16(10, entries.length, true);
  ev.setUint32(12, cdSize, true); ev.setUint32(16, offset, true);
  const total = new Uint8Array(offset + cdSize + 22);
  let p = 0;
  for (const c of [...chunks, ...central, eo]) { total.set(c, p); p += c.length; }
  return total;
}

export function gplText(name, palette) {
  let s = `GIMP Palette\nName: ${name}\nColumns: 0\n#\n`;
  palette.forEach((c, i) => { s += `${String(c[0]).padStart(3)} ${String(c[1]).padStart(3)} ${String(c[2]).padStart(3)}\tC${String(i).padStart(2, '0')}\n`; });
  return s;
}

export function actBytes(palette) {
  const b = new Uint8Array(768 + 4);
  palette.forEach((c, i) => { b[i * 3] = c[0]; b[i * 3 + 1] = c[1]; b[i * 3 + 2] = c[2]; });
  b[768] = 0; b[769] = palette.length; b[770] = 0; b[771] = 0;
  return b;
}

export function download(bytes, name, mime = 'application/octet-stream') {
  const blob = bytes instanceof Blob ? bytes : new Blob([bytes], { type: mime });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 4000);
}
