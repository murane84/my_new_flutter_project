"""Build Aluta's Harmony fonts from Lora (SIL OFL 1.1).

Harmony (text cut)   – Regular 400 (sturdier: wght 430), Medium 500, Bold 700,
                       Italic 400. Taller x-height (+4%), a little more air
                       (+12 units per glyph), tabular digits by default,
                       hand-tuned Swahili + English pairs, music notes ♪ ♫.
Harmony Display      – SemiBold 600: Lora's elegance + heart tittles on i / j.
Soft (Nunito) and Easy read (Atkinson Hyperlegible) are subset only.

Reserved Font Name: "Lora" never appears in the new fonts' names.
"""
import copy
import os
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import otTables as ot
from fontTools.otlLib.builder import buildPairPosGlyphs, buildLookup
from fontTools.varLib import instancer

SRC = os.path.join(os.path.dirname(__file__), "src")
OUT = os.path.join(os.path.dirname(__file__), "out")
os.makedirs(OUT, exist_ok=True)

UNICODES = (
    list(range(0x20, 0x7F)) + list(range(0xA0, 0x180))
    + [0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026,
       0x20AC, 0x2122, 0x2190, 0x2192, 0x00B7, 0x266A, 0x266B, 0x2665]
)

XH_GROW = 0.04
AIR = 12  # units added to each advance (1.2% of the em)

SW_EN_PAIRS = [
    # Swahili
    "ng", "ny", "mw", "ch", "wa", "ku", "ki", "li", "me", "we", "ya", "za",
    "nd", "mb", "sh", "aw", "kw", "ji", "tu", "sa",
    # English
    "th", "he", "in", "er", "an", "re", "ou", "on", "at", "en",
    "To", "Ta", "Te", "Yo", "Ya", "Wa", "We", "AV", "AW", "LT", "Ty", "Vo",
    "rv", "ry", "f.", "r.", "y.", "v,", "w.",
]


def name_font(f, family, style, weight_cls, italic=False):
    full = family if style == "Regular" else f"{family} {style}"
    ps = (family.replace(" ", "") + "-" + style.replace(" ", ""))
    t = f["name"]
    keep = {}
    for rec in t.names:
        if rec.nameID in (0, 13, 14):
            keep[rec.nameID] = rec.toUnicode()
    t.names = []
    cp = (keep.get(0, "Copyright 2011 The Lora Project Authors "
          "(https://github.com/cyrealtype/Lora-Cyrillic)")
          + ". Harmony: modified by Ozilane (Aluta), 2026.")
    vals = {
        0: cp,
        1: family if style in ("Regular", "Italic", "Bold", "Bold Italic")
        else f"{family} {style.replace(' Italic', '')}",
        2: ("Italic" if italic else "Regular")
        if style not in ("Bold", "Bold Italic")
        else ("Bold Italic" if italic else "Bold"),
        3: f"1.000;OZLN;{ps}",
        4: full,
        5: "Version 1.000",
        6: ps,
        13: keep.get(13, "This Font Software is licensed under the SIL Open "
                     "Font License, Version 1.1."),
        14: keep.get(14, "https://openfontlicense.org"),
        16: family,
        17: style,
    }
    for nid, v in vals.items():
        t.setName(v, nid, 3, 1, 0x409)
    f["OS/2"].usWeightClass = weight_cls
    fs = f["OS/2"].fsSelection & ~0b1100001
    if italic:
        fs |= 1
    if style == "Regular":
        fs |= 0b1000000
    if "Bold" in style:
        fs |= 0b100000
    f["OS/2"].fsSelection = fs
    mac = 0
    if "Bold" in style:
        mac |= 1
    if italic:
        mac |= 2
    f["head"].macStyle = mac
    for tag in ("STAT", "fvar", "avar", "gvar", "HVAR", "MVAR"):
        if tag in f:
            del f[tag]


def instance(path, wght):
    f = TTFont(path)
    return instancer.instantiateVariableFont(f, {"wght": wght},
                                             updateFontNames=False)


def lowercase_glyphs(f):
    cm = f.getBestCmap()
    out = set()
    for cp, g in cm.items():
        ch = chr(cp)
        if ch.islower() or cp in (0x131, 0x237):
            out.add(g)
    return out


