/* ai2pixel Studio — núcleo da metodologia Grade-Nativa (port JS do pipeline Python)
 * Estágios: chroma-key -> detecção de grade (RANSAC + regressão) -> reamostragem
 * nativa (mediana no miolo) -> paleta global OKLab (exata ou k-means) -> snap +
 * limpeza de órfãos -> exportação nativa. Sem dependências externas.
 */

// ---------------- cor: sRGB <-> OKLab ----------------
export function rgbToOklab(r, g, b) {
  const f = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  const R = f(r), G = f(g), B = f(b);
  const l = 0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B;
  const m = 0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B;
  const s = 0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B;
  const l_ = Math.cbrt(l), m_ = Math.cbrt(m), s_ = Math.cbrt(s);
  return [
    0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
  ];
}
export function oklabToRgb(L, a, b) {
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
  const l = l_ ** 3, m = m_ ** 3, s = s_ ** 3;
  const inv = (c) => { c = Math.min(1, Math.max(0, c)); return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055; };
  return [
    Math.round(inv(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s) * 255),
    Math.round(inv(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s) * 255),
    Math.round(inv(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s) * 255),
  ];
}

// ---------------- estágio 1: chroma-key ----------------
export function detectChromaKey(d, w, h) {
  const t = Math.max(1, Math.floor(0.02 * Math.min(w, h)));
  const cnt = new Map();
  let total = 0;
  const add = (i) => {
    if (d[i + 3] <= 200) return;
    const k = ((d[i] >> 4) << 8) | ((d[i + 1] >> 4) << 4) | (d[i + 2] >> 4);
    cnt.set(k, (cnt.get(k) || 0) + 1); total++;
  };
  for (let y = 0; y < t; y++) for (let x = 0; x < w; x++) add((y * w + x) * 4);
  for (let y = h - t; y < h; y++) for (let x = 0; x < w; x++) add((y * w + x) * 4);
  for (let y = 0; y < h; y++) for (const x of [0, 1, w - 2, w - 1]) add((y * w + x) * 4);
  if (!total) return null;
  let bk = 0, bv = 0;
  for (const [k, v] of cnt) if (v > bv) { bv = v; bk = k; }
  const cov = bv / total;
  const r = ((bk >> 8) & 15) * 16 + 8, g = ((bk >> 4) & 15) * 16 + 8, b = (bk & 15) * 16 + 8;
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
  if (cov > 0.30 && mx - mn > 60) return { key: [r, g, b], cov };
  return null;
}

export function chromaKey(d, w, h, key, tol) {
  const lo = tol * 0.45, hi = tol * 1.05;
  const [kr, kg, kb] = key;
  const green = kg > kr && kg > kb, blue = kb > kr && kb > kg, red = kr > kg && kr > kb;
  for (let i = 0; i < d.length; i += 4) {
    const dr = d[i] - kr, dg = d[i + 1] - kg, db = d[i + 2] - kb;
    const dist = Math.sqrt(dr * dr + dg * dg + db * db);
    let a = (dist - lo) / Math.max(1e-6, hi - lo);
    a = a < 0 ? 0 : a > 1 ? 1 : a;
    if (green) d[i + 1] = Math.min(d[i + 1], Math.max(d[i], d[i + 2]));
    else if (blue) d[i + 2] = Math.min(d[i + 2], Math.max(d[i], d[i + 1]));
    else if (red) d[i] = Math.min(d[i], Math.max(d[i + 1], d[i + 2]));
    d[i + 3] = Math.round(a * 255);
  }
}

// ---------------- estágio 2: grade ----------------
function edgeSignal(d, w, h) {
  const dx = new Float64Array(w - 1), dy = new Float64Array(h - 1);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w - 1; x++) {
      const i = (y * w + x) * 4, j = i + 4;
      const a0 = d[i + 3] / 255, a1 = d[j + 3] / 255;
      let s = 0;
      for (let c = 0; c < 3; c++) {
        const v0 = d[i + c] * a0 + 255 * (1 - a0), v1 = d[j + c] * a1 + 255 * (1 - a1);
        s += Math.abs(v1 - v0);
      }
      dx[x] += s / h;
    }
  }
  for (let x = 0; x < w; x++) {
    for (let y = 0; y < h - 1; y++) {
      const i = (y * w + x) * 4, j = i + w * 4;
      const a0 = d[i + 3] / 255, a1 = d[j + 3] / 255;
      let s = 0;
      for (let c = 0; c < 3; c++) {
        const v0 = d[i + c] * a0 + 255 * (1 - a0), v1 = d[j + c] * a1 + 255 * (1 - a1);
        s += Math.abs(v1 - v0);
      }
      dy[y] += s / w;
    }
  }
  return [dx, dy];
}

