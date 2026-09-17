#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ai2pixel — Metodologia "Grade-Nativa" (Native-Grid Fidelity Pipeline)
=====================================================================

Converte imagens "pseudo pixel art" geradas por IA em pixel art autêntica,
preservando a identidade visual e a composição original na resolução nativa
de cada pixel (1 bloco pseudo-pixel detectado = 1 pixel real).

Estágios:
  0. Diagnóstico         -> contagem de cores, detecção de chroma-key
  1. Chroma-key + despill-> remove fundo verde/azul sólido com borda suave
  2. Detecção de grade   -> pitch (passo, possivelmente fracionário) + fase,
                            por energia de pente sobre o gradiente (autocorr.)
  3. Reamostragem nativa -> cor mediana por célula (robusta a ruído/off-grid)
  4. Paleta global OKLab -> cores exatas se possível (fidelidade absoluta),
                            senão k-means perceptual; paleta ÚNICA compartilhada
                            entre todos os frames => estabilidade temporal
  5. Snap + limpeza       -> nearest palette em OKLab, remoção de órfãos,
                            dithering opcional (Bayer 4x4 / Floyd-Steinberg)
  6. Exportação nativa    -> PNG 1:1, folha de sprites, GIF, paleta .gpl/.act,
                            preview nearest-neighbor e relatório de métricas

Referências da metodologia (ver README.md):
  * Yeh, S.-Y. "PixelOE: Detail-Oriented Pixelization based on Contrast-Aware
    Outline Expansion" (2024)
  * Gerstner et al. "Pixelated Image Abstraction", NPAR 2012 / Computers &
    Graphics 37(5), 2013
  * Seo et al. "Structure-Aware Pixel Art Scaling via Block Size Detection",
    Applied Sciences 16(5):2314, 2026
  * jenissimo/unfake.js — detecção de grade por votação de blocos
  * Kopf & Lischinski, "Depixelizing Pixel Art" (problema inverso)
  * Floyd & Steinberg (1976); Bayer (1973); Ottosson, "OKLab" (2020)