def grow_x_height(f, glyphs):
    glyf = f["glyf"]
    xh = f["OS/2"].sxHeight
    lift = xh * XH_GROW

    def y_of(y):
        if y <= 0:
            return y
        if y < xh + 12:
            return round(y * (1 + XH_GROW))
        return round(y + lift)

    for name in glyphs:
        g = glyf[name]
        if g.isComposite():
            # Marks sit on a taller body: raise the non-base components.
            for i, c in enumerate(g.components):
                if i > 0 and c.y > 0:
                    c.y = round(c.y + lift)
            continue
        if g.numberOfContours <= 0:
            continue
        coords = g.coordinates
        for i in range(len(coords)):
            x, y = coords[i]
            coords[i] = (x, y_of(y))
        g.recalcBounds(glyf)
    f["OS/2"].sxHeight = round(xh * (1 + XH_GROW))


def add_air(f):
    glyf = f["glyf"]
    hmtx = f["hmtx"]
    half = AIR // 2
    for name in f.getGlyphOrder():
        adv, lsb = hmtx[name]
        if adv == 0:
            continue
        g = glyf[name]
        hmtx[name] = (adv + AIR, lsb + half)
        if g.isComposite():
            continue  # its components move with them
        if g.numberOfContours > 0:
            coords = g.coordinates
            for i in range(len(coords)):
                x, y = coords[i]
                coords[i] = (x + half, y)
            g.recalcBounds(glyf)
    # composites: the base component already shifted → nothing to do.


def tabular_digits(f):
    for t in f["cmap"].tables:
        if not t.isUnicode():
            continue
        for cp, name in [(0x30 + i, n) for i, n in enumerate(
                ["zero", "one", "two", "three", "four", "five", "six",
                 "seven", "eight", "nine"])]:
            tf = name + ".tf"
            if cp in t.cmap and tf in f["glyf"].glyphs:
                t.cmap[cp] = tf


def _profile(f, name, side, bands):
    """Horizontal extent of a glyph in each y band (right or left edge)."""
    gs = f.getGlyphSet()
    pen = DecomposingRecordingPen(gs)
    gs[name].draw(pen)
    pts = []
    for op, args in pen.value:
        for p in args:
            pts.append(p)
    out = []
    for lo, hi in bands:
        xs = [x for x, y in pts if lo <= y < hi]
        if not xs:
            out.append(None)
        else:
            out.append(max(xs) if side == "R" else min(xs))
    return out


def kern_pairs(f):
    """Even out common Swahili / English lowercase pairs that Lora leaves
    unkerned: measure each pair's tightest gap (band by band, after Lora's
    own kerning) and nudge it gently toward the 'nn' / 'oo' rhythm.
    Pairs Lora already kerns, capitals and punctuation are left alone."""
    import io
    import uharfbuzz as hb
    buf = io.BytesIO()
    f.save(buf)
    face = hb.Face(buf.getvalue())
    font = hb.Font(face)
    cm = f.getBestCmap()
    hmtx = f["hmtx"]
    cap = f["OS/2"].sCapHeight
    bands = [(y, y + 50) for y in range(-200, cap + 50, 50)]

    def lora_kern(a, b):
        out = []
        for feats in ({"kern": True}, {"kern": False}):
            bb = hb.Buffer()
            bb.add_str(a + b)
            bb.guess_segment_properties()
            hb.shape(font, bb, feats)
            out.append(bb.glyph_positions[0].x_advance)
        return out[0] - out[1]

    def gap(a, b):
        ga, gb = cm.get(ord(a)), cm.get(ord(b))
        if not ga or not gb:
            return None
        ra = _profile(f, ga, "R", bands)
        lb = _profile(f, gb, "L", bands)
        adv = hmtx[ga][0] + lora_kern(a, b)
        ds = [(adv - r) + l for r, l in zip(ra, lb)
              if r is not None and l is not None]
        return min(ds) if ds else None

    ref = [gap(*p) for p in ("nn", "oo", "no", "on", "nu", "un")]
    ref = [r for r in ref if r is not None]
    target = sum(ref) / len(ref)
    pairs, shown = {}, {}
    for p in SW_EN_PAIRS:
        a, b = p[0], p[1]
        if not (a.islower() and b.islower()):
            continue
        if lora_kern(a, b) != 0:
            continue
        g = gap(a, b)
        if g is None:
            continue
        delta = max(-10, min(10, round((target - g) * 0.4)))
        if abs(delta) >= 3:
            pairs[(cm[ord(a)], cm[ord(b)])] = delta
            shown[p] = delta
    if not pairs:
        return {}
    vr = {}
    for k, d in pairs.items():
        v = ot.ValueRecord()
        v.XAdvance = d
        vr[k] = (v, None)
    subtables = buildPairPosGlyphs(vr, f.getReverseGlyphMap())
    lookup = buildLookup(subtables)
    gpos = f["GPOS"].table
    gpos.LookupList.Lookup.append(lookup)
    gpos.LookupList.LookupCount = len(gpos.LookupList.Lookup)
    idx = gpos.LookupList.LookupCount - 1
    for fr in gpos.FeatureList.FeatureRecord:
        if fr.FeatureTag == "kern":
            fr.Feature.LookupListIndex.append(idx)
            fr.Feature.LookupCount = len(fr.Feature.LookupListIndex)
    return shown