function contentMask(sig, pitch) {
  const w = Math.max(3, Math.round(pitch));
  const n = sig.length;
  const c = new Float64Array(n + 1);
  for (let i = 0; i < n; i++) c[i + 1] = c[i] + sig[i];
  const sm = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const a = Math.max(0, i - (w >> 1)), b = Math.min(n, i + w - (w >> 1));
    sm[i] = (c[b] - c[a]) / Math.max(1, b - a);
  }
  let med = 0, nz = 0;
  const vals = [];
  for (let i = 0; i < n; i++) if (sig[i] > 0) vals.push(sig[i]);
  vals.sort((a, b) => a - b);
  med = vals.length ? vals[vals.length >> 1] : 0;
  const thr = Math.max(1e-6, 0.25 * med);
  const mask = new Uint8Array(n);
  for (let i = 0; i < n; i++) mask[i] = sm[i] > thr ? 1 : 0;
  return mask;
}

function boundaryPeaks(sig) {
  const n = sig.length;
  const cm = contentMask(sig, 7);
  let sum = 0, cnt = 0;
  const vals = [];
  for (let i = 0; i < n; i++) if (cm[i]) { sum += sig[i]; cnt++; vals.push(sig[i]); }
  if (cnt < 16) return [];
  vals.sort((a, b) => a - b);
  const thr = Math.max((sum / cnt) * 2.0, vals[Math.floor(vals.length * 0.90)]);
  const peaks = [];
  let i = 0;
  while (i < n) {
    if (sig[i] > thr && cm[i]) {
      let j = i;
      while (j + 1 < n && sig[j + 1] > thr && (j + 1 - i) <= 4) j++;
      let bi = i;
      for (let k = i; k <= j; k++) if (sig[k] > sig[bi]) bi = k;
      peaks.push(bi);
      i = j + 1;
    } else i++;
  }
  return peaks;
}

function circPhase(bounds, p) {
  const r = bounds.map((b) => ((b % p) + p) % p).sort((a, b) => a - b);
  let gi = 0, gv = -1;
  for (let i = 0; i < r.length; i++) {
    const nx = i + 1 < r.length ? r[i + 1] : r[0] + p;
    const g = nx - r[i];
    if (g > gv) { gv = g; gi = i; }
  }
  const cut = (r[gi] + gv / 2) % p;
  const nxt = r[(gi + 1) % r.length];
  return ((((nxt + p - cut) % p) + cut) % p);
}

function fitPitch(bounds, p0) {
  let o = bounds[0], p = p0;
  for (let it = 0; it < 5; it++) {
    const k = bounds.map((b) => Math.round((b - o) / p));
    const dbs = [], dks = [];
    for (let i = 1; i < bounds.length; i++) {
      if (k[i] > k[i - 1]) { dbs.push(bounds[i] - bounds[i - 1]); dks.push(k[i] - k[i - 1]); }
    }
    if (dbs.length < 3) return null;
    const ratios = dbs.map((v, i) => v / dks[i]).sort((a, b) => a - b);
    const pn = ratios[ratios.length >> 1];
    const res = bounds.map((b, i) => b - k[i] * pn).sort((a, b) => a - b);
    const on = res[res.length >> 1];
    if (Math.abs(pn - p) < 1e-4 && Math.abs(on - o) < 1e-4) { p = pn; o = on; break; }
    p = pn; o = on;
  }
  // refino MQ nos inliers
  for (let it = 0; it < 2; it++) {
    const k = bounds.map((b) => Math.round((b - o) / p));
    const tol = Math.max(1.5, 0.08 * p);
    const K = [], B = [];
    bounds.forEach((b, i) => { if (Math.abs(b - (o + k[i] * p)) <= tol) { K.push(k[i]); B.push(b); } });
    if (K.length >= 6) {
      let sk = 0, sb = 0, skk = 0, skb = 0;
      for (let i = 0; i < K.length; i++) { sk += K[i]; sb += B[i]; skk += K[i] * K[i]; skb += K[i] * B[i]; }
      const den = K.length * skk - sk * sk;
      if (Math.abs(den) > 1e-9) {
        p = (K.length * skb - sk * sb) / den;
        o = (sb - p * sk) / K.length;
      }
    }
  }
  return p < 1.8 ? null : [p, o];
}

