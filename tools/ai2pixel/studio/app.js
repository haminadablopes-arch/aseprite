/* ai2pixel Studio — interface (metodologia Grade-Nativa no navegador) */
import * as P from './pipeline.js';
import * as E from './encoders.js';

const $ = (s) => document.querySelector(s);
const state = { files: [], result: null, playing: false, frame: 0, zoom: 1, timer: null };

const yieldUi = () => new Promise((r) => setTimeout(r, 0));
function progress(p, msg) {
  $('#bar').style.width = `${Math.round(p * 100)}%`;
  if (msg) $('#status').textContent = msg;
}

async function readFiles(list) {
  const files = [...list].filter((f) => /image\/(png|jpeg|webp|gif|bmp)/.test(f.type) || /\.(png|jpe?g|webp|gif|bmp)$/i.test(f.name));
  files.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
  state.files = [];
  for (const f of files) {
    const bmp = await createImageBitmap(f);
    const cv = document.createElement('canvas');
    cv.width = bmp.width; cv.height = bmp.height;
    const cx = cv.getContext('2d');
    cx.drawImage(bmp, 0, 0);
    const id = cx.getImageData(0, 0, bmp.width, bmp.height);
    state.files.push({ name: f.name, img: id });
  }
  $('#filelist').textContent = state.files.map((f) => f.name).join(', ') || '—';
  if (state.files.length) { $('#controls').disabled = false; $('#run').disabled = false; }
}

function drawFinals() {
  const r = state.result;
  if (!r) return;
  const f = r.finals[state.frame];
  const cv = $('#after');
  cv.width = f.w * state.zoom; cv.height = f.h * state.zoom;
  const cx = cv.getContext('2d');
  cx.imageSmoothingEnabled = false;
  const tmp = document.createElement('canvas');
  tmp.width = f.w; tmp.height = f.h;
  tmp.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(f.data), f.w, f.h), 0, 0);
  cx.drawImage(tmp, 0, 0, cv.width, cv.height);
  const src = state.files[state.frame % state.files.length].img;
  const cv2 = $('#before');
  const scale = Math.max(1, Math.floor(state.zoom * f.w / src.width));
  cv2.width = src.width * scale; cv2.height = src.height * scale;
  const cx2 = cv2.getContext('2d');
  cx2.imageSmoothingEnabled = false;
  cx2.putImageData(src, 0, 0);
  const tmp2 = document.createElement('canvas');
  tmp2.width = src.width; tmp2.height = src.height;
  tmp2.getContext('2d').putImageData(src, 0, 0);
  cx2.clearRect(0, 0, cv2.width, cv2.height);
  cx2.drawImage(tmp2, 0, 0, cv2.width, cv2.height);
  $('#swatches').innerHTML = r.palette.map((c) =>
    `<span title="rgb(${c.join(',')})" style="background:rgb(${c.join(',')})"></span>`).join('');
}

function play() {
  stop();
  state.playing = true;
  const fps = parseFloat($('#fps').value) || 12;
  state.timer = setInterval(() => {
    state.frame = (state.frame + 1) % state.result.finals.length;
    $('#framelab').textContent = `${state.frame + 1}/${state.result.finals.length}`;
    drawFinals();
  }, 1000 / fps);
}
function stop() { state.playing = false; if (state.timer) clearInterval(state.timer); state.timer = null; }