def _add_glyph(f, name, glyph, adv, cps):
    f["glyf"].glyphs[name] = glyph
    order = f.getGlyphOrder()
    if name not in order:
        order.append(name)
        f.setGlyphOrder(order)
    glyph.recalcBounds(f["glyf"])
    f["hmtx"][name] = (adv, glyph.xMin if hasattr(glyph, "xMin") else 0)
    for t in f["cmap"].tables:
        if t.isUnicode():
            for cp in cps:
                t.cmap[cp] = name


def _circle(pen, cx, cy, rx, ry, cw=False):
    k = 0.5523
    pts = [(cx + rx, cy), (cx, cy + ry), (cx - rx, cy), (cx, cy - ry)]
    if cw:
        pts = pts[::-1]
    pen.moveTo(pts[0])
    for i in range(4):
        a = pts[i]
        b = pts[(i + 1) % 4]
        if not cw:
            c1 = (a[0] - k * (a[1] - cy) * rx / ry, a[1] + k * (a[0] - cx) * ry / rx)
            c2 = (b[0] + k * (b[1] - cy) * rx / ry, b[1] - k * (b[0] - cx) * ry / rx)
        else:
            c1 = (a[0] + k * (a[1] - cy) * rx / ry, a[1] - k * (a[0] - cx) * ry / rx)
            c2 = (b[0] - k * (b[1] - cy) * rx / ry, b[1] + k * (b[0] - cx) * ry / rx)
        pen.curveTo(c1, c2, b)
    pen.closePath()


def _note_head(pen, cx, cy):
    # a slightly tilted oval head (as a quadratic-friendly cubic ellipse)
    _circle(pen, cx, cy, 118, 84, cw=True)


def music_notes(f, stem):
    """♪ and ♫ drawn in Harmony's soft style (round heads, gentle flag)."""
    from fontTools.pens.cu2quPen import Cu2QuPen
    w = stem
    # ♪
    tp = TTGlyphPen(f.getGlyphSet())
    pen = Cu2QuPen(tp, 1.0, reverse_direction=False)
    _note_head(pen, 240, 90)
    pen.moveTo((358 - w, 100))
    pen.lineTo((358 - w, 660))
    pen.lineTo((358, 660))
    pen.lineTo((358, 100))
    pen.closePath()
    # flag: a soft S curve down the right
    pen.moveTo((358 - w, 660))
    pen.curveTo((370, 580), (520, 560), (490, 380))
    pen.curveTo((485, 350), (470, 330), (458, 318))
    pen.curveTo((480, 430), (420, 490), (358, 510))
    pen.lineTo((358, 660))
    pen.closePath()
    _add_glyph(f, "musicnote", tp.glyph(), 600, [0x266A])
    # ♫
    tp = TTGlyphPen(f.getGlyphSet())
    pen = Cu2QuPen(tp, 1.0, reverse_direction=False)
    _note_head(pen, 170, 70)
    _note_head(pen, 560, 140)
    for x, y0, y1 in ((288, 80, 620), (678, 150, 690)):
        pen.moveTo((x - w, y0))
        pen.lineTo((x - w, y1))
        pen.lineTo((x, y1))
        pen.lineTo((x, y0))
        pen.closePath()
    # beam, gently rising
    pen.moveTo((288 - w, 620))
    pen.lineTo((678, 690))
    pen.lineTo((678, 580))
    pen.lineTo((288 - w, 510))
    pen.closePath()
    _add_glyph(f, "musicnotes", tp.glyph(), 800, [0x266B])


def _heart(pen, cx, cy, s):
    """A small heart centred at (cx, cy), about 2*s wide (clockwise for TT)."""
    pts = [
        ("M", (0, -1.05)),
        ("C", (-0.25, -0.75), (-1.0, -0.35), (-1.0, 0.25)),
        ("C", (-1.0, 0.75), (-0.45, 0.95), (0, 0.55)),
        ("C", (0.45, 0.95), (1.0, 0.75), (1.0, 0.25)),
        ("C", (1.0, -0.35), (0.25, -0.75), (0, -1.05)),
    ]

    def P(p):
        return (cx + p[0] * s, cy + p[1] * s)

    # draw counter-clockwise then reverse for TrueType's clockwise outers
    from fontTools.pens.reverseContourPen import ReverseContourPen
    rp = ReverseContourPen(pen)
    for item in pts:
        if item[0] == "M":
            rp.moveTo(P(item[1]))
        else:
            rp.curveTo(P(item[1]), P(item[2]), P(item[3]))
    rp.closePath()