function refinePitchFine(bounds, p0) {
  let best = [0, p0, 0];
  for (let p = Math.max(2, p0 - 0.8); p <= p0 + 0.8; p += 0.02) {
    const o = circPhase(bounds, p);
    let inl = 0;
    for (const b of bounds) {
      let r = ((b - o + p / 2) % p + p) % p - p / 2;
      if (Math.abs(r) <= 1.0) inl++;
    }
    const cov = inl / bounds.length;
    if (cov > best[0]) best = [cov, p, o];
  }
  return best;
}

function ransacPitch(bounds, lo = 3, hi = 64, tol = 1.2) {
  const nb = bounds.length;
  if (nb < 8 || nb > 44) return null;
  let best = [0, 0, 0];
  for (let i = 0; i < nb; i++) {
    for (let j = i + 1; j < nb; j++) {
      const d = bounds[j] - bounds[i];
      for (let m = 1; m <= 8; m++) {
        const p = d / m;
        if (p < lo || p > hi) continue;
        const tolp = Math.max(0.6, Math.min(tol, 0.15 * p));
        const o = circPhase(bounds, p);
        let inl = 0;
        for (const b of bounds) {
          const r = ((b - o + p / 2) % p + p) % p - p / 2;
          if (Math.abs(r) <= tolp) inl++;
        }
        if (inl > best[0] || (inl === best[0] && inl > 0 && p > best[1])) best = [inl, p, o];
      }
    }
  }
  if (best[0] < 6) return null;
  let [inl, p, o] = best;
  const tolp = Math.max(0.6, Math.min(tol, 0.15 * p));
  const mask = bounds.map((b) => {
    const r = ((b - o + p / 2) % p + p) % p - p / 2;
    return Math.abs(r) <= tolp;
  });
  const inb = bounds.filter((_, i) => mask[i]);
  if (inb.length >= 6) {
    const fit = fitPitch(inb, p);
    if (fit) [p, o] = fit;
  }
  const rf = refinePitchFine(inb.length >= 6 ? inb : bounds, p);
  return [rf[1], rf[2], inl / nb];
}

function detectPitchPhase(sig) {
  const bounds = boundaryPeaks(sig);
  const res = ransacPitch(bounds);
  return res || [1, 0, 0];
}

export function detectGrid(d, w, h) {
  const [dx, dy] = edgeSignal(d, w, h);
  let [px, ox, fx] = detectPitchPhase(dx);
  let [py, oy, fy] = detectPitchPhase(dy);
  if (Math.max(fx, fy) >= 0.5) {
    const ref = fx >= fy ? px : py;
    const lo2 = ref * 0.94, hi2 = ref * 1.06;
    if (fx < fy || Math.abs(px - py) > 0.06 * Math.max(px, py)) {
      const b = boundaryPeaks(dx);
      const r = ransacPitch(b, lo2, hi2);
      if (r && r[2] >= 0.4) [px, ox, fx] = r;
    }
    if (fy < fx || Math.abs(px - py) > 0.06 * Math.max(px, py)) {
      const b = boundaryPeaks(dy);
      const r = ransacPitch(b, lo2, hi2);
      if (r && r[2] >= 0.4) [py, oy, fy] = r;
    }
  }
  const conf = Math.min(fx, fy);
  if (conf < 0.5 || px < 1.8 || py < 1.8)
    return { px: 1, py: 1, ox: 0, oy: 0, conf: 0, native: true };
  return { px, py, ox: ((ox % px) + px) % px, oy: ((oy % py) + py) % py, conf, native: false };
}

