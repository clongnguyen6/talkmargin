# TalkMargin icon concepts

Exploration record. Soft Reply was selected; the final assets and their build are in [../final/](../final/README.md).

- Quiet Cue: teal reading lines and a cue triangle for the current talking point. More specific to prompting; the triangle becomes tiny at 16 px.
- Soft Reply: an ivory speech bubble for prepared speech and private question support. Strong small silhouette; more generic to chat apps.

App artwork: built-in `image_gen.imagegen`, one generation per concept; the tool did not expose a model name. Per embedded C2PA manifest (in each concept's `generated-source.png`, signature not validated): created by softwareAgent `ChatGPT`, version `gpt-image`; claim generator `OpenAI Media Service API`; digitalSourceType `trainedAlgorithmicMedia`. Verbatim prompts for both concepts and the manifest fields: [prompts.json](prompts.json). The generated originals are 1254 x 1254 RGBA PNGs. Pillow Lanczos resizing produces exact 1024 x 1024 masters and smaller previews, preserving alpha. Generated edges and shadows remain concept quality.

Menu templates: precise geometry in [render.py](render.py), using Pillow supersampling; editable equivalent SVGs. All PNG color channels are black, with transparency carrying the silhouette. The two reading lines are cutouts in Soft Reply. PNGs are named by logical point size; @2x has twice the pixel dimensions.

Contact sheets show each app PNG at native 1024, 128, 32 and 16 pixels and the menu samples at 16 and 18 pt, both densities, on light and dark bars (dark samples simulate white template tint). Offline composites, not device captures.

Regenerate derivatives: `uv run --with pillow python design/icon-concepts/render.py`. It processes each concept folder that has a `generated-source.png` and skips the rest; no image API. Pillow 13.0.0 used originally. Requires macOS Helvetica for sheet labels.

## Files

The published tree keeps only the selected concept's generated source and glyph, plus the prompts and this tooling:

- `soft-reply/generated-source.png`: unmodified generated image, 1254 x 1254, with its C2PA manifest.
- `soft-reply/menu-template.svg`: editable black glyph, 18 x 18 viewBox.
- `prompts.json`, `render.py`, this README.

The development tree also has `quiet-cue/` with the same layout, and in each concept folder the outputs of `render.py` (published tree: run it to recreate them for Soft Reply):

| File | Purpose / dimensions |
| --- | --- |
| app-1024.png | App icon master, 1024 x 1024 |
| app-128.png, app-32.png, app-16.png | App previews |
| menu-16pt.png, menu-16pt@2x.png | Black transparent template, 16 pt at @1x and @2x |
| menu-18pt.png, menu-18pt@2x.png | Black transparent template, 18 pt at @1x and @2x |
| contact-sheet.png | Review sheet, 1600 x 1240 |
