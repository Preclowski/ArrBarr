#!/usr/bin/env python3
"""Give the demo a real open-licensed library: run after anonymize_fixtures.py + pack_fixtures.py.

Renames the anonymizer's "Open Movie N" / "Open Series N" / "Open Artist N" / "Open Album N"
placeholders to titles from demo_catalogue.json (Blender open movies, public-domain films,
CC music), points their artwork at the real posters/covers, and tops the library lists up
with the rest of the catalogue. Edits the packed fixtures in place; safe to re-run.
"""
import copy, json, os, re
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PACKED = os.path.join(HERE, "..", "..", "Packages", "MediaKit", "Sources", "MediaKit", "Fixtures")
KINDS = ["radarr", "sonarr", "lidarr", "qbittorrent", "sabnzbd"]
# Library ops first: they get the catalogue's first (best-known) titles.
PRIORITY = {
    "radarr": ["fetchallmovies", "fetchcalendar", "fetchqueue", "fetchqueue-api-v3-moviefile",
               "fetchhistory", "fetchhistoryformovie", "search-lookup"],
    "sonarr": ["fetchallseries", "fetchcalendar", "fetchqueue", "fetchhistory",
               "fetchhistoryforseries", "fetchqueue-api-v3-episodefile", "search-lookup"],
    "lidarr": ["fetchallartists", "fetchartistalbums", "fetchcalendar", "fetchqueue",
               "fetchhistory", "search-lookup", "search-lookup-api-v1-search"],
}
PLACEHOLDER = re.compile(r"Open[ .](Movie|Series|Artist|Album)[ .](\d+)\b")


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def clean(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def main():
    cat = json.load(open(os.path.join(HERE, "demo_catalogue.json")))
    files = {k: json.load(open(os.path.join(PACKED, k + ".json"))) for k in KINDS}
    albums_of = {a["name"]: [x["title"] for x in a["albums"]] for a in cat["artists"]}
    pools = {
        "Movie": [m["title"] for m in cat["movies"]],
        "Series": [s["title"] for s in cat["series"]],
        "Artist": [a["name"] for a in cat["artists"]],
        "Album": [x["title"] for a in cat["artists"] for x in a["albums"]],
    }
    art = {}
    for m in cat["movies"] + cat["series"]:
        art[slug(m["title"])] = m["poster"]
    for a in cat["artists"]:
        art[slug(a["name"])] = a["poster"]
        for x in a["albums"]:
            art[slug(x["title"])] = x["cover"]

    # Placeholders in priority order, then everything else in the file.
    order = []
    for kind in KINDS:
        ops = PRIORITY.get(kind, []) + sorted(files[kind])
        for op in ops:
            if op in files[kind]:
                for t, n in PLACEHOLDER.findall(json.dumps(files[kind][op]["body"])):
                    if (t, n) not in order:
                        order.append((t, n))
    used = {t: {v for v in pool if any(v in json.dumps(f) for f in files.values())} for t, pool in pools.items()}
    mapping = {}
    for t, n in order:
        free = [v for v in pools[t] if v not in used[t]]
        if free:
            mapping[(t, n)] = free[0]
            used[t].add(free[0])
        elif t == "Series":
            # Seven shows cover every episode: the calendar and history repeat them, as they would.
            mapping[(t, n)] = pools[t][len(mapping) % len(pools[t])]
        # Any other long tail (alternate titles, search results) stays a placeholder.
    # The anonymizer named some episode releases after a movie; they belong to their series.
    shows = {e["id"]: e["title"] for e in files["sonarr"]["fetchallseries"]["body"]}
    for rec in files["sonarr"]["fetchqueue"]["body"]["records"]:
        m = PLACEHOLDER.search(rec["title"])
        if m and m.group(1) == "Movie":
            owner = PLACEHOLDER.fullmatch(shows.get(rec["seriesId"], ""))
            mapping[("Movie", m.group(2))] = mapping.get(owner.groups(), pools["Series"][0]) if owner else pools["Series"][0]

    def rename(text):
        for (t, n), title in sorted(mapping.items(), key=lambda kv: -len(kv[0][1])):
            forms = [(f"Open {t} {n}", title), (f"Open.{t}.{n}", re.sub(r"[^A-Za-z0-9]+", ".", title).strip(".")),
                     (f"open-{t.lower()}-{n}", slug(title)), (f"open{t.lower()}{n}", clean(title)),
                     (f"open {t.lower()} {n}", title.lower())]
            for old, new in forms:
                text = re.sub(re.escape(json.dumps(old)[1:-1]) + r"(?!\d)", json.dumps(new)[1:-1].replace("\\", "\\\\"), text)
        # Release names carried the placeholder's random year.
        for m in cat["movies"]:
            dotted = re.escape(re.sub(r"[^A-Za-z0-9]+", ".", m["title"]).strip("."))
            text = re.sub(r"\b(%s)\.(19|20)\d{2}\b" % dotted, r"\g<1>.%d" % m["year"], text)
        return text

    def fix_art(text):
        def repl(m):
            s, cover = m.group(2), m.group(3)
            if s in art and cover in ("poster", "cover", "fanart", "remoteposter", "remotecover"):
                return art[s]
            return m.group(0)
        return re.sub(r"https://example\.invalid/(movie|series|album|artist)/([a-z0-9-]+)/([a-z0-9-]+)\.jpg", repl, text)

    for kind in KINDS:
        files[kind] = json.loads(fix_art(rename(json.dumps(files[kind], ensure_ascii=False))))

    by_title = {m["title"]: m for m in cat["movies"]}
    series_by_title = {s["title"]: s for s in cat["series"]}

    def enrich(node):
        if isinstance(node, list):
            for x in node:
                enrich(x)
        elif isinstance(node, dict):
            m = by_title.get(node.get("title")) if "tmdbId" in node else None
            if m:
                node.update(year=m["year"], runtime=m["runtime"], genres=m["genres"], overview=m["overview"],
                            certification=m["certification"], studio=m["studio"])
                if isinstance(node.get("ratings"), dict) and isinstance(node["ratings"].get("imdb"), dict):
                    node["ratings"]["imdb"]["value"] = m["rating"]
            s = series_by_title.get(node.get("title")) if "tvdbId" in node else None
            if s:
                node.update(year=s["year"], genres=s["genres"], overview=s["overview"], network=s["network"])
            for v in node.values():
                enrich(v)

    for kind in ("radarr", "sonarr"):
        enrich(files[kind])

    # Top the libraries up so the Shelf has the whole catalogue.
    def top_up(entries, titles, key, make):
        have = {e[key] for e in entries}
        next_id = max(e["id"] for e in entries) + 1
        for i, title in enumerate(t for t in titles if t not in have):
            e = make(copy.deepcopy(entries[i % len(entries)]), title)
            e["id"] = next_id + i
            entries.append(e)

    def movie(e, title):
        m = by_title[title]
        e.update(title=title, sortTitle=title.lower(), cleanTitle=clean(title), titleSlug=slug(title),
                 originalTitle=title, tmdbId=10_000 + sum(map(ord, title)) * 37 % 990_000, imdbId=None,
                 folderName=f"/data/movies/{title} ({m['year']})", path=f"/data/movies/{title} ({m['year']})",
                 alternateTitles=[], images=[{"coverType": "poster", "url": m["poster"], "remoteUrl": m["poster"]},
                                             {"coverType": "fanart", "url": m["poster"], "remoteUrl": m["poster"]}])
        e.pop("movieFile", None)
        enrich(e)
        return e

    def artist(e, name):
        a = next(x for x in cat["artists"] if x["name"] == name)
        e.update(artistName=name, sortName=name.lower(), cleanName=clean(name), path=f"/data/lidarr/{name}",
                 foreignArtistId="demo-%08x" % (sum(map(ord, name)) * 2654435761 % 2**32),
                 images=[{"coverType": "poster", "url": a["poster"], "remoteUrl": a["poster"]}], links=[])
        e.pop("lastAlbum", None)
        e.pop("nextAlbum", None)
        return e

    def show(e, title):
        t = series_by_title[title]
        e.update(title=title, sortTitle=title.lower(), cleanTitle=clean(title), titleSlug=slug(title),
                 tvdbId=10_000 + sum(map(ord, title)) * 41 % 990_000, imdbId=None, path=f"/data/tv/{title}",
                 alternateTitles=[], images=[{"coverType": "poster", "url": t["poster"], "remoteUrl": t["poster"]}])
        enrich(e)
        return e

    for op in ("fetchallseries", "search-fetchlibraryownership"):
        top_up(files["sonarr"][op]["body"], pools["Series"], "title", show)
    for op in ("fetchallmovies", "search-fetchlibraryownership"):
        top_up(files["radarr"][op]["body"], pools["Movie"], "title", movie)
    top_up(files["lidarr"]["fetchallartists"]["body"], pools["Artist"], "artistName", artist)
    link_and_extend(files, cat, by_title, series_by_title)
    credits(files["radarr"], cat)
    releases(files["radarr"])

    for kind in KINDS:
        with open(os.path.join(PACKED, kind + ".json"), "w") as f:
            json.dump(files[kind], f, indent=1, sort_keys=True, ensure_ascii=False)
            f.write("\n")
    print("renamed %d placeholders; library: %d movies, %d artists" % (
        len(mapping), len(files["radarr"]["fetchallmovies"]["body"]), len(files["lidarr"]["fetchallartists"]["body"])))


# The recording day; FixtureTransport moves calendar dates so this day reads as today.
ANCHOR = datetime(2026, 9, 15, tzinfo=timezone.utc)
EXTRA_ID = 900_000  # rows this script adds; re-runs find them by id and skip


def iso(days, hour=0):
    return (ANCHOR + timedelta(days=days, hours=hour)).strftime("%Y-%m-%dT%H:%M:%SZ")


def dotted_name(title):
    return re.sub(r"[^A-Za-z0-9]+", ".", title).strip(".")


def link_and_extend(files, cat, by_title, series_by_title):
    """Queue and calendar rows point at library entries, and there are enough of them to look lived-in."""
    radarr, sonarr, lidarr = files["radarr"], files["sonarr"], files["lidarr"]
    movies = {m["title"]: m for m in radarr["fetchallmovies"]["body"]}
    shows = {s["title"]: s for s in sonarr["fetchallseries"]["body"]}
    artists = {a["artistName"]: a for a in lidarr["fetchallartists"]["body"]}

    def owner(release, names):
        return next((n for n in sorted(names, key=len, reverse=True) if release.startswith(dotted_name(n) + ".")), None)

    # -- Radarr queue: one row per movie, each tied to its library entry.
    rq = radarr["fetchqueue"]["body"]["records"]
    template = copy.deepcopy(rq[0])
    extra = [("Sintel", "downloading", 0.38, "qBittorrent", "torrent"), ("Metropolis", "queued", 1.0, "SABnzbd", "usenet"),
             ("His Girl Friday", "downloading", 0.72, "SABnzbd", "usenet"), ("Tears of Steel", "completed", 0.0, "qBittorrent", "torrent")]
    for i, (title, status, left, client, proto) in enumerate(extra):
        if any(r["id"] == EXTRA_ID + i for r in rq):
            continue
        r = copy.deepcopy(template)
        m = by_title[title]
        r.update(id=EXTRA_ID + i, downloadId="demo-%04d" % i, status=status, downloadClient=client, protocol=proto,
                 title="%s.%d.1080p.BluRay.x264-DEMO" % (dotted_name(title), m["year"]), size=9_800_000_000 - i * 1_300_000_000,
                 added=iso(-1 - i), trackedDownloadState="importPending" if status == "completed" else "downloading")
        r["sizeleft"] = int(r["size"] * left)
        r["quality"]["quality"].update(id=7, modifier="none", name="Bluray-1080p", resolution=1080, source="bluray")
        rq.append(r)
    for r in rq:
        t = owner(r["title"], movies)
        if t:
            r["movieId"] = movies[t]["id"]

    # -- Sonarr queue: episodes of different shows.
    sq = sonarr["fetchqueue"]["body"]["records"]
    template = copy.deepcopy(sq[0])
    for i, (title, season, ep, status, left) in enumerate([("The Lone Ranger", 2, 14, "downloading", 0.55),
                                                          ("Caminandes", 1, 3, "downloading", 0.2),
                                                          ("Flash Gordon", 1, 12, "queued", 1.0)]):
        if any(r["id"] == EXTRA_ID + i for r in sq):
            continue
        r = copy.deepcopy(template)
        r.update(id=EXTRA_ID + i, downloadId="demo-tv-%04d" % i, status=status, seasonNumber=season,
                 episodeId=EXTRA_ID + i, title="%s.S%02dE%02d.1080p.WEB-DL-DEMO" % (dotted_name(title), season, ep),
                 size=1_400_000_000 + i * 200_000_000, added=iso(-i))
        r["sizeleft"] = int(r["size"] * left)
        r["episode"].update(id=EXTRA_ID + i, seasonNumber=season, episodeNumber=ep, title="Episode %d" % ep, hasFile=False)
        sq.append(r)
    for r in sq:
        t = owner(r["title"], shows)
        if t:
            r["seriesId"] = shows[t]["id"]
            if isinstance(r.get("episode"), dict):
                r["episode"]["seriesId"] = shows[t]["id"]

    # -- Lidarr queue: rows name the album; point them at its artist.
    album_artist = {x["title"]: a["name"] for a in cat["artists"] for x in a["albums"]}
    for r in lidarr["fetchqueue"]["body"]["records"]:
        album = next((al for al in sorted(album_artist, key=len, reverse=True) if r["title"].startswith(dotted_name(al))), None)
        if album and album_artist[album] in artists:
            r["artistId"] = artists[album_artist[album]]["id"]

    # -- Upcoming: releases and episodes spread over the next three weeks.
    rc = radarr["fetchcalendar"]["body"]
    for i, (title, day) in enumerate([("Sherlock Jr.", 0), ("Nosferatu", 2), ("The Kid", 3), ("Detour", 5), ("Carnival of Souls", 8),
                                      ("The 39 Steps", 11), ("Meet John Doe", 15), ("Gulliver's Travels", 19)]):
        if title not in movies or any(m["title"] == title for m in rc):
            continue
        m = copy.deepcopy(movies[title])
        m.update(digitalRelease=iso(day), physicalRelease=iso(day + 28), hasFile=False, monitored=True, isAvailable=False)
        rc.append(m)
    for m in rc:
        if m["title"] in movies:
            m["id"] = movies[m["title"]]["id"]
    radarr["fetchcalendar"]["anchor"] = iso(0)

    sc = sonarr["fetchcalendar"]["body"]
    template = copy.deepcopy(sc[0])
    plan = [("Caminandes", 2, d, 1 + d // 7) for d in (0, 7, 14)] + [("The Lone Ranger", 3, d, 9 + d // 7) for d in (1, 8, 15)] + \
           [("Petticoat Junction", 5, d, 20 + d // 7) for d in (2, 9, 16)] + [("The Cisco Kid", 2, d, 4 + d // 7) for d in (4, 11, 18)] + \
           [("Pioneer One", 1, 6, 6), ("Tom Corbett, Space Cadet", 2, 10, 3)]
    for i, (title, season, day, ep) in enumerate(plan):
        if title not in shows or any(e["id"] == EXTRA_ID + i for e in sc):
            continue
        e = copy.deepcopy(template)
        e.update(id=EXTRA_ID + i, seriesId=shows[title]["id"], series=copy.deepcopy(shows[title]), seasonNumber=season,
                 episodeNumber=ep, title="Episode %d" % ep, airDateUtc=iso(day, 20), airDate=iso(day, 20)[:10],
                 hasFile=False, monitored=True, finaleType=None)
        sc.append(e)
    for e in sc:
        if e["series"]["title"] in shows:
            e["seriesId"] = shows[e["series"]["title"]]["id"]
            e["series"] = copy.deepcopy(shows[e["series"]["title"]])
    sonarr["fetchcalendar"]["anchor"] = iso(0)

    lc = lidarr["fetchcalendar"]["body"]
    template = copy.deepcopy(lc[0])
    for i, (name, album, day) in enumerate([("Josh Woodward", "The Beautiful Machine", 4), ("Blue Dot Sessions", "Codebreaker", 9),
                                            ("Jonathan Coulton", "Smoking Monkey", 16)]):
        if name not in artists or any(a["id"] == EXTRA_ID + i for a in lc):
            continue
        cover = next(x["cover"] for a in cat["artists"] if a["name"] == name for x in a["albums"] if x["title"] == album)
        a = copy.deepcopy(template)
        a.update(id=EXTRA_ID + i, title=album, artistId=artists[name]["id"], artist=copy.deepcopy(artists[name]),
                 releaseDate=iso(day), images=[{"coverType": "cover", "url": cover, "remoteUrl": cover}],
                 foreignAlbumId="demo-album-%04d" % i)
        lc.append(a)
    lidarr["fetchcalendar"]["anchor"] = iso(0)



def credits(radarr, cat):
    """Real cast and crew for the titles that have them; FixtureTransport scopes `/credit?movieId=` by `movieId`."""
    ids = {m["title"]: m["id"] for m in radarr["fetchallmovies"]["body"]}
    rows = []
    for m in cat["movies"]:
        for order, c in enumerate(m.get("credits", [])):
            row = {"id": EXTRA_ID + len(rows), "movieId": ids[m["title"]], "personName": c["name"], "type": c["type"],
                   "order": order, "personTmdbId": EXTRA_ID + sum(map(ord, c["name"])),
                   "creditTmdbId": "demo-%s-%d" % (slug(m["title"]), order),
                   "images": [{"coverType": "headshot", "url": c["headshot"], "remoteUrl": c["headshot"]}] if "headshot" in c else []}
            if c["type"] == "cast":
                row["character"] = c["character"]
            else:
                row.update(job=c["job"], department="Directing" if c["job"] == "Director" else "Production")
            rows.append(row)
    radarr["fetchcredits"]["body"] = rows
    radarr["fetchcredits"]["scope"] = "movieId"



def releases(radarr):
    """The recorder never calls /release, so manual search gets a synthetic list for a few titles."""
    ids = {m["title"]: m for m in radarr["fetchallmovies"]["body"]}
    qualities = {"Remux-2160p": (31, "bluray", 2160, "remux"), "Bluray-2160p": (19, "bluray", 2160, "none"),
                 "WEBDL-2160p": (18, "web", 2160, "none"), "Bluray-1080p": (7, "bluray", 1080, "none"),
                 "WEBDL-1080p": (3, "web", 1080, "none"), "Bluray-720p": (6, "bluray", 720, "none")}
    rows = [
        ("{d}.{y}.2160p.UHD.BluRay.REMUX.HDR.DV.TrueHD.Atmos.7.1-DEMO", "Remux-2160p", 71.4, "torrent", "Demo Tracker", 142, 9, 4, 8120, ["HDR", "DV", "TrueHD Atmos"], []),
        ("{d}.{y}.2160p.UHD.BluRay.x265.HDR10.DTS-HD.MA.5.1-OPEN", "Bluray-2160p", 38.2, "usenet", "Demo Indexer 1", None, None, 11, 6420, ["HDR10", "x265"], []),
        ("{d}.{y}.Criterion.1080p.BluRay.x264.FLAC.1.0-DEMO", "Bluray-1080p", 14.6, "torrent", "Demo Tracker", 86, 3, 26, 3150, ["Criterion", "FLAC"], ["Not an upgrade for existing movie file"]),
        ("{d}.{y}.2160p.WEB-DL.DDP5.1.HDR.H.265-OPEN", "WEBDL-2160p", 19.8, "usenet", "Demo Indexer 2", None, None, 2, 5210, ["HDR", "DDP5.1"], []),
        ("{d}.{y}.2160p.BluRay.REMUX.HEVC.DTS-HD.MA.5.1-OPEN", "Remux-2160p", 64.9, "usenet", "Demo Indexer 2", None, None, 38, 7480, ["HDR", "DTS-HD MA"], []),
        ("{d}.{y}.2160p.UHD.BluRay.x265.10bit.HDR.DDP5.1-DEMO", "Bluray-2160p", 29.3, "torrent", "Demo Tracker", 57, 4, 73, 5980, ["HDR", "DDP5.1"], []),
        ("{d}.{y}.2160p.AMZN.WEB-DL.DDP5.1.HDR10P.H.265-OPEN", "WEBDL-2160p", 17.2, "torrent", "Public Archive", 203, 15, 9, 4870, ["HDR10+", "DDP5.1"], []),
        ("{d}.{y}.2160p.WEB-DL.DV.HDR.DDP5.1.H.265-DEMO", "WEBDL-2160p", 16.4, "usenet", "Demo Indexer 1", None, None, 5, 4660, ["DV", "HDR"], []),
        ("{d}.{y}.1080p.BluRay.x264-DEMO", "Bluray-1080p", 9.1, "torrent", "Public Archive", 312, 22, 190, 1400, [], ["Not an upgrade for existing movie file"]),
        ("{d}.{y}.1080p.WEB-DL.AAC2.0.H.264-OPEN", "WEBDL-1080p", 5.4, "usenet", "Demo Indexer 1", None, None, 47, 900, ["AAC"], ["Not an upgrade for existing movie file"]),
        ("{d}.{y}.720p.BluRay.x264-DEMO", "Bluray-720p", 4.7, "torrent", "Public Archive", 58, 1, 640, 200, [], ["Not an upgrade for existing movie file", "Quality profile does not allow 720p"]),
    ]
    out = []
    for title in ("Charade", "Night of the Living Dead", "His Girl Friday", "Sintel", "Big Buck Bunny"):
        m = ids[title]
        dotted = dotted_name(title)
        for i, (name, q, gb, proto, indexer, seeds, leech, age, score, formats, rejections) in enumerate(rows):
            qid, source, res, mod = qualities[q]
            out.append({
                "guid": "demo-release-%s-%d" % (slug(title), i), "movieId": m["id"],
                "title": name.format(d=dotted, y=m["year"]), "indexer": indexer, "indexerId": 1 + i % 3,
                "size": int(gb * 1_000_000_000), "seeders": seeds, "leechers": leech, "age": age, "ageHours": age * 24.0,
                "publishDate": iso(-age), "protocol": proto, "releaseGroup": name.rsplit("-", 1)[-1],
                "quality": {"quality": {"id": qid, "name": q, "source": source, "resolution": res, "modifier": mod},
                            "revision": {"version": 1, "real": 0, "isRepack": False}},
                "customFormatScore": score, "customFormats": [{"id": 100 + j, "name": f} for j, f in enumerate(formats)],
                "rejected": bool(rejections), "rejections": rejections, "approved": not rejections,
                "languages": [{"id": 1, "name": "English"}], "indexerFlags": [],
            })
    radarr["fetchreleases"] = {"status": 200, "headers": {"content-type": "application/json; charset=utf-8"},
                               "body": out, "synthetic": True, "scope": "movieId"}


if __name__ == "__main__":
    main()