Uso:
  python3 ai2pixel.py -i frames/*.png -o out/ [--max-colors 32] [--pitch auto]
                      [--chroma auto|off|#RRGGBB] [--tol 90] [--cleanup 1]
                      [--dither off|bayer|fs] [--preview-scale 8] [--fps 12]
"""

import argparse
import json
import math
import os
import struct
import sys
import zlib
from collections import Counter

import numpy as np
from PIL import Image

# --------------------------------------------------------------------------
# Cor: sRGB <-> OKLab (Björn Ottosson, 2020) — espaço perceptual p/ paletas
# --------------------------------------------------------------------------

def srgb_to_linear(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * (c ** (1 / 2.4)) - 0.055) * 255.0


def rgb_to_oklab(rgb):
    """rgb: (...,3) float 0..255 -> oklab (...,3)"""
    c = srgb_to_linear(np.asarray(rgb, dtype=np.float64))
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = np.cbrt(l), np.cbrt(m), np.cbrt(s)
    return np.stack([
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    ], axis=-1)


def oklab_to_rgb(lab):
    lab = np.asarray(lab, dtype=np.float64)
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    r = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return np.clip(np.round(linear_to_srgb(np.stack([r, g, bb], axis=-1))), 0, 255)


# --------------------------------------------------------------------------
# Estágio 1 — Chroma-key com despill
# --------------------------------------------------------------------------

def detect_chroma_key(rgba):
    """Amostra a moldura externa; se houver cor sólida saturada dominante,
    retorna (rgb, cobertura). Senão None."""
    h, w = rgba.shape[:2]
    t = max(1, int(0.02 * min(h, w)))
    sel_rgb = np.concatenate([
        rgba[:t, :, :3].reshape(-1, 3), rgba[-t:, :, :3].reshape(-1, 3),
        rgba[:, :t, :3].reshape(-1, 3), rgba[:, -t:, :3].reshape(-1, 3)])
    if rgba.shape[2] > 3:
        sel_a = np.concatenate([
            rgba[:t, :, 3].reshape(-1), rgba[-t:, :, 3].reshape(-1),
            rgba[:, :t, 3].reshape(-1), rgba[:, -t:, 3].reshape(-1)])
        sel_rgb = sel_rgb[sel_a > 200]
    border = sel_rgb
    if len(border) == 0:
        return None
    quant = (border // 24) * 24 + 12
    cnt = Counter(map(tuple, quant.tolist()))
    (r, g, b), cov = cnt.most_common(1)[0]
    cov = cov / len(border)
    mx, mn = max(r, g, b), min(r, g, b)
    if cov > 0.30 and (mx - mn) > 60:
        return (float(r), float(g), float(b)), cov
    return None


def chroma_key(rgba, key, tol):
    """Alpha com borda suave + despill (remove franja verde/ciano)."""
    rgb = rgba[..., :3].astype(np.float64)
    d = np.sqrt(((rgb - np.array(key)) ** 2).sum(-1))
    lo, hi = tol * 0.45, tol * 1.05
    alpha = np.clip((d - lo) / max(1e-6, hi - lo), 0, 1)
    # despill: limita o canal dominante da chave pelos outros dois
    kr, kg, kb = key
    out = rgb.copy()
    if kg > kr and kg > kb:          # fundo verde
        out[..., 1] = np.minimum(out[..., 1], np.maximum(out[..., 0], out[..., 2]))
    elif kb > kr and kb > kg:        # fundo azul
        out[..., 2] = np.minimum(out[..., 2], np.maximum(out[..., 0], out[..., 1]))
    elif kr > kg and kr > kb:        # fundo magenta/vermelho
        out[..., 0] = np.minimum(out[..., 0], np.maximum(out[..., 1], out[..., 2]))
    a = (alpha * 255).astype(np.uint8)
    return np.dstack([out.astype(np.uint8), a])


# --------------------------------------------------------------------------
# Estágio 2 — Detecção da grade (pitch fracionário + fase)
# --------------------------------------------------------------------------

def _edge_signal(rgba):
    """Energia de borda por coluna e por linha (soma de gradientes)."""
    px = rgba[..., :3].astype(np.float64)
    a = rgba[..., 3:4].astype(np.float64) / 255.0
    px = px * a + 255.0 * (1 - a)          # fundo branco p/ gradiente estável
    dx = np.abs(np.diff(px, axis=1)).sum(-1).mean(0)   # por coluna
    dy = np.abs(np.diff(px, axis=0)).sum(-1).mean(1)   # por linha
    return dx, dy


def _boundary_peaks(sig, k=2.0, pct=90):
    """Colunas/linhas de fronteira de bloco: picos locais acima de limiar
    relativo ao conteúdo (fundos vazios são excluídos antes)."""
    cm = _content_mask(sig, 7)
    sig_c = sig[cm] if cm.any() else sig
    if len(sig_c) < 16:
        return np.array([], dtype=int)
    thr = max(sig_c.mean() * k, np.percentile(sig_c, pct))
    cand = np.where((sig > thr) & cm)[0]
    if len(cand) == 0:
        return np.array([], dtype=int)
    groups = np.split(cand, np.where(np.diff(cand) > 2)[0] + 1)
    return np.array([g[int(np.argmax(sig[g]))] for g in groups], dtype=int)


def _content_mask(sig, pitch):
    """Máscara de região com conteúdo (exclui fundo vazio/uniforme, onde não
    existem fronteiras e os dentes do pente não significam nada)."""
    w = max(3, int(round(pitch)))
    c = np.cumsum(np.concatenate([[0.0], sig]))
    sm = (c[w:] - c[:-w]) / w
    pad = np.concatenate([np.full(w // 2, sm[0] if len(sm) else 0.0), sm,
                          np.full(w - w // 2, sm[-1] if len(sm) else 0.0)])
    med = np.median(sig[sig > 0]) if (sig > 0).any() else 0.0
    return pad[:len(sig)] > max(1e-6, 0.25 * med)


def _cov_prec(bounds, n, pitch, phase, tol, sig=None):
    """Cobertura (fronteiras explicadas pelo pente) e precisão (dentes do
    pente, dentro da região de conteúdo, que caem em fronteiras)."""
    if len(bounds) == 0:
        return 0.0, 0.0
    d = np.mod(bounds - phase + pitch / 2, pitch) - pitch / 2
    cov = float((np.abs(d) <= tol).mean())
    comb = np.arange(phase, n - 1, pitch)
    if sig is not None:
        cm = _content_mask(sig, pitch)
        ci = np.clip(np.round(comb).astype(int), 0, n - 1)
        comb = comb[cm[ci]]
    if len(comb) < 4:
        return cov, 0.0
    i = np.searchsorted(bounds, comb)
    i = np.clip(i, 0, len(bounds) - 1)
    j = np.clip(i - 1, 0, len(bounds) - 1)
    dist = np.minimum(np.abs(bounds[i] - comb), np.abs(bounds[j] - comb))
    prec = float((dist <= tol).mean())
    return cov, prec


def _f1(bounds, n, pitch, phase, tol):
    cov, prec = _cov_prec(bounds, n, pitch, phase, tol)
    return 0.0 if cov + prec <= 0 else 2 * cov * prec / (cov + prec)


def _fit_pitch(bounds, n, p0):
    """Ajuste robusto b_k ~= o + k*p (mediana de inclinações, estilo
    Theil-Sen): imune a outliers de blur/JPEG e a gaps sem fronteira."""
    o = float(bounds[0])
    p = float(p0)
    for _ in range(5):
        k = np.round((bounds - o) / p)
        dk = np.diff(k)
        db = np.diff(bounds.astype(float))
        m = dk > 0
        if m.sum() < 3:
            return None
        p_new = float(np.median(db[m] / dk[m]))
        o_new = float(np.median(bounds - k * p_new))
        if abs(p_new - p) < 1e-4 and abs(o_new - o) < 1e-4:
            p, o = p_new, o_new
            break
        p, o = p_new, o_new
    # refino por mínimos quadrados apenas nos inliers
    for _ in range(2):
        k = np.round((bounds - o) / p)
        res = bounds - (o + k * p)
        inl = np.abs(res) <= max(1.5, 0.08 * p)
        if inl.sum() >= 6:
            A = np.vstack([k[inl], np.ones(int(inl.sum()))]).T
            sol, *_ = np.linalg.lstsq(A, bounds[inl].astype(float), rcond=None)
            p, o = float(sol[0]), float(sol[1])
    if p < 1.8:
        return None
    return p, o


def _circ_phase(bounds, pitch):
    r = np.mod(bounds, pitch)
    r = np.sort(r)
    # mediana circular
    gaps = np.diff(np.concatenate([r, [r[0] + pitch]]))
    i = int(np.argmax(gaps))
    cut = (r[i] + gaps[i] / 2) % pitch
    return float((r[i + 1 if i + 1 < len(r) else 0] + pitch - cut) % pitch + cut) % pitch


def _refine_pitch_fine(sig, bounds, p0, tol=1.0, span=0.8, step=0.02):
    """Varredura fina de pitch; para cada candidato a fase é a mediana
    circular dos resíduos, então a cobertura pico-a-pico identifica o
    pitch verdadeiro com precisão sub-centesimal."""
    best = (0.0, p0, 0.0)
    for p in np.arange(max(2.0, p0 - span), p0 + span + 1e-9, step):
        o = _circ_phase(bounds, p)
        d = np.mod(bounds - o + p / 2, p) - p / 2
        cov = float((np.abs(d) <= tol).mean())
        if cov > best[0]:
            best = (cov, float(p), o)
    return best[1], best[2], best[0]


def _ransac_pitch(bounds, lo=3.0, hi=64.0, tol=1.2):
    """Hipóteses de pitch a partir de pares de fronteiras (dist/m) com
    votação de inliers por fase circular — robusto a picos espúrios de
    ringing/JPEG e a gaps sem mudança de cor."""
    nb = len(bounds)
    if nb < 8:
        return None
    if nb > 44:                      # limita custo: picos mais fortes
        return None
    best = (0, 0.0, 0.0)
    for i in range(nb):
        for j in range(i + 1, nb):
            d = float(bounds[j] - bounds[i])
            for m in range(1, 9):
                p = d / m
                if not (lo <= p <= hi):
                    continue
                tolp = max(0.6, min(tol, 0.15 * p))
                o = _circ_phase(bounds, p)
                r = np.mod(bounds - o + p / 2, p) - p / 2
                inl = int((np.abs(r) <= tolp).sum())
                if inl > best[0] or (inl == best[0] and inl > 0 and p > best[1]):
                    best = (inl, float(p), float(o))
    if best[0] < 6:
        return None
    inl, p, o = best
    r = np.mod(bounds - o + p / 2, p) - p / 2
    mask = np.abs(r) <= tol
    fit = _fit_pitch(bounds[mask], len(bounds), p) if mask.sum() >= 6 else None
    if fit:
        p, o = fit
    p2, o2, _ = _refine_pitch_fine(None, bounds[mask] if mask.sum() >= 6 else bounds, p)
    return p2, o2, inl / nb


def _detect_pitch_phase(sig, lo=3.0, hi=64.0):
    bounds = _boundary_peaks(sig)
    res = _ransac_pitch(bounds, lo, hi)
    if res is None:
        return 1.0, 0.0, 0.0
    return res


def detect_grid(rgba):
    dx, dy = _edge_signal(rgba)
    px, ox, fx = _detect_pitch_phase(dx)
    py, oy, fy = _detect_pitch_phase(dy)
    # pseudo-pixels de IA são quadrados: usa o eixo mais confiável como
    # referência e reajusta o outro numa janela de ±6%
    if max(fx, fy) >= 0.5:
        ref = px if fx >= fy else py
        lo2, hi2 = ref * 0.94, ref * 1.06
        if fx < fy or abs(px - py) > 0.06 * max(px, py):
            px2, ox2, fx2 = _detect_pitch_phase(dx, lo2, hi2)
            if fx2 >= 0.4:
                px, ox, fx = px2, ox2, fx2
        if fy < fx or abs(px - py) > 0.06 * max(px, py):
            py2, oy2, fy2 = _detect_pitch_phase(dy, lo2, hi2)
            if fy2 >= 0.4:
                py, oy, fy = py2, oy2, fy2
    conf = min(fx, fy)
    if conf < 0.50 or px < 1.8 or py < 1.8:
        return dict(pitch_x=1.0, pitch_y=1.0, off_x=0.0, off_y=0.0,
                    confidence=float(conf), already_native=True)
    return dict(pitch_x=float(px), pitch_y=float(py),
                off_x=float(ox % px), off_y=float(oy % py),
                confidence=float(conf), already_native=False)


# --------------------------------------------------------------------------
# Estágio 3 — Reamostragem nativa (mediana por célula)
# --------------------------------------------------------------------------

def resample_native(rgba, grid):
    h, w = rgba.shape[:2]
    px, py = grid["pitch_x"], grid["pitch_y"]
    ox, oy = grid["off_x"], grid["off_y"]
    nw = max(1, int(math.floor((w - ox) / px)))
    nh = max(1, int(math.floor((h - oy) / py)))
    out = np.zeros((nh, nw, 4), dtype=np.uint8)
    rgb = rgba[..., :3]
    alp = rgba[..., 3]
    # pico de gradiente cai em B-1 (transição); compensa meia célula
    ox += 0.5
    oy += 0.5
    for j in range(nh):
        y0 = int(round(oy + j * py)); y1 = int(round(oy + (j + 1) * py))
        y0 = max(0, min(h, y0)); y1 = max(y0 + 1, min(h, y1))
        if y0 >= h:
            continue
        for i in range(nw):
            x0 = int(round(ox + i * px)); x1 = int(round(ox + (i + 1) * px))
            x0 = max(0, min(w, x0)); x1 = max(x0 + 1, min(w, x1))
            if x0 >= w:
                continue
            cell_a = alp[y0:y1, x0:x1]
            m = cell_a > 127
            frac = m.mean()
            if frac < 0.45:
                continue  # transparente
            # mediana só no miolo da célula: as bordas carregam pixels
            # misturados pelo blur/upscaling e viesariam a cor representativa
            my0 = y0 + int(0.22 * (y1 - y0)); my1 = max(my0 + 1, y1 - int(0.22 * (y1 - y0)))
            mx0 = x0 + int(0.22 * (x1 - x0)); mx1 = max(mx0 + 1, x1 - int(0.22 * (x1 - x0)))
            mi = alp[my0:my1, mx0:mx1] > 127
            if mi.sum() >= 4:
                cell = rgb[my0:my1, mx0:mx1][mi]
            else:
                cell = rgb[y0:y1, x0:x1][m]
            med = np.median(cell, axis=0)
            out[j, i] = (int(med[0]), int(med[1]), int(med[2]), 255)
    return out


# --------------------------------------------------------------------------
# Estágio 4 — Paleta global em OKLab (exata ou k-means)
# --------------------------------------------------------------------------

def collect_colors(natives, cap=300000):
    cols = np.concatenate([n[..., :3].reshape(-1, 3) for n in natives])
    al = np.concatenate([n[..., 3].reshape(-1) for n in natives])
    cols = cols[al > 0]
    if len(cols) > cap:
        cols = cols[np.random.default_rng(7).choice(len(cols), cap, replace=False)]
    return cols


def exact_palette(cols, max_colors, radius=10.0):
    """Paleta exata tolerante a jitter de codec: agrupa cores representativas
    num raio RGB pequeno (centro = mediana do grupo). Se o número de grupos
    cabe em max_colors, a paleta é a própria identidade cromática da arte
    (fidelidade absoluta, sem quantização destrutiva)."""
    uniq, counts = np.unique(cols, axis=0, return_counts=True)
    # só cores recorrentes entram na formação da paleta: misturas de células
    # desalinhadas (pontos médios espúrios) aparecem 1-2 vezes e são excluídas
    keep = counts >= 3
    uniq, counts = uniq[keep], counts[keep]
    if len(uniq) == 0:
        return None, False
    order = np.argsort(-counts)
    uniq, counts = uniq[order], counts[order]
    centers = []
    members = []
    for c in uniq:
        hit = -1
        for i, ct in enumerate(centers):
            if np.sqrt(((ct - c.astype(np.float64)) ** 2).sum()) <= radius:
                hit = i
                break
        if hit >= 0:
            members[hit].append(c)
            centers[hit] = np.median(np.array(members[hit]), axis=0)
        else:
            centers.append(c.astype(np.float64))
            members.append([c])
    if len(centers) <= max_colors:
        pal = np.clip(np.round(centers), 0, 255).astype(np.uint8)
        return pal, True
    return None, False


def kmeans_oklab(cols, k, iters=25, seed=7):
    lab = rgb_to_oklab(cols)
    rng = np.random.default_rng(seed)
    # k-means++ simplificado
    idx = [rng.integers(len(lab))]
    for _ in range(k - 1):
        d = np.min(((lab[:, None, :] - lab[idx][None, :, :]) ** 2).sum(-1), axis=1)
        p = d / (d.sum() + 1e-12)
        idx.append(rng.choice(len(lab), p=p))
    cen = lab[idx].copy()
    for _ in range(iters):
        d = ((lab[:, None, :] - cen[None, :, :]) ** 2).sum(-1)
        asg = d.argmin(1)
        newc = cen.copy()
        for c in range(k):
            m = asg == c
            if m.any():
                newc[c] = lab[m].mean(0)
        if np.abs(newc - cen).max() < 1e-5:
            cen = newc; break
        cen = newc
    return oklab_to_rgb(cen).astype(np.uint8)


def cell_purity(rgba, grid, sample=400):
    """Fração média de pixels de cada célula que concordam com a mediana da
    própria célula: máxima quando a grade está alinhada aos blocos reais."""
    h, w = rgba.shape[:2]
    px, py = grid["pitch_x"], grid["pitch_y"]
    ox, oy = grid["off_x"], grid["off_y"]
    nw = max(1, int((w - ox) / px)); nh = max(1, int((h - oy) / py))
    rng = np.random.default_rng(5)
    js = rng.integers(0, nh, sample); is_ = rng.integers(0, nw, sample)
    rgb = rgba[..., :3].astype(np.int16)
    tot = 0.0; n = 0
    for j, i in zip(js, is_):
        y0 = int(round(oy + j * py)); y1 = int(round(oy + (j + 1) * py))
        x0 = int(round(ox + i * px)); x1 = int(round(ox + (i + 1) * px))
        y0 = max(0, min(h, y0)); y1 = max(y0 + 1, min(h, y1))
        x0 = max(0, min(w, x0)); x1 = max(x0 + 1, min(w, x1))
        if y0 >= h or x0 >= w:
            continue
        cell = rgb[y0:y1, x0:x1]
        if rgba[y0:y1, x0:x1, 3].mean() <= 127:
            continue
        med = np.median(cell.reshape(-1, 3), axis=0)
        tot += (np.sqrt(((cell - med) ** 2).sum(-1)) <= 48).mean()
        n += 1
    return tot / max(1, n)


def refine_alignment(rgba, grid, steps=(-1.0, -0.5, 0.0, 0.5, 1.0)):
    """Busca local do deslocamento de fase maximizando pureza de célula."""
    if grid.get("already_native"):
        return grid
    best = (cell_purity(rgba, grid), grid["off_x"], grid["off_y"])
    for dx in steps:
        for dy in steps:
            if dx == 0 and dy == 0:
                continue
            g2 = dict(grid)
            g2["off_x"] = grid["off_x"] + dx
            g2["off_y"] = grid["off_y"] + dy
            sc = cell_purity(rgba, g2)
            if sc > best[0] + 1e-4:
                best = (sc, g2["off_x"], g2["off_y"])
    g3 = dict(grid)
    g3["off_x"], g3["off_y"] = best[1], best[2]
    g3["purity"] = round(best[0], 4)
    return g3


def _compactness(rgba, grid, k=10):
    """Distância média das cores representativas aos k centros modais:
    mínima quando a grade casa com os blocos reais (paleta compacta)."""
    nat = resample_native(rgba, grid)
    cols = nat[..., :3][nat[..., 3] > 0]
    if len(cols) < 60:
        return 1e9
    q = (cols // 6) * 6 + 3
    uniq, cnt = np.unique(q, axis=0, return_counts=True)
    top = uniq[np.argsort(-cnt)][:k].astype(np.float64)
    d = np.sqrt(((cols[:, None, :].astype(np.float64) - top[None, :, :]) ** 2).sum(-1))
    return float(d.min(1).mean())


def refine_grid_compact(rgba, grid, span_p=0.06, span_o=2.0):
    if grid.get("already_native"):
        return grid
    best = (_compactness(rgba, grid), grid["pitch_x"], grid["off_x"],
            grid["pitch_y"], grid["off_y"])
    for px in np.arange(grid["pitch_x"] - span_p, grid["pitch_x"] + span_p + 1e-9, 0.02):
        for ox in np.arange(grid["off_x"] - span_o, grid["off_x"] + span_o + 1e-9, 0.25):
            g = dict(grid); g["pitch_x"] = float(px); g["off_x"] = float(ox)
            c = _compactness(rgba, g)
            if c < best[0] - 1e-6:
                best = (c, float(px), float(ox), best[3], best[4])
    g = dict(grid); g["pitch_x"], g["off_x"] = best[1], best[2]
    for py in np.arange(g["pitch_y"] - span_p, g["pitch_y"] + span_p + 1e-9, 0.02):
        for oy in np.arange(g["off_y"] - span_o, g["off_y"] + span_o + 1e-9, 0.25):
            g2 = dict(g); g2["pitch_y"] = float(py); g2["off_y"] = float(oy)
            c = _compactness(rgba, g2)
            if c < best[0] - 1e-6:
                best = (c, best[1], best[2], float(py), float(oy))
    g["pitch_y"], g["off_y"] = best[3], best[4]
    g["compactness"] = round(best[0], 3)
    return g


def snap_to_palette(native, pal_lab, pal_rgb):
    """Nearest-neighbor em OKLab; retorna índices + erro médio."""
    a = native[..., 3]
    rgb = native[..., :3]
    m = a > 0
    lab = rgb_to_oklab(rgb[m])
    d = ((lab[:, None, :] - pal_lab[None, :, :]) ** 2).sum(-1)
    idx = d.argmin(1)
    err = float(np.sqrt(d[np.arange(len(lab)), idx]).mean())
    out = native.copy()
    out[..., :3][m] = pal_rgb[idx]
    return out, idx, err


# --------------------------------------------------------------------------
# Estágio 5 — Limpeza de órfãos + dithering opcional
# --------------------------------------------------------------------------

def remove_orphans(img, passes=1):
    """Pixel cuja cor não aparece nos 4-vizinhos e o modo 8-vizinho cobre >=4
    é substituído pelo modo (remove ruído pontual de IA sem tocar em detalhes
    intencionais: pixels isolados cercados por vazio permanecem)."""
    changed = 0
    for _ in range(passes):
        h, w = img.shape[:2]
        out = img.copy()
        nch = 0
        for j in range(h):
            for i in range(w):
                if img[j, i, 3] == 0:
                    continue
                c = img[j, i]
                nb4 = [img[j, i - 1] if i > 0 else None, img[j, i + 1] if i < w - 1 else None,
                       img[j - 1, i] if j > 0 else None, img[j + 1, i] if j < h - 1 else None]
                if any(n is not None and n[3] > 0 and tuple(n[:3]) == tuple(c[:3]) for n in nb4):
                    continue
                nb8 = []
                for dj in (-1, 0, 1):
                    for di in (-1, 0, 1):
                        if dj == 0 and di == 0:
                            continue
                        jj, ii = j + dj, i + di
                        if 0 <= jj < h and 0 <= ii < w and img[jj, ii, 3] > 0:
                            nb8.append(tuple(img[jj, ii, :3]))
                if not nb8:
                    continue
                mode, cnt = Counter(nb8).most_common(1)[0]
                if cnt >= 4 and mode != tuple(c[:3]):
                    out[j, i, :3] = mode
                    nch += 1
        img = out
        changed += nch
        if nch == 0:
            break
    return img, changed


BAYER4 = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]],
                  dtype=np.float64) / 16.0 - 0.5


def dither_bayer(native, pal_lab, pal_rgb, strength=0.6):
    h, w = native.shape[:2]
    out = native.copy()
    for j in range(h):
        for i in range(w):
            if native[j, i, 3] == 0:
                continue
            lab = rgb_to_oklab(native[j, i, :3].astype(np.float64))
            thr = (BAYER4[j % 4, i % 4]) * strength * 0.06
            lab = lab + np.array([thr, 0, 0])
            d = ((pal_lab - lab) ** 2).sum(-1)
            out[j, i, :3] = pal_rgb[d.argmin()]
    return out


# --------------------------------------------------------------------------
# Estágio 6 — Exportação (PNG via PIL, GIF próprio, paletas .gpl/.act)
# --------------------------------------------------------------------------

def gif_lzw(indices, min_code_size):
    """LZW GIF89a. Regra de largura validada contra o decoder do PIL:
    emite com a largura atual; após adicionar a entrada `nxt`, se
    nxt > (1 << w) então w += 1 (máx. 12)."""
    clear = 1 << min_code_size
    end = clear + 1

    def reset():
        return {(i,): i for i in range(clear)}, end + 1, min_code_size + 1

    table, nxt, w = reset()
    emitted = []          # (code, width)
    emitted.append((clear, w))
    cur = ()
    for k in indices:
        wk = cur + (k,)
        if wk in table:
            cur = wk
            continue
        emitted.append((table[cur], w))
        if nxt < 4096:
            table[wk] = nxt
            nxt += 1
            if nxt > (1 << w) and w < 12:
                w += 1
        else:
            emitted.append((clear, w))
            table, nxt, w = reset()
        cur = (k,)
    if cur:
        emitted.append((table[cur], w))
    emitted.append((end, w))
    # empacotamento LSB-first em sub-blocos de 255 bytes
    acc = 0
    nbits = 0
    buf = bytearray()
    for c, cs in emitted:
        acc |= c << nbits
        nbits += cs
        while nbits >= 8:
            buf.append(acc & 0xFF)
            acc >>= 8
            nbits -= 8
    if nbits:
        buf.append(acc & 0xFF)
    chunks = bytearray()
    for i in range(0, len(buf), 255):
        blk = buf[i:i + 255]
        chunks.append(len(blk))
        chunks += blk
    chunks.append(0)
    return bytes(chunks)


def write_gif(path, frames_idx, palette_rgb, w, h, delay_cs, transparent=True):
    n = len(palette_rgb)
    need = n + 1 if transparent else n
    bits = max(1, math.ceil(math.log2(max(2, need))))
    size = 1 << bits
    pal = np.zeros((size, 3), dtype=np.uint8)
    pal[:n] = palette_rgb
    tidx = size - 1 if transparent else 0
    mcs = max(2, bits)
    out = bytearray(b"GIF89a")
    out += struct.pack("<HH", w, h)
    out += bytes([0xF0 | (bits - 1), 0, 0])
    out += pal.tobytes()
    out += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"  # loop infinito
    for fidx in frames_idx:
        out += b"\x21\xF9\x04"
        flags = (2 << 2) | (0x01 if transparent else 0x00)  # disposal=2 + transp
        out += bytes([flags])
        out += struct.pack("<H", delay_cs)
        out += bytes([tidx if transparent else 0])
        out += b"\x00"
        out += b"\x2C" + struct.pack("<HHHH", 0, 0, w, h) + bytes([0])
        flat = fidx.reshape(-1).astype(np.int64).copy()
        if transparent:
            flat[fidx.reshape(-1) < 0] = tidx
        out += bytes([mcs])
        out += gif_lzw(flat.tolist(), mcs)
    out += b"\x3B"
    with open(path, "wb") as f:
        f.write(out)


def write_gpl(path, name, palette_rgb):
    with open(path, "w") as f:
        f.write("GIMP Palette\nName: %s\nColumns: 0\n#\n" % name)
        for i, (r, g, b) in enumerate(palette_rgb):
            f.write("%3d %3d %3d\t%s\n" % (r, g, b, "C%02d" % i))


def write_act(path, palette_rgb):
    pal = np.zeros((256, 3), dtype=np.uint8)
    pal[:len(palette_rgb)] = palette_rgb
    with open(path, "wb") as f:
        f.write(pal.tobytes())
        f.write(struct.pack(">HH", len(palette_rgb), 0))


# --------------------------------------------------------------------------
# Pipeline completo
# --------------------------------------------------------------------------

def process(inputs, outdir, max_colors=32, chroma="auto", tol=90.0,
            cleanup=1, dither="off", preview_scale=None, fps=12, pitch=None):
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(os.path.join(outdir, "frames_native"), exist_ok=True)
    report = {"inputs": [os.path.basename(i) for i in inputs], "frames": []}

    sources = [np.asarray(Image.open(p).convert("RGBA")) for p in inputs]

    # Estágio 0/1 — chroma-key
    key_info = None
    if chroma != "off":
        if chroma.startswith("#"):
            key = tuple(int(chroma[i:i + 2], 16) for i in (1, 3, 5))
            cov = 1.0
        else:
            det = detect_chroma_key(sources[0])
            if det is None:
                key, cov = None, 0.0
            else:
                key, cov = det
        if key is not None:
            key_info = {"key": list(key), "border_coverage": round(cov, 3)}
            sources = [chroma_key(s, key, tol) for s in sources]
    report["chroma_key"] = key_info

    # Estágio 2 — grade (detectada no frame 0; confirmada pela mediana dos pitches)
    grids = [detect_grid(sources[0])]
    if pitch:
        g0 = grids[0]
        g0.update(pitch_x=float(pitch), pitch_y=float(pitch), already_native=False)
    else:
        g0 = grids[0]
    g0 = refine_grid_compact(sources[0], refine_alignment(sources[0], g0))
    report["grid"] = {k: (round(v, 4) if isinstance(v, float) else v)
                      for k, v in g0.items()}

    # Estágio 3 — reamostragem nativa
    natives = [resample_native(s, g0) for s in sources]
    nh, nw = natives[0].shape[:2]
    report["native_size"] = [nw, nh]

    # Estágio 4 — paleta global compartilhada
    cols = collect_colors(natives)
    report["unique_native_colors"] = int(len(np.unique(cols, axis=0)))
    pal, exact = exact_palette(cols, max_colors)
    if pal is None:
        pal = kmeans_oklab(cols, max_colors)
        exact = False
    report["palette_exact"] = bool(exact)
    report["palette_size"] = int(len(pal))
    pal_lab = rgb_to_oklab(pal.astype(np.float64))

    # Estágios 4b/5 — snap, limpeza, dither
    quant = []
    cleaned_frames = []
    for n in natives:
        sn, _, err = snap_to_palette(n, pal_lab, pal)
        quant.append(round(err, 5))
        if cleanup > 0:
            sn, ch = remove_orphans(sn, cleanup)
        else:
            ch = 0
        if dither == "bayer":
            sn = dither_bayer(sn, pal_lab, pal)
        cleaned_frames.append((sn, ch))
    report["quantization_mean_oklab_de"] = quant
    report["orphan_pixels_removed"] = [int(c) for _, c in cleaned_frames]
    finals = [f for f, _ in cleaned_frames]

    # métrica de flicker: histograma de paleta entre frames consecutivos
    flick = []
    for a, b in zip(finals, finals[1:]):
        ha = Counter(map(tuple, a[..., :3][a[..., 3] > 0].tolist()))
        hb = Counter(map(tuple, b[..., :3][b[..., 3] > 0].tolist()))
        tot = sum(ha.values()) + sum(hb.values()) or 1
        flick.append(round(sum(abs(ha[k] - hb.get(k, 0)) for k in ha) / tot, 4))
    report["inter_frame_histogram_delta"] = flick

    # Estágio 6 — exportação
    pal_order = [tuple(c) for c in pal]
    for i, f in enumerate(finals):
        Image.fromarray(f, "RGBA").save(
            os.path.join(outdir, "frames_native", "frame_%02d.png" % i))
    sheet = np.concatenate(finals, axis=1)
    Image.fromarray(sheet, "RGBA").save(os.path.join(outdir, "sprite_sheet.png"))
    z = preview_scale or max(1, int(math.ceil(640 / max(nw, nh))))
    Image.fromarray(sheet, "RGBA").resize(
        (sheet.shape[1] * z, sheet.shape[0] * z), Image.NEAREST).save(
        os.path.join(outdir, "preview_x%d.png" % z))
    Image.fromarray(finals[0], "RGBA").resize(
        (nw * z, nh * z), Image.NEAREST).save(
        os.path.join(outdir, "preview_frame0_x%d.png" % z))

    idx_frames = []
    for f in finals:
        ix = np.full(f.shape[:2], -1, dtype=np.int64)
        m = f[..., 3] > 0
        flat_rgb = f[..., :3][m]
        keys = {c: k for k, c in enumerate(pal_order)}
        ix[m] = [keys[tuple(c)] for c in flat_rgb]
        idx_frames.append(ix)
    write_gif(os.path.join(outdir, "animation.gif"), idx_frames, pal,
              nw, nh, max(1, int(round(100 / fps))))
    write_gpl(os.path.join(outdir, "palette.gpl"), "ai2pixel", pal)
    write_act(os.path.join(outdir, "palette.act"), pal)
    Image.fromarray(np.repeat(np.repeat(pal[None, :, :], 8, 0), 8, 1).astype(np.uint8),
                    "RGB").save(os.path.join(outdir, "palette.png"))
    with open(os.path.join(outdir, "report.json"), "w") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)
    return report


def main():
    ap = argparse.ArgumentParser(description="ai2pixel — Grade-Nativa pipeline")
    ap.add_argument("-i", "--inputs", nargs="+", required=True)
    ap.add_argument("-o", "--outdir", default="out")
    ap.add_argument("--max-colors", type=int, default=32)
    ap.add_argument("--chroma", default="auto")
    ap.add_argument("--tol", type=float, default=90.0)
    ap.add_argument("--cleanup", type=int, default=1)
    ap.add_argument("--dither", choices=["off", "bayer"], default="off")
    ap.add_argument("--preview-scale", type=int, default=None)
    ap.add_argument("--fps", type=float, default=12)
    ap.add_argument("--pitch", type=float, default=None)
    a = ap.parse_args()
    rep = process(a.inputs, a.outdir, a.max_colors, a.chroma, a.tol, a.cleanup,
                  a.dither, a.preview_scale, a.fps, a.pitch)
    print(json.dumps({k: rep[k] for k in
                      ("grid", "native_size", "unique_native_colors",
                       "palette_exact", "palette_size")}, indent=2))


if __name__ == "__main__":
    main()
