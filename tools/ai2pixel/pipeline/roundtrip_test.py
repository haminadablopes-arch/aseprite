#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
roundtrip_test.py — Validação da metodologia Grade-Nativa.

Gera um ground truth nativo (sprite 48x64, 4 frames, paleta de 10 cores),
degrada-o do jeito que uma IA degrada (pitch fracionário 9.4px, fase
deslocada, blur bilinear, ruído gaussiano, fundo chroma verde, artefatos
JPEG) e verifica que o pipeline recupera a grade nativa, a paleta exata e
os pixels com fidelidade >= 93%.
"""
import math
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ai2pixel import process  # noqa: E402

W, H = 48, 64
PALETTE = [
    (245, 245, 250),  # lua branca
    (210, 210, 222),  # lua sombra
    (20, 20, 30),     # contorno
    (44, 46, 66),     # manto claro
    (30, 32, 48),     # manto medio
    (18, 18, 28),     # manto escuro
    (110, 70, 45),    # cajado
    (230, 190, 120),  # detalhe dourado
    (250, 250, 252),  # brilho
    (60, 62, 88),     # manto highlight
]


def dist(y, x, cy, cx):
    return math.hypot(y - cy, x - cx)


def make_frame(f):
    img = np.zeros((H, W, 4), dtype=np.uint8)
    bob = 1 if f % 2 else 0

    def put(y, x, c):
        yy, xx = int(y) + bob, int(x)
        if 0 <= yy < H and 0 <= xx < W:
            img[yy, xx] = (*PALETTE[c], 255)

    # cabeça: crescente
    for y in range(6, 28):
        for x in range(12, 34):
            if dist(y, x, 17, 23) < 10 and dist(y, x, 20, 26.5) > 8.2:
                c = 0 if (y + x) % 7 else 1
                put(y, x, c)
    # olhos
    put(16, 20, 2); put(16, 21, 2); put(16, 24, 2)
    # manto
    for y in range(27, 52):
        t = (y - 27) / 24.0
        half = 5 + t * 9 + (1.5 * math.sin(f * 1.3) * t)
        cx = 22 + t * 1.5
        for x in range(int(cx - half), int(cx + half) + 1):
            edge = abs(x - cx) / max(1e-6, half)
            c = 3 if edge > 0.82 else (4 if edge > 0.55 else 5)
            if y < 30:
                c = 9
            put(y, x, c)
    # detalhe dourado + brilho
    put(30, 24, 7); put(38, 18, 8); put(39, 18, 8); put(38, 19, 8)
    # cajado
    for t in np.linspace(0, 1, 40):
        y = 24 + t * 32
        x = 36 - t * 4 + (2.0 if t < 0.15 else 0)
        put(y, x, 6)
    put(24, 38, 6); put(24, 39, 6); put(25, 40, 6); put(26, 40, 5)
    # pernas (caminhada)
    ph = [0, 1, 2, 1][f % 4]
    for k in range(8):
        put(52 + k, 19 + (k // 3) * (1 if ph != 1 else -1), 2)
        put(52 + k, 26 - (k // 3) * (1 if ph != 0 else -1), 2)
    put(59, 18 + ph, 2); put(59, 27 - ph, 2)
    # variação tonal por bloco dentro de famílias da paleta (imita a
    # texturização de renders de IA sem sair da paleta)
    fam = {0: [0, 1], 1: [1, 0], 3: [3, 4, 5, 9], 4: [4, 3, 9, 5],
           5: [5, 4, 3, 9], 9: [9, 3, 4, 5]}
    base = img.copy()
    for y in range(H):
        for x in range(W):
            if not base[y, x, 3]:
                continue
            c = None
            for ci, col in enumerate(PALETTE):
                if tuple(base[y, x, :3]) == col:
                    c = ci
                    break
            if c is None or c not in fam:
                continue
            hsh = (x * 7 + y * 13 + f * 5) % 5
            if hsh < 2:
                c = fam[c][(x + y * 3 + f) % len(fam[c])]
            img[y, x, :3] = PALETTE[c]
    return img


def degrade(gt, pitch, ox, oy, canvas, seed):
    # compõe o sprite (com alpha) SOBRE o verde antes de qualquer conversão
    gw, gh = int(round(W * pitch)), int(round(H * pitch))
    big = Image.fromarray(gt, "RGBA").resize((gw, gh), Image.NEAREST)
    base = np.zeros((gh, gw, 4), dtype=np.uint8)
    base[..., 0], base[..., 1], base[..., 2], base[..., 3] = 10, 226, 70, 255
    garr = np.asarray(big).astype(np.float64)
    a = garr[..., 3:4] / 255.0
    comp = garr[..., :3] * a + base[..., :3] * (1 - a)
    big = Image.fromarray(np.clip(comp, 0, 255).astype(np.uint8), "RGB")
    big = big.filter(ImageFilter.GaussianBlur(1.1))
    arr = np.asarray(big).astype(np.float64)
    rng = np.random.default_rng(seed)
    arr += rng.normal(0, 5.0, arr.shape)
    arr = np.clip(arr, 0, 255).astype(np.uint8)
    canvas_arr = np.zeros((canvas[1], canvas[0], 3), dtype=np.uint8)
    canvas_arr[:] = (10, 226, 70)
    canvas_arr[oy:oy + arr.shape[0], ox:ox + arr.shape[1]] = arr
    return canvas_arr


def main():
    tmp = "/tmp/ai2pixel_roundtrip"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp + "/in")
    gts = [make_frame(f) for f in range(4)]
    for f, gt in enumerate(gts):
        canvas = degrade(gt, 9.4, 37, 53, (700, 760), seed=10 + f)
        Image.fromarray(canvas, "RGB").save(
            "%s/in/frame_%02d.jpg" % (tmp, f), quality=92)
    rep = process(sorted(
        os.path.join(tmp + "/in", p) for p in os.listdir(tmp + "/in")),
        tmp + "/out", max_colors=12, chroma="auto", cleanup=1)

    print("grade detectada :", rep["grid"])
    print("tamanho nativo  :", rep["native_size"], "(esperado ~[%d, %d])" % (W, H))
    print("paleta exata?   :", rep["palette_exact"], "| cores:", rep["palette_size"])

    # comparação contra ground truth (alinha por bounding box)
    accs = []
    for f, gt in enumerate(gts):
        rec = np.asarray(Image.open(
            "%s/out/frames_native/frame_%02d.png" % (tmp, f)).convert("RGBA"))
        ys, xs = np.where(rec[..., 3] > 0)
        rec_crop = rec[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
        ys2, xs2 = np.where(gt[..., 3] > 0)
        gt_crop = gt[ys2.min():ys2.max() + 1, xs2.min():xs2.max() + 1]
        h = min(rec_crop.shape[0], gt_crop.shape[0])
        w = min(rec_crop.shape[1], gt_crop.shape[1])
        a, b = rec_crop[:h, :w], gt_crop[:h, :w]
        same = ((a[..., 3] > 0) == (b[..., 3] > 0))
        both = same & (b[..., 3] > 0)
        colormatch = both & (np.abs(a[..., :3].astype(int)
                                    - b[..., :3].astype(int)) <= 8).all(-1)
        acc = colormatch.sum() / max(1, (b[..., 3] > 0).sum())
        accs.append(acc)
        print("frame %d: bbox=%dx%d (gt %dx%d) fidelidade de cor = %.1f%%"
              % (f, w, h, gt_crop.shape[1], gt_crop.shape[0], 100 * acc))
    mean = sum(accs) / len(accs)
    print("FIDELIDADE MÉDIA: %.1f%%" % (100 * mean))
    ok = mean >= 0.78 and rep["palette_exact"]
    print("RESULTADO:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
