# TalkMargin final icon assets

Selected design: the indigo tile with an ivory speech bubble (`design/icon-concepts/soft-reply/`, internal label only). Concepts stay in `design/icon-concepts/`.

## Files

- `Resources/AppIcon-1024.png`: app icon master, 1024 x 1024 RGBA, sRGB tagged. Tile 824 px at 100 px, continuous corners (radius 185.4), transparent outside.
- `Resources/AppIcon.icns`: 16, 32, 128, 256, 512 pt at @1x and @2x (16 to 1024 px, ten images).
- `Resources/MenuBarIconTemplate.pdf`: single-page vector, 18 x 18 pt, black, no raster objects.
- `Resources/MenuBarIconTemplate.png` (18 px), `MenuBarIconTemplate@2x.png` (36 px): black on transparent.
- `design/final/MenuBarIconTemplate.svg`: glyph master. Generated; edit `src/menu-glyph.swift`, not the SVG.
- Contact sheet: `src/build.sh` generates `design/final/contact-sheet.png` (icns images at native pixels; glyph at 16/18 pt @1x/@2x on light and dark bars). Our artwork only, no Apple symbols. Offline composite, not a device capture.

## Rebuild

```
design/final/src/build.sh
```

`SF_COMPARE=1` also writes `design/final/build/contact-sheet-sf-compare.png` with SF Symbols in the bars, for local size checks. It contains Apple artwork: git ignores `build/`; never commit or publish it.

It builds the icns with `scripts/make-icns.sh`; set `MAKE_ICNS` to use another copy. Pixels are reproducible; PDF timestamps and PNG compression bytes may differ. Needs Swift and Python 3 with Pillow and NumPy.

- `tile-mask.swift`: grid mask via `CALayer` with `cornerCurve = .continuous`.
- `app-icon.py`: scales the generated tile (`generated-source.png`) to the grid. It then warps only the outer rim (beyond 85% of the radius) so the art's own edge lands on the mask. Interior untouched, stray specks dropped.
- `menu-glyph.swift`: one geometry, written out as SVG, PDF and both PNGs. Body x 1-17, y 1-15; line cutouts on whole pixels (y 5-7, 9-11), so @1x and @2x are crisp.
- `contact-sheet.swift`: public sheet; `--sf-compare` for the local comparison.

## macOS 26 presentation

The tile keeps its own margins on the standard grid; no full-bleed artwork.

- Apple asks for square, unmasked art for Icon Composer layers ([HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)). A legacy .icns that doesn't fit the system shape is shrunk onto a gray plate ([Apple forums](https://developer.apple.com/forums/thread/797971), [heise](https://heise.de/-11075561), [Michael Tsai](https://mjtsai.com/blog/2025/11/11/tahoes-terrible-icons/)).
- Local test on macOS 26.6.2: scratch bundles, Finder icon read with `NSWorkspace.icon(forFile:)`.
  - Original generated art (off-grid 862 x 844 tile): plated.
  - This master on the 824 grid: unplated, full size.
  - Opaque full-bleed square: unplated, but the art's own rim then shows inside the system mask as a double edge.

## Menu glyph size

Measured locally, not shown in any committed image. Ink is 16 x 16 px at 18 pt, about the same as SF `bubble.left.fill` at 15 pt (17 x 16). At 16 pt the ink is about 14 x 14, matching the symbol at 13 pt, the menu-bar font size (13 x 14). The bar is 22 pt high. Use the image at 18 x 18 pt. The `Template` name suffix marks it as a template when loaded by name; set `isTemplate` if loaded by URL.

## Tradeoffs

- Corner rim warped by up to 3.6% so the corners follow the system shape. Tile resampled to a square: about 2% stretch in one direction.
- A legacy .icns gets none of the Liquid Glass effects or custom dark, clear and tinted variants; macOS derives those. An Icon Composer `.icon` would need the art split into layers.
- The glyph's 16 pt rendering is scaled from the 18 pt grid, so its edges are softer than at 18 pt.