async function run() {
  if (!state.files.length) return;
  stop();
  $('#run').disabled = true;
  const maxColors = parseInt($('#colors').value, 10);
  const chromaMode = $('#chroma').value;
  const tol = parseFloat($('#tol').value);
  const cleanup = parseInt($('#cleanup').value, 10);
  try {
    const sources = state.files.map((f) => new Uint8ClampedArray(f.img.data));
    const w = state.files[0].img.width, h = state.files[0].img.height;
    let keyInfo = null;
    if (chromaMode !== 'off') {
      let key = null, cov = 0;
      if (chromaMode === 'auto') { const d0 = P.detectChromaKey(sources[0], w, h); if (d0) { key = d0.key; cov = d0.cov; } }
      else key = [0, 1, 2].map((i) => parseInt(chromaMode.substr(1 + i * 2, 2), 16));
      if (key) { keyInfo = { key, cov }; sources.forEach((s) => P.chromaKey(s, w, h, key, tol)); }
    }
    progress(0.1, 'Detectando a grade de pseudo-pixels…');
    await yieldUi();
    let g = P.detectGrid(sources[0], w, h);
    g = P.refineAlignment(sources[0], w, h, g);
    progress(0.25, 'Refinando alinhamento (compacidade da paleta)…');
    await yieldUi();
    g = P.refineGridCompact(sources[0], w, h, g, () => { });
    progress(0.4, 'Reamostrando na resolução nativa…');
    await yieldUi();
    const natives = [];
    for (let i = 0; i < sources.length; i++) {
      natives.push(P.resampleNative(sources[i], w, h, g));
      if (i % 4 === 0) { progress(0.4 + 0.2 * i / sources.length, `Reamostrando frame ${i + 1}/${sources.length}…`); await yieldUi(); }
    }
    progress(0.65, 'Construindo paleta global (OKLab)…');
    await yieldUi();
    let palette = P.exactPalette(natives, maxColors);
    const exact = !!palette;
    if (!palette) palette = P.kmeansOklab(natives, maxColors);
    progress(0.75, 'Encaixando cores e limpando órfãos…');
    await yieldUi();
    const finals = [], errs = [], orph = [];
    for (let i = 0; i < natives.length; i++) {
      const sn = P.snapToPalette(natives[i], palette);
      errs.push(sn.err);
      const cl = cleanup > 0 ? P.removeOrphans(sn, cleanup) : { ...sn, changed: 0 };
      orph.push(cl.changed);
      finals.push(cl);
      if (i % 4 === 0) { progress(0.75 + 0.2 * i / natives.length, `Frame ${i + 1}/${natives.length}…`); await yieldUi(); }
    }
    state.result = { finals, palette, exact, grid: g, keyInfo, errs, orph, nw: finals[0].w, nh: finals[0].h };
    state.frame = 0;
    state.zoom = Math.max(1, Math.min(16, Math.round(640 / Math.max(state.result.nw, state.result.nh))));
    $('#zoom').value = state.zoom;
    renderReport();
    drawFinals();
    $('#exports').disabled = false;
    $('#stage').style.display = 'flex';
    progress(1, 'Concluído.');
  } catch (e) {
    $('#status').textContent = 'Erro: ' + e.message;
    console.error(e);
  }
  $('#run').disabled = false;
}

function renderReport() {
  const r = state.result;
  const rows = [
    ['Grade detectada (pitch x/y)', r.grid.native ? 'imagem já nativa' : `${r.grid.px.toFixed(3)} / ${r.grid.py.toFixed(3)} px`],
    ['Fase (off x/y)', `${r.grid.ox.toFixed(2)} / ${r.grid.oy.toFixed(2)}`],
    ['Confiança da grade', r.grid.conf.toFixed(2)],
    ['Pureza de célula', (r.grid.purity ?? 0).toFixed(3)],
    ['Chroma-key', r.keyInfo ? `rgb(${r.keyInfo.key.join(',')}) cob. ${(r.keyInfo.cov * 100).toFixed(0)}%` : 'não detectado/desligado'],
    ['Resolução nativa', `${r.nw} × ${r.nh} px (1:1)`],
    ['Paleta', `${r.palette.length} cores — ${r.exact ? 'EXATA (identidade preservada)' : 'k-means OKLab'}`],
    ['Erro médio de quantização (ΔE OKLab)', (r.errs.reduce((a, b) => a + b, 0) / r.errs.length).toFixed(4)],
    ['Pixels órfãos removidos por frame', r.orph.join(', ')],
  ];
  $('#report').innerHTML = rows.map(([k, v]) => `<tr><td>${k}</td><td>${v}</td></tr>`).join('');
}

