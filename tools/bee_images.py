"""Generate one icon per bee species from the mod textures and the species
colours in the mod sources, the way Forestry renders them in game:

    outline tinted with the primary colour
  + body tinted with the secondary colour
  + untinted detail layer on top

Outputs
  docs/bees/<uid>.png        princess icon, 64x64 (uid with non-alphanumerics -> _)
  docs/bees/<uid>_drone.png  drone icon
  src/species_uids.lua       display name -> uid, for species the survey has no uid for

Usage
  python tools/bee_images.py [--mods "<path to .minecraft/mods>"] [--out docs/bees]

Textures come from the Forestry, Magic Bees and Binnie jars of your modpack
(a PrismLauncher GTNH instance is found automatically). Colours and names come
from the GTNH fork sources on GitHub; downloaded files are cached in tools/cache.
"""
import argparse
import glob
import io
import os
import re
import sys
import urllib.request
import zipfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "tools", "cache")

SOURCES = {
    "forestry_def": "https://raw.githubusercontent.com/GTNewHorizons/ForestryMC/master/src/main/java/forestry/apiculture/genetics/BeeDefinition.java",
    "forestry_lang": "https://raw.githubusercontent.com/GTNewHorizons/ForestryMC/master/src/main/resources/assets/forestry/lang/en_US.lang",
    "extrabees_def": "https://raw.githubusercontent.com/GTNewHorizons/Binnie/master/src/main/java/binnie/extrabees/genetics/ExtraBeeDefinition.java",
    "extrabees_lang": "https://raw.githubusercontent.com/GTNewHorizons/Binnie/master/src/main/resources/assets/extrabees/lang/en_US.lang",
    "magicbees_def": "https://raw.githubusercontent.com/GTNewHorizons/MagicBees/master/src/main/java/magicbees/bees/BeeSpecies.java",
    "magicbees_lang": "https://raw.githubusercontent.com/GTNewHorizons/MagicBees/master/src/main/resources/assets/magicbees/lang/en_US.lang",
    "gt_def": "https://raw.githubusercontent.com/GTNewHorizons/GT5-Unofficial/master/src/main/java/gregtech/loaders/misc/GTBeeDefinition.java",
}
FORESTRY_TEXTURE_BASE = "https://raw.githubusercontent.com/GTNewHorizons/ForestryMC/master/src/main/resources/assets/forestry/textures/items/bees/default/"

# Magic Bees species drawn with their own icon sets (from BeeSpecies.getCustomIconProvider)
MAGICBEES_SKULKING = {
    "SKULKING", "GHASTLY", "SPIDERY", "SMOULDERING", "BIGBAD", "BATTY", "SHEEPISH", "HORSE", "CATTY", "BRAINY",
    "TC_WISPY", "AM_VORTEX", "AM_WIGHT", "TE_BLIZZY", "TE_GELID", "TE_DANTE", "TE_PYRO", "TE_SHOCKING", "TE_AMPED",
    "TE_GROUNDED", "TE_ROCKING",
}
MAGICBEES_DOCTORAL = {"DOCTORAL"}
MAGICBEES_BODY = {  # BeeSpecies.BodyColours
    "DEFAULT": 0xFF7C26, "ARCANE": 0xFF9D60, "ABOMINABLE": 0x960F00, "EXTRINSIC": 0xF696FF, "SKULKING": 0xE15236,
    "THAUMCRAFT_SHARD": 0x999999, "THAUMCRAFT_NODE": 0x675ED1, "ARSMAGICA": 0xE3A55B, "BOTANIA": 0xFFB2BB,
}


def fetch(key):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, key)
    if not os.path.exists(path):
        print("  downloading", key)
        req = urllib.request.Request(SOURCES[key], headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=60) as r, open(path, "wb") as f:
            f.write(r.read())
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def parse_lang(text):
    out = {}
    for line in text.splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def capitalize(s):
    return s[:1].upper() + s[1:]


# ----------------------------------------------------------------------------
# species tables: list of dicts { mod, enum, uid, name, primary, secondary, iconset }
# ----------------------------------------------------------------------------
def parse_forestry(text, lang):
    pat = re.compile(r'^\s*([A-Z_0-9]+)\(BeeBranchDefinition\.[A-Z_]+,\s*"[^"]*",\s*(?:true|false),\s*new Color\((0x[0-9a-fA-F]+)\),\s*new Color\((0x[0-9a-fA-F]+)\)', re.M)
    out = []
    for enum, p, s in pat.findall(text):
        lower = enum.lower()
        out.append({"mod": "forestry", "enum": enum, "uid": "forestry.species" + capitalize(lower),
                    "name": lang.get("for.bees.species." + lower, capitalize(lower)),
                    "primary": int(p, 16), "secondary": int(s, 16), "iconset": "default"})
    return out


