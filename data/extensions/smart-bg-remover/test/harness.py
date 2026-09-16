#!/usr/bin/env python3
"""
Harness de auditoria do núcleo (bgcore.lua) do Removedor de Fundo Inteligente.

Roda o algoritmo Lua puro (sem Aseprite) sobre imagens RGBA e compara o
resultado com uma máscara verdade (ground truth) gerada junto com a imagem.

Uso:
    python3 harness.py                 # roda os casos sintéticos
    python3 harness.py --real DIR      # roda sobre PNGs reais de DIR

Requisitos: pip install numpy pillow lupa
"""
import os
import sys
import time
import argparse

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "lib")
OUT = os.path.join(HERE, "out")

# ------------------------------------------------------------------ runtime Lua
_lua = None


def lua():
    global _lua
    if _lua is None:
        import lupa
        _lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        _lua.execute("package.path = %r .. ';' .. package.path" % (LIB + "/?.lua"))
        _lua.execute("bgcore = require('bgcore')")
        # O resultado é binário: transportamos em hexadecimal (lupa não
        # converte strings Lua com bytes arbitrários para Python).
        _lua.execute("""
          local hexbyte = {}
          for i = 0, 255 do hexbyte[string.char(i)] = string.format('%02x', i) end
          local bytefrom = setmetatable({}, { __index = function(t, k)
            local v = string.char(tonumber(k, 16))
            t[k] = v
            return v
          end })
          function __run_bgcore(hexdata, ctx, opts)
            local data = hexdata:gsub('..', bytefrom)
            local out, rep = bgcore.process(data, ctx, opts)
            return (out:gsub('.', hexbyte)), rep
          end
        """)
    return _lua


def run_bgcore(rgba, opts):
    """rgba: np.uint8 array (h,w,4). Devolve (novo_rgba, report_dict)."""
    L = lua()
    h, w = rgba.shape[:2]
    data = rgba.tobytes()
    ctx = L.table_from({
        "w": w, "h": h, "stride": w * 4, "bpp": 4,
        "transparentKey": "\0\0\0\0",
    })
    o = L.table_from(opts)
    t0 = time.time()
    hexdata = data.hex()
    hexout, report = L.eval("__run_bgcore")(hexdata, ctx, o)
    dt = time.time() - t0
    out = np.frombuffer(bytes.fromhex(hexout), dtype=np.uint8).reshape(h, w, 4).copy()
    return out, dict(report), dt


# --------------------------------------------------------- geração dos casos
def ellipse_mask(h, w, cy, cx, ry, rx):
    y, x = np.mgrid[0:h, 0:w]
    return ((x - cx) ** 2 / rx ** 2 + (y - cy) ** 2 / ry ** 2) <= 1.0


def rect_mask(h, w, y0, y1, x0, x1):
    m = np.zeros((h, w), bool)
    m[y0:y1, x0:x1] = True
    return m


def antialias(mask, radius=2):
    """Cria uma faixa 'ignore' (valor 2) ao redor da máscara para bordas suaves."""
    from PIL import ImageFilter
    img = Image.fromarray((mask * 255).astype(np.uint8))
    blur = np.asarray(img.filter(ImageFilter.GaussianBlur(radius)))
    return (blur > 20) & (blur < 235)