async function exportAll(kind) {
  const r = state.result;
  if (!r) return;
  if (kind === 'zip') {
    const entries = [];
    for (let i = 0; i < r.finals.length; i++) {
      const f = r.finals[i];
      const cv = document.createElement('canvas'); cv.width = f.w; cv.height = f.h;
      cv.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(f.data), f.w, f.h), 0, 0);
      const blob = await new Promise((res) => cv.toBlob(res, 'image/png'));
      entries.push({ name: `frame_${String(i).padStart(2, '0')}.png`, bytes: new Uint8Array(await blob.arrayBuffer()) });
    }
    E.download(E.encodeZip(entries), 'ai2pixel_frames_nativos.zip', 'application/zip');
  } else if (kind === 'sheet') {
    const f0 = r.finals[0];
    const cv = document.createElement('canvas');
    cv.width = f0.w * r.finals.length; cv.height = f0.h;
    const cx = cv.getContext('2d');
    for (let i = 0; i < r.finals.length; i++) {
      const t = document.createElement('canvas'); t.width = f0.w; t.height = f0.h;
      t.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(r.finals[i].data), f0.w, f0.h), 0, 0);
      cx.drawImage(t, i * f0.w, 0);
    }
    const blob = await new Promise((res) => cv.toBlob(res, 'image/png'));
    E.download(blob, 'sprite_sheet.png', 'image/png');
  } else if (kind === 'gif') {
    const idx = r.finals.map((f) => {
      const a = new Int32Array(f.w * f.h);
      const map = new Map(r.palette.map((c, i) => [c[0] * 65536 + c[1] * 256 + c[2], i]));
      for (let i = 0; i < a.length; i++) {
        if (!f.data[i * 4 + 3]) { a[i] = -1; continue; }
        a[i] = map.get(f.data[i * 4] * 65536 + f.data[i * 4 + 1] * 256 + f.data[i * 4 + 2]);
      }
      return a;
    });
    const fps = parseFloat($('#fps').value) || 12;
    E.download(E.encodeGif(idx, r.palette, r.nw, r.nh, Math.max(1, Math.round(100 / fps))), 'animacao.gif', 'image/gif');
  } else if (kind === 'gpl') E.download(new TextEncoder().encode(E.gplText('ai2pixel', r.palette)), 'palette.gpl', 'text/plain');
  else if (kind === 'act') E.download(E.actBytes(r.palette), 'palette.act', 'application/octet-stream');
  else if (kind === 'json') E.download(new TextEncoder().encode(JSON.stringify({ grid: r.grid, palette: r.palette, exact: r.exact, native: [r.nw, r.nh], errs: r.errs, orphans: r.orph }, null, 2)), 'report.json', 'application/json');
}

// ---------------- wiring ----------------
const drop = $('#drop');
['dragover', 'dragenter'].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', (e) => readFiles(e.dataTransfer.files));
drop.addEventListener('click', () => $('#pick').click());
$('#pick').addEventListener('change', (e) => readFiles(e.target.files));
$('#run').addEventListener('click', run);
$('#play').addEventListener('click', () => (state.playing ? stop() : play()));
$('#prev').addEventListener('click', () => { stop(); state.frame = (state.frame - 1 + state.result.finals.length) % state.result.finals.length; $('#framelab').textContent = `${state.frame + 1}/${state.result.finals.length}`; drawFinals(); });
$('#next').addEventListener('click', () => { stop(); state.frame = (state.frame + 1) % state.result.finals.length; $('#framelab').textContent = `${state.frame + 1}/${state.result.finals.length}`; drawFinals(); });
$('#zoom').addEventListener('input', (e) => { state.zoom = parseInt(e.target.value, 10); drawFinals(); });
['zip', 'sheet', 'gif', 'gpl', 'act', 'json'].forEach((k) => $(`#ex-${k}`).addEventListener('click', () => exportAll(k)));
