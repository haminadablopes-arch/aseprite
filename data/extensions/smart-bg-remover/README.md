# Smart Background Remover v0.7.0

Aseprite extension that **recognizes the background pattern** and removes it from **all selected frames**, with a **live canvas preview** and layer reuse.

Current flow (v0.7.0):
- Only 2 layers: `Original` (hidden after processing) + `Original - removed` (always overwritten, never created again from scratch)
- **Live preview on the canvas for ALL selected frames**: when opened (Ctrl+Shift+B), every frame in the scope is processed and the result shows on the canvas — press **play** (or the dialog's ▶ button) to check the whole animation before confirming
- **No freezing**: while dragging a slider only the 1st frame is re-processed (instant); on release (onrelease) the whole batch is updated in ~50ms slices via Timer, keeping the UI responsive
- After confirming, applies to all selected frames **with no report dialog** (just hides the original and shows the processed one; undo with Ctrl+Z)
- Shortcut **Ctrl+Shift+B** opens the preview directly
- v0.7.0: fully translated to English (Portuguese labels/layer suffixes from older versions are still recognized)

## How to use

1. Select the frames on the timeline (or leave only the current frame active).
2. Press **Ctrl+Shift+B** or right-click the selection > **Remove Background (Ctrl+Shift+B)**
3. In the preview dialog, adjust (everything updates the canvas instantly):
   - **Detection**: Automatic, Solid color, Repeating pattern, Gradient, etc.
   - **Tolerance**: 0-128
   - **Soften edges**: 0-64
   - **Erase only areas connected to the borders**
   - **Also erase internal islands**
   - **Border sampling**: **Thickness** (1-32) and sides **Top / Bottom / Left / Right**
   - **Detect background in each frame on confirm**: checked = re-analyzes every frame (more accurate if the background changes), unchecked = uses the same model from the first frame for all (much faster). It also affects the preview.
4. The result shows **instantly on the canvas** for all frames.
5. Click **Apply to all** to keep the result. Or **Cancel** to restore the previous content.

The same item appears on the **cels** context menu (since v0.6.1: a single item straight on the popup, no submenu; the preview always opens with the options saved from the last run).

## What it recognizes

The core (`lib/bgcore.lua`) samples the border and classifies into:

| Model | When | How it decides |
|---|---|---|
| `flat` | one color dominates ≥80% of the border | matches that color |
| `tile` | repeating pattern (checkerboard, stripes, Bayer dither) | detects a 1x1 up to 16x16 tile and predicts the color by position `(x%P, y%Q)` |
| `gradient` | smooth variation | per-pixel plane fit (least squares) |
| `set` | complex/noisy background | set of main colors |
| `transparent` | border already transparent | nothing to do |

## Saved options

Tolerance, softening, mode, etc. are saved in `preferences.lua`. Since v0.5.1, **all** parameters (contiguous, islands, border thickness and sides) appear in the preview and any change updates the canvas immediately; on confirm everything is saved and reused the next time.

## Previewing all frames and performance

Measured cost per frame (Lua 5.5, checker border + subject):

| Size | analyze | process | total/frame |
|---|---|---|---|
| 64×64 | ~1.6ms | ~0.8ms | ~2.4ms |
| 256×256 | ~7ms | ~6ms | ~13ms |
| 512×512 | ~16ms | ~23ms | ~39ms |
| 1024×1024 | ~41ms | ~88ms | ~128ms |
| 2048×2048 | ~102ms | ~320ms | ~422ms |

To keep the UI smooth:

- **Slider drag** → re-processes only the 1st frame (instant response).
- **Slider release (onrelease), checkboxes and combobox** → updates the whole batch in ~50ms slices (Timer), with progress on the status ("Updating previews... 3/10 frames"). Between slices Aseprite gets to breathe (redraw, respond to clicks).
- **"Detect background in each frame on confirm" unchecked** → the 1st frame's model is analyzed once and reused for the others (saves each frame's analyze).
- **Linked cels** (frames sharing the same image) → processed once and propagated to every frame that uses them, in both the preview and the final confirmation.
- **Cancel** → restores the pre-preview content of every touched cel (or removes the ones created only for the preview).
- The **▶ Play animation** button runs Aseprite's own play with the previews applied; playing itself costs nothing beyond normal drawing (the cels are already processed).

## Layers

- Before: created `Name (backup)` + a new `Name` on every run.
- Now: creates `Name - removed` once and **always overwrites** the selected cels. The original is hidden (`isVisible=false`) after processing. Running again updates the same layer. A single undo reverts everything.

This avoids layer pollution and gives a clean preview.

## Shortcut

Defined in `keys.aseprite-keys`:
- `Ctrl+Shift+B` → `Remove Background (Ctrl+Shift+B)` (frames popup, cels popup and Edit menu)

You can change it in Edit > Keyboard Shortcuts.

## Performance

Raw-byte processing with memoized LUTs. ~0.5s per 2048×2048 frame on Lua 5.5. The preview processes the batch in slices, so it stays responsive even on large sprites.

## Files

```
smart-bg-remover/
  package.json           metadata + keys
  keys.aseprite-keys     Ctrl+Shift+B shortcut
  main.lua               commands, live preview, layer reuse
  lib/bgcore.lua         pure core (no Aseprite API)
  test/                  audit harness
```

## Tests

```bash
pip install numpy pillow lupa
python3 test/harness.py
python3 test/harness.py --size 2048
python3 test/harness.py --integration
```
