# Converts the lensfun XML database (CC-BY-SA 3.0) into a compact JSON for Emulsa.
# Own parser; no lensfun code. Usage: python3 -I convert.py <db dir> <out.json>
import sys, os, json, glob
import xml.etree.ElementTree as ET

db, out = sys.argv[1], sys.argv[2]
SKIP = ("compact-", "actioncams")
def num(s, d=0.0):
    try: return float(s)
    except (TypeError, ValueError): return d
def r(x): return float(f"{x:.6g}")

lenses = {}
for path in sorted(glob.glob(os.path.join(db, "*.xml"))):
    base = os.path.basename(path)
    if base.startswith(SKIP): continue
    root = ET.parse(path).getroot()
    for L in root.findall("lens"):
        maker = (L.findtext("maker") or "").strip()
        models = L.findall("model")
        model = next((m.text for m in models if m.get("lang") == "en"), None) or (models[0].text if models else "")
        model = (model or "").strip()
        typ = (L.findtext("type") or "rectilinear").strip()
        if typ != "rectilinear" or not model: continue
        crop = num(L.findtext("cropfactor"), 1.0)
        cal = L.find("calibration")
        if cal is None: continue
        d, t, v = [], [], []
        for e in cal.findall("distortion"):
            f, m = num(e.get("focal")), e.get("model")
            if m == "ptlens":
                a, b, c = num(e.get("a")), num(e.get("b")), num(e.get("c")); co = [1-a-b-c, c, b, a, 0]
            elif m == "poly3":
                k = num(e.get("k1")); co = [1-k, 0, k, 0, 0]
            elif m == "poly5":
                co = [1, 0, num(e.get("k1")), 0, num(e.get("k2"))]
            else: continue
            d.append([r(f)] + [r(x) for x in co])
        for e in cal.findall("tca"):
            f, m = num(e.get("focal")), e.get("model")
            if m == "linear":
                co = [num(e.get("kr"), 1), 0, 0, num(e.get("kb"), 1), 0, 0]
            elif m == "poly3":
                co = [num(e.get("vr"), 1), num(e.get("cr")), num(e.get("br")), num(e.get("vb"), 1), num(e.get("cb")), num(e.get("bb"))]
            else: continue
            t.append([r(f)] + [r(x) for x in co])
        for e in cal.findall("vignetting"):
            if e.get("model") != "pa": continue
            v.append([r(num(e.get("focal"))), r(num(e.get("aperture"))), r(num(e.get("distance"), 1000)),
                      r(num(e.get("k1"))), r(num(e.get("k2"))), r(num(e.get("k3")))])
        if not (d or t or v): continue
        fe = L.find("focal")
        focals = sorted({x[0] for x in d + t + v})
        fmin = num(fe.get("min") if fe is not None and fe.get("min") else (fe.get("value") if fe is not None else None), focals[0] if focals else 50)
        fmax = num(fe.get("max") if fe is not None and fe.get("max") else (fe.get("value") if fe is not None else None), focals[-1] if focals else 50)
        ae = L.find("aperture")
        amin = num(ae.get("min") if ae is not None else None, 0) or (min(x[1] for x in v) if v else 2.8)
        mounts = sorted({(m.text or "").strip() for m in L.findall("mount")} - {""})
        key = (maker.lower(), model.lower())
        entry = {"m": maker, "n": model, "mt": mounts, "c": r(crop), "f": [r(fmin), r(fmax)], "a": r(amin), "d": d, "t": t, "v": v}
        old = lenses.get(key)
        if old is None or crop < old["c"] - 0.01:
            lenses[key] = entry
        elif abs(crop - old["c"]) <= 0.01:
            for k in ("d", "t", "v"): old[k] += entry[k]
            old["mt"] = sorted(set(old["mt"]) | set(mounts))

items = sorted(lenses.values(), key=lambda e: (e["m"].lower(), e["n"].lower()))
with open(out, "w") as fp:
    json.dump({"source": "lensfun database (https://lensfun.github.io), CC BY-SA 3.0", "lenses": items}, fp, separators=(",", ":"))
ff = sum(1 for e in items if e["c"] <= 1.1)
print(len(items), "lenses;", ff, "full-frame or larger;", os.path.getsize(out), "bytes")