def parse_extrabees(text, lang):
    pat = re.compile(r'^\s*([A-Z_0-9]+)\(ExtraBeeBranchDefinition\.[A-Z_]+,\s*"[^"]*",\s*(?:true|false),\s*new Color\((0x[0-9a-fA-F]+)\),\s*new Color\((0x[0-9a-fA-F]+)\)', re.M)
    out = []
    for enum, p, s in pat.findall(text):
        lower = enum.lower()
        out.append({"mod": "extrabees", "enum": enum, "uid": "extrabees.species." + lower,
                    "name": lang.get("extrabees.species." + lower + ".name", capitalize(lower)),
                    "primary": int(p, 16), "secondary": int(s, 16), "iconset": "default"})
    return out


def parse_magicbees(text, lang):
    pat = re.compile(r'^\s*([A-Z_0-9]+)\("([^"]+)",\s*"[^"]*",\s*BeeClassification\.[A-Z_]+,\s*(0x[0-9a-fA-F]+),\s*(?:(BodyColours\.[A-Z_]+|0x[0-9a-fA-F]+),)?', re.M)
    out = []
    for enum, species, p, sec in pat.findall(text):
        if sec.startswith("BodyColours."):
            s = MAGICBEES_BODY.get(sec.split(".")[1], MAGICBEES_BODY["DEFAULT"])
        elif sec:
            s = int(sec, 16)
        else:
            s = MAGICBEES_BODY["DEFAULT"]
        iconset = "skulking" if enum in MAGICBEES_SKULKING else ("doctoral" if enum in MAGICBEES_DOCTORAL else "default")
        out.append({"mod": "magicbees", "enum": enum, "uid": "magicbees.species" + species,
                    "name": lang.get("magicbees.species" + species, species),
                    "primary": int(p, 16), "secondary": s, "iconset": iconset})
    return out


def parse_gt(text, lang):
    pat = re.compile(r'^\s*([A-Z_0-9]+)\(GTBranchDefinition\.[A-Z_]+,\s*"([^"]+)",\s*(?:true|false),\s*new Color\((0x[0-9a-fA-F]+)\),\s*new Color\((0x[0-9a-fA-F]+)\)', re.M | re.S)
    out = []
    for enum, inline, p, s in pat.findall(text):
        lower = enum.lower()
        # GT registers "for.bees.species.<lower>" with the inline name as the English default
        name = lang.get("for.bees.species." + lower) or re.sub(r"(?<=[a-z])(?=[A-Z])", " ", inline)
        out.append({"mod": "gregtech", "enum": enum, "uid": "gregtech.bee.species" + capitalize(lower),
                    "name": name, "primary": int(p, 16), "secondary": int(s, 16), "iconset": "default"})
    return out


# ----------------------------------------------------------------------------
# textures
# ----------------------------------------------------------------------------
def find_mods_dir(explicit):
    if explicit:
        return explicit
    appdata = os.environ.get("APPDATA", "")
    candidates = glob.glob(os.path.join(appdata, "PrismLauncher", "instances", "*", ".minecraft", "mods", "Forestry-*.jar"))
    candidates += glob.glob(os.path.join(appdata, ".minecraft", "mods", "Forestry-*.jar"))
    if not candidates:
        return None
    candidates.sort(key=os.path.getmtime, reverse=True)
    return os.path.dirname(candidates[0])


def load_textures(mods_dir):
    """Returns { iconset: { 'body1': img, 'princess.outline': img, ... } } of 16x16 RGBA frames."""
    sets = {}

    def add(iconset, fname, data):
        im = Image.open(io.BytesIO(data)).convert("RGBA")
        frame = im.crop((0, 0, 16, 16)) if im.size[1] > 16 else im
        sets.setdefault(iconset, {})[fname[:-4]] = frame

    jars = {}
    if mods_dir:
        for prefix, pattern in (("forestry", "Forestry-*.jar"), ("magicbees", "magicbees-*.jar"), ("extrabees", "binnie-mods-*.jar")):
            found = glob.glob(os.path.join(mods_dir, pattern))
            if found:
                jars[prefix] = found[0]
    for prefix, jar in jars.items():
        z = zipfile.ZipFile(jar)
        base = "assets/%s/textures/items/bees/" % prefix
        for name in z.namelist():
            if name.startswith(base) and name.endswith(".png"):
                rest = name[len(base):]
                if "/" in rest:
                    iconset, fname = rest.split("/", 1)
                    add(iconset, fname, z.read(name))
        print("  textures from", os.path.basename(jar))
    if "default" not in sets:
        print("  no Forestry jar found, downloading the default icon set from GitHub")
        for fname in ("body1.png", "princess.outline.png", "princess.body2.png", "drone.outline.png", "drone.body2.png",
                      "queen.outline.png", "queen.body2.png"):
            req = urllib.request.Request(FORESTRY_TEXTURE_BASE + fname, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=60) as r:
                add("default", fname, r.read())
    return sets