// ---------------- estágio 3: reamostragem nativa ----------------
export function resampleNative(d, w, h, g) {
  const px = g.px, py = g.py;
  let ox = g.ox + 0.5, oy = g.oy + 0.5;
  const nw = Math.max(1, Math.floor((w - ox) / px));
  const nh = Math.max(1, Math.floor((h - oy) / py));
  const out = new Uint8ClampedArray(nw * nh * 4);
  for (let j = 0; j < nh; j++) {
    let y0 = Math.round(oy + j * py), y1 = Math.round(oy + (j + 1) * py);
    y0 = Math.max(0, Math.min(h, y0)); y1 = Math.max(y0 + 1, Math.min(h, y1));
    if (y0 >= h) continue;
    for (let i = 0; i < nw; i++) {
      let x0 = Math.round(ox + i * px), x1 = Math.round(ox + (i + 1) * px);
      x0 = Math.max(0, Math.min(w, x0)); x1 = Math.max(x0 + 1, Math.min(w, x1));
      if (x0 >= w) continue;
      let na = 0, tot = 0;
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { tot++; if (d[(y * w + x) * 4 + 3] > 127) na++; }
      if (na / tot < 0.45) continue;
      const my0 = y0 + Math.floor(0.22 * (y1 - y0)), my1 = Math.max(my0 + 1, y1 - Math.floor(0.22 * (y1 - y0)));
      const mx0 = x0 + Math.floor(0.22 * (x1 - x0)), mx1 = Math.max(mx0 + 1, x1 - Math.floor(0.22 * (x1 - x0)));
      const rs = [], gs = [], bs = [];
      for (let y = my0; y < my1; y++) for (let x = mx0; x < mx1; x++) {
        const i4 = (y * w + x) * 4;
        if (d[i4 + 3] > 127) { rs.push(d[i4]); gs.push(d[i4 + 1]); bs.push(d[i4 + 2]); }
      }
      if (rs.length < 4) {
        for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
          const i4 = (y * w + x) * 4;
          if (d[i4 + 3] > 127) { rs.push(d[i4]); gs.push(d[i4 + 1]); bs.push(d[i4 + 2]); }
        }
      }
      if (!rs.length) continue;
      rs.sort((a, b) => a - b); gs.sort((a, b) => a - b); bs.sort((a, b) => a - b);
      const o4 = (j * nw + i) * 4;
      out[o4] = rs[rs.length >> 1]; out[o4 + 1] = gs[gs.length >> 1];
      out[o4 + 2] = bs[bs.length >> 1]; out[o4 + 3] = 255;
    }
  }
  return { data: out, w: nw, h: nh };
}

// ---------------- refinamentos de alinhamento ----------------
export function cellPurity(d, w, h, g, sample = 300) {
  const nw = Math.max(1, Math.floor((w - g.ox) / g.px)), nh = Math.max(1, Math.floor((h - g.oy) / g.py));
  let tot = 0, n = 0;
  for (let s = 0; s < sample; s++) {
    const j = (s * 7919 + 13) % nh, i = (s * 104729 + 7) % nw;
    let y0 = Math.round(g.oy + j * g.py), y1 = Math.round(g.oy + (j + 1) * g.py);
    let x0 = Math.round(g.ox + i * g.px), x1 = Math.round(g.ox + (i + 1) * g.px);
    y0 = Math.max(0, Math.min(h, y0)); y1 = Math.max(y0 + 1, Math.min(h, y1));
    x0 = Math.max(0, Math.min(w, x0)); x1 = Math.max(x0 + 1, Math.min(w, x1));
    if (y0 >= h || x0 >= w) continue;
    let na = 0, tot2 = 0;
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { tot2++; if (d[(y * w + x) * 4 + 3] > 127) na++; }
    if (na / tot2 <= 0.5) continue;
    const cell = [];
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) cell.push([d[(y * w + x) * 4], d[(y * w + x) * 4 + 1], d[(y * w + x) * 4 + 2]]);
    const med = [0, 1, 2].map((c) => { const v = cell.map((p) => p[c]).sort((a, b) => a - b); return v[v.length >> 1]; });
    let ok = 0;
    for (const p of cell) if (Math.hypot(p[0] - med[0], p[1] - med[1], p[2] - med[2]) <= 48) ok++;
    tot += ok / cell.length; n++;
  }
  return n ? tot / n : 0;
}

export function refineAlignment(d, w, h, g) {
  if (g.native) return g;
  let best = [cellPurity(d, w, h, g), g.ox, g.oy];
  for (const dx of [-1, -0.5, 0, 0.5, 1]) for (const dy of [-1, -0.5, 0, 0.5, 1]) {
    if (!dx && !dy) continue;
    const sc = cellPurity(d, w, h, { ...g, ox: g.ox + dx, oy: g.oy + dy });
    if (sc > best[0] + 1e-4) best = [sc, g.ox + dx, g.oy + dy];
  }
  return { ...g, ox: best[1], oy: best[2], purity: best[0] };
}

