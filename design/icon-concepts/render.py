"""Resize generated artwork and draw deterministic menu glyphs and review sheets.

Run: uv run --with pillow python design/icon-concepts/render.py
App artwork is generated, never drawn by this script. Glyphs use precise geometry.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
NAMES = {'quiet-cue': 'Quiet Cue', 'soft-reply': 'Soft Reply'}
IDEAS = {
    'quiet-cue': 'A teal script tile with a cue marker for the current talking point.',
    'soft-reply': 'An ivory speech bubble for prepared speech and quiet answer support.',
}


def glyph(name, size):
    # Work in 18-point coordinates and supersample only the vector-style glyph.
    scale = size * 8 / 18
    image = Image.new('RGBA', (size * 8, size * 8))
    d = ImageDraw.Draw(image)
    def rect(box, radius, fill):
        d.rounded_rectangle(tuple(v * scale for v in box), radius * scale, fill=fill)
    def poly(points, fill):
        d.polygon([(x * scale, y * scale) for x, y in points], fill=fill)
    if name == 'quiet-cue':
        rect((2, 4, 15, 7), 1.2, 'black')
        rect((2, 10, 12, 13), 1.2, 'black')
        poly([(14, 9.5), (17, 11.5), (14, 13.5)], 'black')
    else:
        rect((1, 2, 17, 14), 4, 'black')
        poly([(4, 12), (3, 17), (9, 13)], 'black')
        rect((4, 5, 14, 7), 1, (0, 0, 0, 0))
        rect((4, 9, 14, 11), 1, (0, 0, 0, 0))
    image = image.resize((size, size), Image.Resampling.LANCZOS)
    black = Image.new('RGBA', image.size)
    black.putalpha(image.getchannel('A'))
    return black


def svg(name):
    shapes = ('<rect x="2" y="4" width="13" height="3" rx="1.2"/>'
              '<rect x="2" y="10" width="10" height="3" rx="1.2"/>'
              '<path d="M14 9.5 17 11.5 14 13.5Z"/>') if name == 'quiet-cue' else (
              '<defs><mask id="lines"><rect width="18" height="18" fill="white"/>'
              '<rect x="4" y="5" width="10" height="2" rx="1" fill="black"/>'
              '<rect x="4" y="9" width="10" height="2" rx="1" fill="black"/>'
              '</mask></defs><g mask="url(#lines)">'
              '<rect x="1" y="2" width="16" height="12" rx="4"/>'
              '<path d="M4 12 3 17 9 13Z"/></g>')
    return '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18" fill="black">' + shapes + '</svg>\n'


for name, title in NAMES.items():
    folder = ROOT / name
    if not (folder / 'generated-source.png').exists():
        print(f'{name}: no generated-source.png, skipped')
        continue
    source = Image.open(folder / 'generated-source.png').convert('RGBA')
    assert source.width == source.height
    master = source.resize((1024, 1024), Image.Resampling.LANCZOS)
    for size in (1024, 128, 32, 16):
        master.resize((size, size), Image.Resampling.LANCZOS).save(folder / f'app-{size}.png')
    (folder / 'menu-template.svg').write_text(svg(name))
    for pt in (16, 18):
        for density in (1, 2):
            suffix = '' if density == 1 else '@2x'
            glyph(name, pt * density).save(folder / f'menu-{pt}pt{suffix}.png')

    sheet = Image.new('RGB', (1600, 1240), '#eef0f3')
    d = ImageDraw.Draw(sheet)
    font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 22)
    small = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 17)
    d.text((32, 22), f'{title} · TalkMargin · concept review', font=font, fill='#17232d')
    d.text((32, 61), IDEAS[name], font=small, fill='#46515b')
    sheet.paste(master, (24, 125), master)
    d.text((32, 1164), '1024 px · native pixels', font=small, fill='#46515b')
    for size, x, y in [(128, 1100, 125), (32, 1300, 125), (16, 1430, 125)]:
        icon = Image.open(folder / f'app-{size}.png')
        sheet.paste(icon, (x, y), icon)
        d.text((x, y + size + 16), f'{size} px', font=small, fill='#46515b')
    d.text((1100, 345), 'Menu templates · native sizes', font=small, fill='#17232d')
    for row, (pt, density) in enumerate([(16, 1), (18, 1), (16, 2), (18, 2)]):
        y = 390 + row * 160
        px = pt * density
        d.text((1100, y), f'{pt} pt @{density}x ({px} px)', font=small, fill='#46515b')
        for bar, color in [(0, '#f9fafb'), (1, '#24282f')]:
            x = 1100 + bar * 220
            d.rounded_rectangle((x, y + 35, x + 200, y + 105), radius=9, fill=color)
            icon = glyph(name, px)
            if bar:
                white = Image.new('RGBA', icon.size, 'white')
                white.putalpha(icon.getchannel('A'))
                icon = white
            sheet.paste(icon, (x + (200 - px)//2, y + 35 + (70 - px)//2), icon)
    d.text((1100, 1070), 'Dark bars simulate white template tint.', font=small, fill='#46515b')
    d.text((1100, 1100), 'View sheet at 100% for pixel comparison.', font=small, fill='#46515b')
    sheet.save(folder / 'contact-sheet.png')
    print(f'{name}: generated {source.size} -> master {master.size}; glyphs and sheet saved')