def checker(w, h, cA, cB, size=1):
    yy, xx = np.mgrid[0:h, 0:w]
    sel = (((xx // size) + (yy // size)) % 2) == 0
    bg = np.zeros((h, w, 4), np.uint8)
    bg[sel] = cA
    bg[~sel] = cB
    return bg


def bayer8(w, h, cA, cB):
    B = np.array([
        [0, 32, 8, 40, 2, 34, 10, 42],
        [48, 16, 56, 24, 50, 18, 58, 26],
        [12, 44, 4, 36, 14, 46, 6, 38],
        [60, 28, 52, 20, 62, 30, 54, 22],
        [3, 35, 11, 43, 1, 33, 9, 41],
        [51, 19, 59, 27, 49, 17, 57, 25],
        [15, 47, 7, 39, 13, 45, 5, 37],
        [63, 31, 55, 23, 61, 29, 53, 21]], np.uint8) * 4
    yy, xx = np.mgrid[0:h, 0:w]
    sel = B[yy % 8, xx % 8] > 127
    bg = np.zeros((h, w, 4), np.uint8)
    bg[sel] = cA
    bg[~sel] = cB
    return bg


def stripes(w, h, cA, cB, period=4):
    xx = np.mgrid[0:h, 0:w][1]
    sel = (xx % period) < (period // 2)
    bg = np.zeros((h, w, 4), np.uint8)
    bg[sel] = cA
    bg[~sel] = cB
    return bg


def gradient_bg(w, h, c0, c1):
    xx = np.mgrid[0:h, 0:w][1] / max(1, w - 1)
    bg = np.zeros((h, w, 4), np.uint8)
    for i, ch in enumerate(range(3)):
        bg[:, :, ch] = (c0[ch] * (1 - xx) + c1[ch] * xx).astype(np.uint8)
    bg[:, :, 3] = 255
    return bg


def noise_bg(w, h, cA, cB, rng):
    sel = rng.random((h, w)) < 0.5
    bg = np.zeros((h, w, 4), np.uint8)
    bg[sel] = cA
    bg[~sel] = cB
    return bg


def subject_over(bg, mask, subject_img):
    img = bg.copy()
    img[mask] = subject_img[mask]
    return img


def shaded_subject(h, w, base, rng, noise=18):
    yy, xx = np.mgrid[0:h, 0:w]
    shade = (1.0 - (yy / max(1, h - 1)) * 0.55)[:, :, None]
    col = np.array(base, float) * shade
    col = col + rng.normal(0, noise, (h, w, 1))
    col = np.clip(col, 0, 255)
    out = np.zeros((h, w, 4), np.uint8)
    out[:, :, :3] = col.astype(np.uint8)
    out[:, :, 3] = 255
    return out


IGNORE = 2
BG = 1
FG = 0


def build_cases(size=(512, 512)):
    h, w = size
    rng = np.random.default_rng(7)
    cases = []

    # 1. fundo plano
    bg = np.zeros((h, w, 4), np.uint8)
    bg[:, :] = (30, 60, 90, 255)
    m = ellipse_mask(h, w, h // 2, w // 2, h // 3, w // 3)
    sub = shaded_subject(h, w, (200, 120, 60), rng)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="flat", img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=24, contiguous=True)))

    # 2. xadrez 1x1 (duas cores que se alternam a cada pixel)
    bg = checker(w, h, (255, 255, 255, 255), (210, 210, 210, 255), 1)
    m = ellipse_mask(h, w, h // 2, w // 2, h // 3, int(w * 0.42))
    sub = shaded_subject(h, w, (60, 90, 170), rng)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="checker1x1", img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=30, contiguous=False)))

    # 3. xadrez 2x2
    bg = checker(w, h, (250, 250, 245, 255), (225, 225, 220, 255), 2)
    m = rect_mask(h, w, h // 5, int(h * 0.8), w // 5, int(w * 0.8))
    sub = shaded_subject(h, w, (120, 40, 140), rng)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="checker2x2", img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=28, contiguous=False)))

    # 4. listras verticais periodo 4
    bg = stripes(w, h, (240, 240, 240, 255), (200, 200, 205, 255), 4)
    m = ellipse_mask(h, w, int(h * 0.45), int(w * 0.5), int(h * 0.35), int(w * 0.3))
    sub = shaded_subject(h, w, (40, 150, 90), rng)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="stripes4", img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=26, contiguous=False)))

    # 5. trama de Bayer 8x8 (dither)
    bg = bayer8(w, h, (250, 245, 235, 255), (215, 210, 200, 255))
    m = ellipse_mask(h, w, h // 2, w // 2, int(h * 0.32), int(w * 0.36))
    sub = shaded_subject(h, w, (170, 60, 60), rng)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="bayer8x8", img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=30, contiguous=False)))

    # 6. gradiente linear
    bg = gradient_bg(w, h, (20, 20, 30), (180, 200, 230))
    m = ellipse_mask(h, w, int(h * 0.55), int(w * 0.45), int(h * 0.3), int(w * 0.25))
    sub = shaded_subject(h, w, (230, 180, 40), rng)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="gradient", img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=26, contiguous=False)))

    # 7. fundo ruidoso (sem estrutura) -> fallback com conectividade
    bg = noise_bg(w, h, (55, 55, 60, 255), (75, 72, 68, 255), rng)
    m = ellipse_mask(h, w, h // 2, w // 2, int(h * 0.33), int(w * 0.3))
    sub = shaded_subject(h, w, (200, 200, 60), rng)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="noise", img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=40, contiguous=True)))

    # 8. fundo plano com ILHA interna (buraco da cor do fundo dentro do sujeito)
    bg = np.zeros((h, w, 4), np.uint8)
    bg[:, :] = (30, 60, 90, 255)
    m = ellipse_mask(h, w, h // 2, w // 2, int(h * 0.42), int(w * 0.42))
    hole = ellipse_mask(h, w, h // 2, w // 2, int(h * 0.10), int(w * 0.10))
    m2 = m & ~hole
    sub = shaded_subject(h, w, (200, 120, 60), rng)
    gt = np.where(m2, FG, BG).astype(np.uint8)
    gt[hole] = BG
    gt[antialias(m2)] = IGNORE
    cases.append(dict(name="flat_island", img=subject_over(bg, m2, sub), gt=gt,
                      opts=dict(tolerance=24, contiguous=True, removeIslands=True)))

    # 9. fundo já transparente
    bg = np.zeros((h, w, 4), np.uint8)
    m = ellipse_mask(h, w, h // 2, w // 2, int(h * 0.35), int(w * 0.35))
    sub = shaded_subject(h, w, (210, 90, 160), rng)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="already_transparent",
                      img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=24, contiguous=True)))

    # 10. fundo plano onde o SUJEITO contém pixels da cor do fundo
    #     (teste crítico: só a conectividade salva o sujeito)
    bg = np.zeros((h, w, 4), np.uint8)
    bg[:, :] = (30, 60, 90, 255)
    m = rect_mask(h, w, h // 4, int(h * 0.75), w // 4, int(w * 0.75))
    sub = shaded_subject(h, w, (200, 200, 200), rng)
    sub[rect_mask(h, w, int(h * 0.45), int(h * 0.55), int(w * 0.45), int(w * 0.55))] = (30, 60, 90, 255)
    gt = np.where(m, FG, BG).astype(np.uint8)
    gt[antialias(m)] = IGNORE
    cases.append(dict(name="subject_has_bg_color", img=subject_over(bg, m, sub), gt=gt,
                      opts=dict(tolerance=20, contiguous=True)))

    return cases


# ------------------------------------------------------------------- avaliação
def warn_list(report):
    w = report.get("warnings")
    if not w:
        return []
    if isinstance(w, dict):
        return [str(v) for v in w.values()]
    return [str(v) for v in w]


def evaluate(name, before, after, gt, elapsed, report):
    removed = after[:, :, 3] == 0
    before_empty = before[:, :, 3] == 0
    gt_bg = (gt == BG) & ~before_empty
    gt_fg = (gt == FG) & ~before_empty
    ignore = (gt == IGNORE) & ~before_empty

    tp = int(np.sum(removed & gt_bg))
    fn = int(np.sum(~removed & gt_bg))
    fp = int(np.sum(removed & gt_fg))
    fp_soft = int(np.sum(removed & ignore))
    total_bg = tp + fn
    total_fg = int(np.sum(gt_fg))

    recall = tp / total_bg * 100 if total_bg else float("nan")
    damage = fp / total_fg * 100 if total_fg else float("nan")

    ok = (recall >= 99.0) and (damage <= 1.0)
    if report.get("modelType") in ("transparent", "empty"):
        ok = (fp == 0) and (fp_soft == 0)
    return dict(name=name, recall=recall, damage=damage, tp=tp, fn=fn, fp=fp,
                fp_soft=fp_soft, total_bg=total_bg, total_fg=total_fg,
                elapsed=elapsed, ok=ok, report=report)


def save_triptych(name, before, after, gt):
    h, w = before.shape[:2]
    canvas = np.zeros((h, w * 3, 4), np.uint8)
    canvas[:, 0:w] = before
    canvas[:, w:2 * w] = after
    # terceiro painel: verde = fundo removido corretamente, vermelho = dano
    check = np.zeros((h, w, 4), np.uint8)
    check[:, :, 3] = 255
    removed = after[:, :, 3] == 0
    gt_bg = gt == BG
    gt_fg = gt == FG
    check[removed & gt_bg] = (40, 200, 40, 255)
    check[removed & gt_fg] = (230, 30, 30, 255)
    check[~removed & gt_bg] = (250, 200, 0, 255)
    check[gt == IGNORE] = (90, 90, 90, 255)
    canvas[:, 2 * w:] = check
    Image.fromarray(canvas, "RGBA").save(os.path.join(OUT, name + ".png"))


# --------------------------------------------------------- teste de integração
EXT = os.path.dirname(HERE)


def _write_bin(path, arr):
    h, w = arr.shape[:2]
    with open(path, "wb") as f:
        f.write(int(w).to_bytes(4, "little"))
        f.write(int(h).to_bytes(4, "little"))
        f.write(arr.tobytes())


def _read_bin(path):
    with open(path, "rb") as f:
        w = int.from_bytes(f.read(4), "little")
        h = int.from_bytes(f.read(4), "little")
        data = f.read()
    return np.frombuffer(data, dtype=np.uint8).reshape(h, w, 4).copy()


def integration(size=256, case_name="checker2x2"):
    """Roda o main.lua inteiro (comando de menu) sobre um sprite falso."""
    L = lua()
    L.execute("package.path = %r .. ';' .. package.path" % (HERE + "/?.lua"))
    L.execute("integration = require('integration')")

    cases = {c["name"]: c for c in build_cases((size, size))}
    case = cases[case_name]
    img = case["img"]
    gt = case["gt"]

    # três frames: o 2º com o fundo levemente diferente (testa a detecção por frame)
    frames = [img]
    img2 = img.copy()
    mask_bg = gt == BG
    img2[..., :3] = np.clip(img2[..., :3].astype(int) + 6, 0, 255).astype(np.uint8)
    frames.append(img2)
    frames.append(img.copy())

    indir = os.path.join(OUT, "integration_in")
    outdir = os.path.join(OUT, "integration_out")
    os.makedirs(indir, exist_ok=True)
    os.makedirs(outdir, exist_ok=True)
    inputs, outputs = [], []
    for i, fr in enumerate(frames):
        p = os.path.join(indir, "frame_%02d.bin" % (i + 1))
        _write_bin(p, fr)
        inputs.append(p)
        outputs.append(os.path.join(outdir, "frame_%02d.bin" % (i + 1)))

    opts = case["opts"]
    # listas python sao 0-based no lupa: converte para tabelas lua (1-based)
    cfg = L.table_from({
        "extPath": EXT,
        "inputs": L.table_from(inputs),
        "outputs": L.table_from(outputs),
        "selectedFrames": L.table_from([1, 2, 3]),
        "button": "remove",
        "command": "SmartBgRemover",
        "opts": L.table_from({
            "modeLabel": "Automático",
            "scopeLabel": "Frames selecionados",
            "layersLabel": "Camada ativa",
            "tolerance": int(opts.get("tolerance", 24)),
            "soft": 0,
            "contiguous": bool(opts.get("contiguous", True)),
            "removeIslands": bool(opts.get("removeIslands", False)),
            "sample": 6,
            "sideTop": True, "sideBottom": True,
            "sideLeft": True, "sideRight": True,
            "perFrame": True,
        }),
    })
    res = L.eval("integration.run")(cfg)
    res = dict(res)

    print("\n=== INTEGRAÇÃO (main.lua + menu de contexto) ===")
    def aslist(v):
        if v is None:
            return []
        if isinstance(v, (list, tuple)):
            return [str(x) for x in v]
        return [str(x) for x in v.values()]

    print("comandos registrados:")
    for line in aslist(res.get("commands")):
        print("   ", line)
    print("submenus registrados:")
    for line in aslist(res.get("groups")):
        print("   ", line)
    print("transações:", aslist(res.get("transactions")))
    print("imagens substituídas:", res.get("imagesReplaced"))
    alerts = aslist(res.get("alerts"))
    if alerts:
        print("alertas:", alerts)
    if not res.get("ok"):
        print("ERRO:", res.get("error"))
        return False

    ok = True
    for i, out in enumerate(outputs):
        after = _read_bin(out)
        r = evaluate("frame_%02d" % (i + 1), frames[i], after, gt, 0, {})
        print(f"  frame {i+1}: fundo removido {r['recall']:.2f}%  "
              f"dano {r['damage']:.2f}%  {'OK' if r['ok'] else 'FALHOU'}")
        ok = ok and r["ok"]
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--real", help="pasta com PNGs reais (sem ground truth)")
    ap.add_argument("--size", default="512")
    ap.add_argument("--opts", default="", help='ex: tolerance=40,contiguous=true')
    ap.add_argument("--integration", action="store_true",
                    help="testa o main.lua com o Aseprite simulado")
    args = ap.parse_args()

    if args.integration:
        ok = integration(size=int(args.size))
        print("\nintegração:", "OK" if ok else "FALHOU")
        return

    os.makedirs(OUT, exist_ok=True)

    extra = {}
    if args.opts:
        for kv in args.opts.split(","):
            k, v = kv.split("=")
            extra[k] = v.lower() in ("true", "1", "yes") if v.lower() in ("true", "false", "1", "0", "yes", "no") else (int(v) if v.isdigit() else v)

    rows = []
    if args.real:
        for fn in sorted(os.listdir(args.real)):
            if not fn.lower().endswith((".png", ".bmp", ".gif")):
                continue
            path = os.path.join(args.real, fn)
            im = Image.open(path).convert("RGBA")
            arr = np.asarray(im).copy()
            opts = dict(tolerance=24, contiguous=True)
            opts.update(extra)
            t0 = time.time()
            out, report, dt = run_bgcore(arr, opts)
            name = os.path.splitext(fn)[0]
            save_triptych(name, arr, out, np.full(arr.shape[:2], IGNORE, np.uint8))
            pct = report.get("percent", 0)
            print(f"[real] {fn}: modelo={report.get('modelType')} removido={pct:.2f}% "
                  f"({report.get('removed')} px) em {dt:.2f}s")
            print(f"       {report.get('description')}")
            for w in warn_list(report):
                print("       AVISO:", w)
    else:
        size = int(args.size)
        for case in build_cases((size, size)):
            opts = dict(case["opts"])
            opts.update(extra)
            for k, v in list(opts.items()):
                if isinstance(v, (bool, np.bool_)):
                    opts[k] = bool(v)
            out, report, dt = run_bgcore(case["img"], opts)
            r = evaluate(case["name"], case["img"], out, case["gt"], dt, report)
            r["model"] = report.get("modelType")
            r["desc"] = report.get("description")
            r["warn"] = "; ".join(warn_list(report))
            rows.append(r)
            save_triptych(case["name"], case["img"], out, case["gt"])

        print(f"{'caso':<24}{'modelo':<12}{'fundo removido':>15}{'dano no sujeito':>17}{'tempo':>9}  status")
        print("-" * 90)
        for r in rows:
            print(f"{r['name']:<24}{str(r['model']):<12}{r['recall']:>14.2f}%"
                  f"{r['damage']:>16.2f}%{r['elapsed']:>8.2f}s  "
                  f"{'OK' if r['ok'] else 'FALHOU'}")
            if r["warn"]:
                print(f"    AVISO: {r['warn']}")
        print()
        for r in rows:
            print(f"* {r['name']} [{r['model']}]: {r['desc']}")

        nok = sum(1 for r in rows if r["ok"])
        print(f"\n{nok}/{len(rows)} casos OK -> imagens em {OUT}")


if __name__ == "__main__":
    main()