function compactness(nat) {
  const { data, w, h } = nat;
  const map = new Map();
  const cols = [];
  for (let i = 0; i < w * h; i++) if (data[i * 4 + 3] > 0) {
    const c = (data[i * 4] >> 3) * 4096 + (data[i * 4 + 1] >> 3) * 64 + (data[i * 4 + 2] >> 3);
    map.set(c, (map.get(c) || 0) + 1);
    cols.push([data[i * 4], data[i * 4 + 1], data[i * 4 + 2]]);
  }
  if (cols.length < 60) return 1e9;
  const top = [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10)
    .map(([k]) => [((k >> 12) & 31) * 8 + 4, ((k >> 6) & 63) * 8 + 4, (k & 63) * 8 + 4]);
  let tot = 0;
  for (const c of cols) {
    let bm = 1e9;
    for (const t of top) { const dd = (c[0] - t[0]) ** 2 + (c[1] - t[1]) ** 2 + (c[2] - t[2]) ** 2; if (dd < bm) bm = dd; }
    tot += Math.sqrt(bm);
  }
  return tot / cols.length;
}

export function refineGridCompact(d, w, h, g, onStep) {
  if (g.native) return g;
  let best = [compactness(resampleNative(d, w, h, g)), g.px, g.ox, g.py, g.oy];
  let n = 0;
  for (let px = g.px - 0.06; px <= g.px + 0.06; px += 0.02)
    for (let ox = g.ox - 2; ox <= g.ox + 2; ox += 0.5) {
      const c = compactness(resampleNative(d, w, h, { ...g, px, ox }));
      if (c < best[0] - 1e-6) best = [c, px, ox, best[3], best[4]];
      if (++n % 20 === 0 && onStep) onStep();
    }
  const g2 = { ...g, px: best[1], ox: best[2] };
  for (let py = g2.py - 0.06; py <= g2.py + 0.06; py += 0.02)
    for (let oy = g2.oy - 2; oy <= g2.oy + 2; oy += 0.5) {
      const c = compactness(resampleNative(d, w, h, { ...g2, py, oy }));
      if (c < best[0] - 1e-6) best = [c, best[1], best[2], py, oy];
      if (++n % 20 === 0 && onStep) onStep();
    }
  return { ...g2, py: best[3], oy: best[4], compactness: best[0] };
}

// ---------------- estágio 4: paleta ----------------
export function exactPalette(natives, maxColors, radius = 10) {
  const cnt = new Map();
  for (const nat of natives) {
    const { data, w, h } = nat;
    for (let i = 0; i < w * h; i++) if (data[i * 4 + 3] > 0) {
      const k = data[i * 4] * 65536 + data[i * 4 + 1] * 256 + data[i * 4 + 2];
      cnt.set(k, (cnt.get(k) || 0) + 1);
    }
  }
  const entries = [...cnt.entries()].filter(([, c]) => c >= 3).sort((a, b) => b[1] - a[1]);
  const centers = [], members = [];
  for (const [k] of entries) {
    const c = [(k >> 16) & 255, (k >> 8) & 255, k & 255];
    let hit = -1;
    for (let i = 0; i < centers.length; i++) {
      const ct = centers[i];
      if (Math.hypot(ct[0] - c[0], ct[1] - c[1], ct[2] - c[2]) <= radius) { hit = i; break; }
    }
    if (hit >= 0) { members[hit].push(c); centers[hit] = members[hit].reduce((a, p) => [a[0] + p[0] / members[hit].length, a[1] + p[1] / members[hit].length, a[2] + p[2] / members[hit].length], [0, 0, 0]); }
    else { centers.push([...c]); members.push([c]); }
  }
  if (centers.length && centers.length <= maxColors)
    return centers.map((c) => c.map((v) => Math.round(Math.min(255, Math.max(0, v)))));
  return null;
}

