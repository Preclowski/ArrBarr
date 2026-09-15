#!/usr/bin/env python3
"""Pack per-operation fixture files into one JSON per service kind (and back).

Recordings land as `<dir>/<kind>/<op>.json` + `<op>.meta.json` (scratchpad, then
anonymize_fixtures.py). The repo ships `Packages/MediaKit/Sources/MediaKit/Fixtures/<kind>.json`:
{ "<op>": { "status": int, "headers": {..}, "body": <json>, "synthetic": bool } }.

  pack_fixtures.py pack   <unpacked-dir> [--out <packed-dir>]
  pack_fixtures.py unpack <packed-dir>   [--out <unpacked-dir>]
"""
import argparse, glob, json, os, sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PACKED = os.path.join(REPO, "Packages", "MediaKit", "Sources", "MediaKit", "Fixtures")
KEEP_HEADERS = {"content-type", "x-application-version", "x-transmission-session-id"}


def pack(src, out):
    os.makedirs(out, exist_ok=True)
    for kind in sorted(os.listdir(src)):
        kdir = os.path.join(src, kind)
        if not os.path.isdir(kdir):
            continue
        packed = {}
        for path in sorted(glob.glob(os.path.join(kdir, "*.json"))):
            name = os.path.basename(path)[:-5]
            if name.endswith(".meta"):
                continue
            meta_path = os.path.join(kdir, name + ".meta.json")
            meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
            with open(path) as f:
                raw = f.read()
            try:
                body = json.loads(raw)
            except ValueError:
                body = raw  # non-JSON bodies (XML-RPC, "Ok.") stay strings
            headers = {k: v for k, v in meta.get("headers", {}).items() if k.lower() in KEEP_HEADERS}
            entry = {"status": meta.get("status", 200), "headers": headers, "body": body}
            if meta.get("synthetic"):
                entry["synthetic"] = True
            packed[name] = entry
        with open(os.path.join(out, kind + ".json"), "w") as f:
            json.dump(packed, f, indent=1, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"{kind}: {len(packed)} operations")


def unpack(src, out):
    for path in sorted(glob.glob(os.path.join(src, "*.json"))):
        kind = os.path.basename(path)[:-5]
        kdir = os.path.join(out, kind)
        os.makedirs(kdir, exist_ok=True)
        for name, entry in json.load(open(path)).items():
            body = entry["body"]
            with open(os.path.join(kdir, name + ".json"), "w") as f:
                if isinstance(body, str):
                    f.write(body)
                else:
                    json.dump(body, f, indent=1, sort_keys=True, ensure_ascii=False)
            meta = {"status": entry["status"], "headers": entry["headers"], "operation": name}
            if entry.get("synthetic"):
                meta["synthetic"] = True
            json.dump(meta, open(os.path.join(kdir, name + ".meta.json"), "w"), indent=1, sort_keys=True)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=["pack", "unpack"])
    p.add_argument("src")
    p.add_argument("--out")
    a = p.parse_args()
    if a.mode == "pack":
        pack(a.src, a.out or PACKED)
    else:
        unpack(a.src, a.out or os.path.join(REPO, "Packages", "MediaKit", "Fixtures"))


if __name__ == "__main__":
    main()