def tint(img, color):
    r, g, b = (color >> 16) & 255, (color >> 8) & 255, color & 255
    out = img.copy()
    px = out.load()
    for y in range(out.size[1]):
        for x in range(out.size[0]):
            pr, pg, pb, pa = px[x, y]
            px[x, y] = (pr * r // 255, pg * g // 255, pb * b // 255, pa)
    return out


def render(textures, kind, primary, secondary, scale=4):
    outline = textures[kind + ".outline"]
    body1 = textures["body1"]
    body2 = textures[kind + ".body2"]
    img = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
    img.alpha_composite(tint(outline, primary))
    img.alpha_composite(tint(body1, secondary))
    img.alpha_composite(body2)
    return img.resize((16 * scale, 16 * scale), Image.NEAREST)


def safe(uid):
    return re.sub(r"[^A-Za-z0-9]", "_", uid)


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mods", help="path to a .minecraft/mods folder")
    ap.add_argument("--out", default=os.path.join(ROOT, "docs", "bees"))
    args = ap.parse_args()

    print("sources")
    langs = {
        "forestry": parse_lang(fetch("forestry_lang")),
        "extrabees": parse_lang(fetch("extrabees_lang")),
        "magicbees": parse_lang(fetch("magicbees_lang")),
    }
    mods_dir = find_mods_dir(args.mods)
    gt_lang = {}
    if mods_dir:
        gt_jars = glob.glob(os.path.join(mods_dir, "gregtech-*.jar"))
        if gt_jars:
            z = zipfile.ZipFile(gt_jars[0])
            for name in z.namelist():
                if name.endswith("assets/gregtech/lang/en_US.lang"):
                    gt_lang = parse_lang(z.read(name).decode("utf-8", "replace"))
    species = []
    species += parse_forestry(fetch("forestry_def"), langs["forestry"])
    species += parse_extrabees(fetch("extrabees_def"), langs["extrabees"])
    species += parse_magicbees(fetch("magicbees_def"), langs["magicbees"])
    species += parse_gt(fetch("gt_def"), gt_lang)

    print("textures", "from", mods_dir or "GitHub")
    sets = load_textures(mods_dir)

    os.makedirs(args.out, exist_ok=True)
    counts = {}
    names = {}
    for sp in species:
        textures = sets.get(sp["iconset"]) or sets["default"]
        for kind, suffix in (("princess", ""), ("drone", "_drone")):
            if kind + ".outline" not in textures:
                textures = sets["default"]
            render(textures, kind, sp["primary"], sp["secondary"]).save(os.path.join(args.out, safe(sp["uid"]) + suffix + ".png"), optimize=True)
        counts[sp["mod"]] = counts.get(sp["mod"], 0) + 1
        names.setdefault(sp["name"], []).append(sp)

    dupes = {n: v for n, v in names.items() if len(v) > 1}
    with open(os.path.join(ROOT, "src", "species_uids.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("-- Generated by tools/bee_images.py: species display name -> allele uid.\n")
        f.write("-- Used for catalog numbering of hive-only species and for icon lookups.\n")
        f.write("return {\n")
        for name in sorted(names):
            sp = names[name][0]
            f.write("  [%s] = %s,\n" % (lua_string(name), lua_string(sp["uid"])))
        f.write("}\n")

    print("species per mod:", ", ".join("%s %d" % kv for kv in sorted(counts.items())))
    print("icons written to", args.out, "(%d species, %d files)" % (len(species), len(species) * 2))
    if dupes:
        print("display names shared by several mods (the first one wins in species_uids.lua):")
        for n, v in sorted(dupes.items()):
            print("   %s: %s" % (n, ", ".join(s["uid"] for s in v)))


if __name__ == "__main__":
    sys.exit(main())