export function kmeansOklab(natives, k, iters = 20) {
  const pts = [];
  for (const nat of natives) {
    const { data, w, h } = nat;
    for (let i = 0; i < w * h; i += 1) if (data[i * 4 + 3] > 0)
      pts.push(rgbToOklab(data[i * 4], data[i * 4 + 1], data[i * 4 + 2]));
  }
  const cap = 60000;
  const sample = pts.length > cap ? pts.filter((_, i) => i % Math.ceil(pts.length / cap) === 0) : pts;
  let seed = 12345;
  const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const cen = [sample[Math.floor(rnd() * sample.length)].slice()];
  while (cen.length < k) {
    let bi = 0, bd = -1;
    for (let t = 0; t < 200; t++) {
      const p = sample[Math.floor(rnd() * sample.length)];
      let dmin = 1e9;
      for (const c of cen) { const dd = (p[0] - c[0]) ** 2 + (p[1] - c[1]) ** 2 + (p[2] - c[2]) ** 2; if (dd < dmin) dmin = dd; }
      if (dmin > bd) { bd = dmin; bi = sample.indexOf(p); }
    }
    cen.push(sample[bi].slice());
  }
  for (let it = 0; it < iters; it++) {
    const sums = cen.map(() => [0, 0, 0, 0]);
    for (const p of sample) {
      let bi = 0, bd = 1e9;
      for (let c = 0; c < cen.length; c++) {
        const dd = (p[0] - cen[c][0]) ** 2 + (p[1] - cen[c][1]) ** 2 + (p[2] - cen[c][2]) ** 2;
        if (dd < bd) { bd = dd; bi = c; }
      }
      const s = sums[bi]; s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; s[3]++;
    }
    let move = 0;
    for (let c = 0; c < cen.length; c++) if (sums[c][3]) {
      const nc = [sums[c][0] / sums[c][3], sums[c][1] / sums[c][3], sums[c][2] / sums[c][3]];
      move = Math.max(move, Math.hypot(nc[0] - cen[c][0], nc[1] - cen[c][1], nc[2] - cen[c][2]));
      cen[c] = nc;
    }
    if (move < 1e-5) break;
  }
  return cen.map((c) => oklabToRgb(c[0], c[1], c[2]));
}

export function snapToPalette(nat, palette) {
  const lab = palette.map((c) => rgbToOklab(c[0], c[1], c[2]));
  const { data, w, h } = nat;
  const out = new Uint8ClampedArray(data);
  let err = 0, n = 0;
  for (let i = 0; i < w * h; i++) {
    if (out[i * 4 + 3] === 0) continue;
    const p = rgbToOklab(out[i * 4], out[i * 4 + 1], out[i * 4 + 2]);
    let bi = 0, bd = 1e9;
    for (let c = 0; c < lab.length; c++) {
      const dd = (p[0] - lab[c][0]) ** 2 + (p[1] - lab[c][1]) ** 2 + (p[2] - lab[c][2]) ** 2;
      if (dd < bd) { bd = dd; bi = c; }
    }
    err += Math.sqrt(bd); n++;
    out[i * 4] = palette[bi][0]; out[i * 4 + 1] = palette[bi][1]; out[i * 4 + 2] = palette[bi][2];
  }
  return { data: out, w, h, err: n ? err / n : 0 };
}

// ---------------- estágio 5: limpeza de órfãos ----------------
export function removeOrphans(nat, passes = 1) {
  let { data, w, h } = nat;
  let changed = 0;
  for (let p = 0; p < passes; p++) {
    const out = new Uint8ClampedArray(data);
    let nch = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      if (!data[i + 3]) continue;
      const c = [data[i], data[i + 1], data[i + 2]];
      const n4 = [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]];
      let same = false;
      for (const [nx, ny] of n4) {
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        const j = (ny * w + nx) * 4;
        if (data[j + 3] && data[j] === c[0] && data[j + 1] === c[1] && data[j + 2] === c[2]) { same = true; break; }
      }
      if (same) continue;
      const cnt = new Map();
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        if (!dx && !dy) continue;
        const nx = x + dx, ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        const j = (ny * w + nx) * 4;
        if (!data[j + 3]) continue;
        const k = data[j] * 65536 + data[j + 1] * 256 + data[j + 2];
        cnt.set(k, (cnt.get(k) || 0) + 1);
      }
      let bk = 0, bv = 0;
      for (const [k, v] of cnt) if (v > bv) { bv = v; bk = k; }
      if (bv >= 4) {
        out[i] = (bk >> 16) & 255; out[i + 1] = (bk >> 8) & 255; out[i + 2] = bk & 255;
        nch++;
      }
    }
    data = out; changed += nch;
    if (!nch) break;
  }
  return { data, w, h, changed };
}