def heart_tittles(f):
    """Display cut: the dot on i and j becomes a little heart."""
    from fontTools.pens.cu2quPen import Cu2QuPen
    gs = f.getGlyphSet()
    xh = f["OS/2"].sxHeight
    for base, dotless in (("i", "dotlessi"), ("j", "uni0237")):
        if dotless not in f["glyf"].glyphs:
            continue
        # where the original dot sits
        rec = DecomposingRecordingPen(gs)
        gs[base].draw(rec)
        pts = [p for _, args in rec.value for p in args if p[1] > xh + 40]
        if not pts:
            continue
        x0 = min(p[0] for p in pts)
        x1 = max(p[0] for p in pts)
        y0 = min(p[1] for p in pts)
        y1 = max(p[1] for p in pts)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        size = max(x1 - x0, y1 - y0) * 0.78
        cy -= size * 0.12
        tp = TTGlyphPen(gs)
        # copy the dotless body
        gs[dotless].draw(tp)
        pen = Cu2QuPen(tp, 1.0, reverse_direction=False)
        _heart(pen, cx, cy, size)
        g = tp.glyph()
        f["glyf"].glyphs[base] = g
        g.recalcBounds(f["glyf"])


def subset(f, extra_glyphs=()):
    opts = Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.name_languages = ["*"]
    opts.notdef_outline = True
    opts.glyph_names = False
    opts.hinting = False
    opts.drop_tables += ["DSIG"]
    s = Subsetter(opts)
    s.populate(unicodes=UNICODES, glyphs=list(extra_glyphs))
    s.subset(f)


def tf_glyphs(f):
    return [n + ".tf" for n in ("zero", "one", "two", "three", "four",
                                "five", "six", "seven", "eight", "nine")
            if n + ".tf" in f.getGlyphOrder()]


def build_text(src, wght, style, weight_cls, italic, out):
    f = instance(src, wght)
    low = lowercase_glyphs(f)
    grow_x_height(f, low)
    add_air(f)
    tabular_digits(f)
    pairs = kern_pairs(f)
    stem = 72 if wght < 600 else 96
    music_notes(f, stem)
    name_font(f, "Harmony", style, weight_cls, italic)
    subset(f)
    f.save(out)
    return pairs


def build_display(src, wght, out):
    f = instance(src, wght)
    heart_tittles(f)
    music_notes(f, 96)
    name_font(f, "Harmony Display", "SemiBold", 600)
    subset(f)
    f.save(out)


def plain(src, wght, family, style, weight_cls, out, rename=False):
    f = instance(src, wght) if wght else TTFont(src)
    subset(f)
    f.save(out)


if __name__ == "__main__":
    lora = os.path.join(SRC, "lora_Lora[wght].ttf")
    lora_i = os.path.join(SRC, "lora_Lora-Italic[wght].ttf")
    p = build_text(lora, 430, "Regular", 400, False, f"{OUT}/Harmony-Regular.ttf")
    print("pairs", p)
    build_text(lora, 520, "Medium", 500, False, f"{OUT}/Harmony-Medium.ttf")
    # Dark mode: light text on dark reads thinner, so a hair heavier.
    build_text(lora, 470, "Regular", 400, False, f"{OUT}/HarmonyDark-Regular.ttf")
    build_text(lora, 700, "Bold", 700, False, f"{OUT}/Harmony-Bold.ttf")
    build_text(lora_i, 430, "Italic", 400, True, f"{OUT}/Harmony-Italic.ttf")
    build_display(lora, 600, f"{OUT}/HarmonyDisplay-SemiBold.ttf")
    nun = os.path.join(SRC, "nunito_Nunito[wght].ttf")
    plain(nun, 400, "Nunito", "Regular", 400, f"{OUT}/Nunito-Regular.ttf")
    plain(nun, 700, "Nunito", "Bold", 700, f"{OUT}/Nunito-Bold.ttf")
    plain(os.path.join(SRC, "atkinsonhyperlegible_AtkinsonHyperlegible-Regular.ttf"),
          None, "", "", 400, f"{OUT}/AtkinsonHyperlegible-Regular.ttf")
    plain(os.path.join(SRC, "atkinsonhyperlegible_AtkinsonHyperlegible-Bold.ttf"),
          None, "", "", 700, f"{OUT}/AtkinsonHyperlegible-Bold.ttf")
    for n in sorted(os.listdir(OUT)):
        print(n, os.path.getsize(os.path.join(OUT, n)))
