#!/usr/bin/env python3
"""Anonymize the MediaKit fixtures and the golden request corpus.

Phase 0 records real responses from the maintainer's live *arr stack. Secrets,
hostnames and root paths are scrubbed by the recorder itself; what is left is
the maintainer's own library — film/series/artist/album titles, overviews,
release and file names, artwork URLs and external ids. This script replaces all
of that with the open-source demo universe ArrCore's DemoMocks already uses, so
the recordings can live in a public repo.

Properties:

* Deterministic and consistent — the same real value maps to the same
  open-source value in every file, so cross references stay coherent (a queue
  row's release name still resolves to its movie, an album still belongs to its
  artist, a Plex tmdb:// guid matches Radarr's tmdbId for the same title).
* In-memory only — the real -> fake table is rebuilt from the files being
  rewritten on every run and is never written anywhere.
* Idempotent — external ids are derived from the *anonymized* title rather than
  from the real id, and already-anonymized values are recognized and reserved,
  so a second run produces byte-identical output.

Usage:  python3 Tools/fixtures/anonymize_fixtures.py [--check]
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import sys
from collections import Counter, defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE_ROOT = os.path.join(REPO, "Packages", "MediaKit", "Fixtures")  # unpacked tree; pack_fixtures.py ships it
CORPUS = os.path.join(REPO, "docs", "superpowers", "baseline", "2026-09-15-golden-requests.json")

# --------------------------------------------------------------------------
# The open-source universe (DemoMocks order)
# --------------------------------------------------------------------------

POOLS = {
    "movie": [
        "Big Buck Bunny", "Sintel", "Tears of Steel", "Elephants Dream",
        "Spring", "Cosmos Laundromat", "Charge", "Hero",
        "Agent 327 Operation Barbershop", "Coffee Run", "Glass Half",
    ],
    "series": ["Pioneer One", "Caminandes"],
    "artist": [
        "Nine Inch Nails", "Brad Sucks", "Jonathan Coulton",
        "Kevin MacLeod", "Tobu", "Komiku",
    ],
    "album": ["Ghosts I-IV", "Out of It", "I Dont Know What Im Doing"],
    "studio": ["Blender Foundation", "Blender Animation Studio", "VODO"],
}

OVERFLOW = {
    "movie": "Open Movie", "series": "Open Series", "artist": "Open Artist",
    "album": "Open Album", "studio": "Open Studio", "person": "Person",
    "character": "Character", "collection": "Collection",
    "indexer": "Demo Indexer", "label": "Demo Label", "section": "Library",
    "generic": "Open Title",
}

SECTION_BY_TYPE = {
    "movie": "Movies", "show": "TV Shows", "artist": "Music",
    "photo": "Photos", "clip": "Videos",
}

OVERVIEW = {
    "movie": "An open-licensed short film from the demo library.",
    "series": "An open-licensed series from the demo library.",
    "episode": "An open-licensed episode from the demo library.",
    "artist": "An open-licensed recording artist from the demo library.",
    "album": "An open-licensed album from the demo library.",
    "track": "An open-licensed recording from the demo library.",
    "person": "A performer in the demo library.",
    "generic": "Placeholder description for the demo library.",
}
TAGLINE = "An open-licensed demo title."

FAKE_PATTERN = re.compile(
    r"^(Open Movie|Open Series|Open Artist|Open Album|Open Studio|Open Title"
    r"|Person|Character|Collection|Demo Indexer|Demo Label|Library"
    r"|Episode|Track) \d+$")

FAKE_LITERALS = set(SECTION_BY_TYPE.values()) | {"DEMO", "Trailer", TAGLINE}
FAKE_LITERALS.update(OVERVIEW.values())
for _pool in POOLS.values():
    FAKE_LITERALS.update(_pool)

MEDIA_EXTENSIONS = {
    ".mkv", ".mp4", ".avi", ".m4v", ".mov", ".ts", ".wmv", ".flv", ".mpg", ".mpeg",
    ".flac", ".mp3", ".m4a", ".ogg", ".opus", ".wav", ".ape", ".wma",
    ".nzb", ".torrent", ".srt", ".ass", ".sub", ".idx", ".nfo", ".jpg", ".png", ".zip",
}

# Where a release name stops being a title and starts being technical detail.
# Deliberately the same vocabulary as TECH_TOKEN below: every token that may
# survive in a rebuilt tail must also be able to end the title part.
TECH_WORDS = (
    r"WEB-DL|WEBDL|WEBRip|WEB|BluRay|Bluray|BDRip|BRRip|DVDRip|DVD|HDTV|REMUX"
    r"|PROPER|REPACK|COMPLETE|EXTENDED|UNRATED|LIMITED|IMAX|INTERNAL|MULTi|DUAL"
    r"|HDR10|HDR|SDR|UHD|4K|2160|1080|720|480"
    r"|x264|x265|h264|h265|HEVC|AVC|AV1|XviD|DivX"
    r"|FLAC|MP3|ALAC|AAC|AC3|EAC3|DTS-HD|DTS|TrueHD|Atmos|DDP5|DDP|DD5|OPUS"
    r"|OGG|WAV|SACD|Lossless"
)
RELEASE_BOUNDARY = re.compile(
    r"[._ \-\[(]("
    r"(19|20)\d{2}\b"
    r"|S\d{1,2}(E\d{1,4})?\b"
    r"|\d{3,4}p\b"
    r"|\d{2,4}kbps\b"
    r"|(" + TECH_WORDS + r")\b"
    r")", re.IGNORECASE)

ART_HOSTS = (
    "image.tmdb.org", "artworks.thetvdb.com", "thetvdb.com", "fanart.tv",
    "coverartarchive.org", "theaudiodb.com", "lidarr.audio", "lidarr.servarr.com",
    "metadata.sonarr.tv", "trakt.tv", "media.services.plex.tv",
)

# Free text that may quote a title; swept once every mapping is known.
FREETEXT_KEYS = {
    "message", "messages", "errormessage", "fail_message", "script_line",
    "action_line", "comment", "helptext", "hint", "reason", "description",
    "displaytitle", "extendeddisplaytitle", "content", "statusmessages",
    "actions", "stage_log", "labels",
}

KEEP_PATH_COMPONENTS = {
    "", "data", "media", "movies", "movie", "tv", "shows", "series", "music",
    "downloads", "download", "complete", "completed", "incomplete", "usenet",
    "torrents", "torrent", "mnt", "volume1", "storage", "library", "books",
    "radarr", "sonarr", "lidarr", "whisparr", "plex", "jellyfin", "emby",
    "qbittorrent", "sabnzbd", "nzbget", "deluge", "transmission", "rtorrent",
}

YEAR_SUFFIX = re.compile(r"\s*\((19|20)\d{2}\)\s*$")

# Link labels that name a public service rather than the media behind it.
LINK_SERVICES = {
    "link", "musicbrainz", "last.fm", "lastfm", "discogs", "allmusic", "imdb",
    "tmdb", "themoviedb", "tvdb", "thetvdb", "trakt", "wikipedia", "wikidata",
    "homepage", "official homepage", "twitter", "facebook", "instagram",
    "youtube", "bandcamp", "soundcloud", "spotify", "apple music", "deezer",
    "tidal", "genius", "rateyourmusic", "setlist.fm", "songkick", "vgmdb",
    "viaf", "whosampled", "myspace", "purevolume", "secondhandsongs", "fanart.tv",
    "tvmaze", "aniList", "anidb", "tvrage", "theaudiodb",
}


# A rebuilt release name can concatenate several fake names ("Open Artist 7 Open
# Album 15"); recognizing the whole run keeps a second pass a no-op.
_FAKE_TOKEN = (r"(?:Open (?:Movie|Series|Artist|Album|Studio|Title)|Person|Character"
               r"|Collection|Demo (?:Indexer|Label)|Library|Episode|Track) \d+")


def _fake_sequence_pattern():
    literals = "|".join(re.escape(x) for x in sorted(FAKE_LITERALS, key=len, reverse=True))
    unit = "(?:%s|%s)" % (_FAKE_TOKEN, literals)
    return re.compile(r"^%s(?:[\s\-]+%s)*$" % (unit, unit))


FAKE_SEQUENCE = _fake_sequence_pattern()


def sab_action(value: str) -> str:
    """SABnzbd stage log: drop the job id and the Usenet provider's name."""
    value = re.sub(r"\[[A-Za-z0-9]{8,}\]", "[job]", value)
    return re.sub(r"(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9.\-]{2,}=", "Server=", value)


def link_label(value: str) -> str:
    if Mapper.looks_fake(value):
        return value
    return M.known(value) or (value if value.lower() in LINK_SERVICES else "link")

# Only these survive in a rebuilt release name's tail; anything else in it could
# still be a word from the real title.
TECH_TOKEN = re.compile(
    r"^((19|20)\d{2}|S\d{1,2}(E\d{1,4})?|E\d{1,4}|\d{3,4}p|\d{2,4}kbps|\d{1,2}bit"
    r"|" + TECH_WORDS + r")$", re.IGNORECASE)


def technical_tail(tail: str) -> str:
    """Keep only recognized technical tokens, so no real word can survive."""
    kept = [t for t in re.split(r"[._\s]+", tail) if t and TECH_TOKEN.match(t)]
    return ("." + ".".join(kept)) if kept else ""


def looks_like_prose(value: str) -> bool:
    """A status sentence, not a release name.

    Anything carrying a technical token, a trailing -GROUP, underscores or more
    than one dot is a release name however wordy it reads.
    """
    if RELEASE_BOUNDARY.search(value):
        return False
    if re.search(r"-[A-Za-z0-9]{2,}$", value):
        return False
    if "_" in value or value.count(".") > 1:
        return False
    return len(value.split()) >= 5

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------


def norm(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.lower())


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "item"


def dotted(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", ".", value).strip(".") or "Open.Title"


def digest(value: str, salt: str = "") -> int:
    return int(hashlib.sha256((salt + "|" + value).encode("utf-8")).hexdigest()[:12], 16)


def split_year(value: str):
    match = YEAR_SUFFIX.search(value)
    if not match:
        return value, ""
    return value[: match.start()].rstrip(), value[match.start():]


def split_extension(value: str):
    root, ext = os.path.splitext(value)
    return (root, ext) if ext.lower() in MEDIA_EXTENSIONS else (value, "")


def is_http(value: str) -> bool:
    return value.startswith("http://") or value.startswith("https://")


def art_host(value: str) -> bool:
    return is_http(value) and any(host in value for host in ART_HOSTS)


# --------------------------------------------------------------------------
# The mapper
# --------------------------------------------------------------------------

class Mapper:
    """Real value -> open-source value. Lives only for the duration of a run."""

    def __init__(self):
        self.by_real = {}
        self.by_norm = {}
        self.used = defaultdict(set)
        self.overflow_next = {}
        self.scanning = True
        self.fields = 0
        self.assigned = Counter()          # pool -> how many values taken
        self.per_client = defaultdict(lambda: {"titles": 0, "fields": 0})
        self.client = "?"

    # -- pools -----------------------------------------------------------

    POOL_FOR = {"episode": "series", "track": "album", "generic": "movie"}

    def _take(self, kind: str) -> str:
        kind = self.POOL_FOR.get(kind, kind)
        used = self.used[kind]
        for candidate in POOLS.get(kind, []):
            if candidate not in used:
                used.add(candidate)
                return candidate
        prefix = OVERFLOW.get(kind, OVERFLOW["generic"])
        n = self.overflow_next.get(kind, len(POOLS.get(kind, [])) + 1)
        while "%s %d" % (prefix, n) in used:
            n += 1
        self.overflow_next[kind] = n + 1
        used.add("%s %d" % (prefix, n))
        return "%s %d" % (prefix, n)

    @staticmethod
    def looks_fake(value: str) -> bool:
        return value in FAKE_LITERALS or bool(FAKE_PATTERN.match(value))

    def _reserve(self, value: str) -> None:
        for kind, pool in POOLS.items():
            if value in pool:
                self.used[kind].add(value)
                return
        for kind, prefix in OVERFLOW.items():
            if value.startswith(prefix + " "):
                self.used[kind].add(value)
                return

    # -- titles ----------------------------------------------------------

    def title(self, raw, kind: str):
        """Map a display title, preserving a trailing "(year)"."""
        if not isinstance(raw, str) or not raw.strip():
            return raw
        base, year = split_year(raw)
        if not base:
            return raw
        if base in self.by_real:
            return self.by_real[base] + year
        key = norm(base)
        if key and key in self.by_norm:
            fake = self.by_norm[key]
        elif self.looks_fake(base):
            self._reserve(base)
            fake = base
        elif self.scanning:
            return raw
        else:
            fake = self._take(kind)
            self.assigned[kind] += 1
            self.per_client[self.client]["titles"] += 1
        self.by_real[base] = fake
        if key:
            self.by_norm.setdefault(key, fake)
        return fake + year

    def known(self, raw):
        if not isinstance(raw, str):
            return None
        base, _ = split_year(raw)
        return self.by_real.get(base) or self.by_norm.get(norm(base))

    def register(self, raw: str, fake: str) -> None:
        if self.scanning or not raw:
            return
        self.by_real.setdefault(raw, fake)
        if norm(raw):
            self.by_norm.setdefault(norm(raw), fake)

    # -- external ids, derived from the ANONYMIZED identity --------------

    def ident(self, idkey: str, salt: str, form: str):
        seed = idkey or "orphan"
        if form == "imdb":
            return "tt%07d" % (digest(seed, salt) % 10_000_000)
        if form == "int":
            return 10_000 + digest(seed, salt) % 990_000
        if form == "uuid":
            h = hashlib.sha256((salt + "|" + seed).encode("utf-8")).hexdigest()
            return "%s-%s-%s-%s-%s" % (h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
        return "demo-%012x" % (digest(seed, salt) % (16 ** 12))

    def count_field(self):
        self.fields += 1
        self.per_client[self.client]["fields"] += 1


M = Mapper()
ORPHAN = [0]

# --------------------------------------------------------------------------
# Node classification
# --------------------------------------------------------------------------

DEFAULT_KIND = {
    "radarr": "movie", "sonarr": "series", "whisparr": "movie",
    "lidarr": "album", "tmdb": "movie", "plex": "movie",
    "qbittorrent": "movie", "sabnzbd": "movie",
}


def entity_kind(d: dict, client: str, parent_key) -> str:
    keys = {k.lower() for k in d}
    if client == "plex":
        if parent_key == "Directory" and "scanner" in keys:
            return "section"
        by_type = {"movie": "movie", "show": "series", "season": "series",
                   "episode": "episode", "artist": "artist", "album": "album",
                   "track": "track"}
        if d.get("type") in by_type:
            return by_type[d["type"]]
    if client == "tmdb":
        if "episode_number" in keys:
            return "episode"
        if "title" in keys or "original_title" in keys:
            return "movie"
        if "first_air_date" in keys or "original_name" in keys:
            return "series"
        if "known_for_department" in keys or "profile_path" in keys or "biography" in keys:
            return "person"
    if "foreignalbumid" in keys or "albumtype" in keys:
        return "album"
    if "foreigntrackid" in keys or "tracknumber" in keys or "absolutetracknumber" in keys:
        return "track"
    if "foreignartistid" in keys or "artistname" in keys or "artisttype" in keys:
        return "artist"
    if "episodenumber" in keys or "airdateutc" in keys or "absoluteepisodenumber" in keys:
        return "episode"
    if "seasons" in keys or "seriestype" in keys or "tvdbid" in keys or "seriesid" in keys:
        return "series"
    if ("tmdbid" in keys or "incinemas" in keys or "moviefile" in keys
            or "minimumavailability" in keys or "movieid" in keys):
        return "movie"
    if "albumid" in keys:
        return "album"
    if "artistid" in keys:
        return "artist"
    if "personname" in keys or "known_for_department" in keys:
        return "person"
    return DEFAULT_KIND.get(client, "generic")


def is_release_node(d: dict, parent_key) -> bool:
    keys = {k.lower() for k in d}
    if parent_key == "statusMessages":
        return True
    if "trackeddownloadstate" in keys or "trackeddownloadstatus" in keys:
        return True
    if "downloadid" in keys and "protocol" in keys:
        return True
    if "hash" in keys and ("save_path" in keys or "magnet_uri" in keys):
        return True
    return "nzo_id" in keys


def primary_title_key(d: dict, kind: str, client: str, release_node: bool):
    """`name` is a title only where it really names media.

    In the *arr APIs `name` is a quality, language, profile, indexer or download
    client name — mapping those as titles would wreck the fixtures (and leak
    through the free-text sweep); only TMDB records and download-client torrents
    carry a media name under that key.
    """
    for candidate in ("title", "artistName", "albumTitle", "personName", "name"):
        value = d.get(candidate)
        if not isinstance(value, str):
            continue
        if candidate == "name":
            if client == "tmdb" and kind in ("person", "series", "episode", "movie"):
                return candidate
            if release_node and client in ("qbittorrent", "sabnzbd"):
                return candidate
            continue
        return candidate
    return None


# --------------------------------------------------------------------------
# Value rewriters
# --------------------------------------------------------------------------

def release_name(raw, kind: str, hint, client: str):
    """Rebuild a release / file name from the fake title, keeping the technical tail."""
    if not isinstance(raw, str) or not raw.strip() or raw == "<redacted>":
        return raw
    if looks_like_prose(raw):
        return raw          # a status sentence, not a release name; swept later
    body, ext = split_extension(raw)
    body = re.sub(r"-DEMO$", "", body)          # our own marker from an earlier run
    match = RELEASE_BOUNDARY.search(body)
    head, tail = (body[: match.start()], body[match.start():]) if match else (body, "")
    head = head.strip(" ._-[(")
    if not head:
        head, tail = body.strip(" ._-[("), ""
    undot = re.sub(r"[._]+", " ", head).strip()

    if FAKE_SEQUENCE.match(undot):
        fake = undot
        M.register(undot, fake)
    elif " - " in undot and client == "lidarr":
        left, right = undot.split(" - ", 1)
        fake = "%s - %s" % (M.title(left, "artist"), M.title(right, "album"))
    else:
        fake = M.known(head) or M.known(undot)
        if fake is None:
            if Mapper.looks_fake(undot):
                M._reserve(undot)
                fake = undot
                M.register(undot, fake)
            elif hint:
                fake = hint
                # An episode's / track's hint names the episode, not the series
                # the file name starts with — binding those would swap them.
                if (kind in ("movie", "series", "artist", "album")
                        and not re.match(r"^(Episode|Track) \d+$", fake)):
                    M.register(undot, fake)
            else:
                fake = M.title(undot, kind)
    if M.scanning:
        return raw
    return dotted(split_year(fake)[0]) + technical_tail(tail) + "-DEMO" + ext


def rebuild_path(raw, kind: str, hint, client: str):
    if not isinstance(raw, str) or not raw.strip() or raw == "<redacted>":
        return raw
    parts = raw.split("/")
    out = []
    for index, part in enumerate(parts):
        if part.lower() in KEEP_PATH_COMPONENTS:
            out.append(part)
            continue
        body, ext = split_extension(part)
        release_like = bool(ext) or ("." in body and " " not in body)
        if index == len(parts) - 1 and release_like:
            out.append(release_name(part, kind, hint, client))
            continue
        # Servarr folder naming appends "{tmdb-603}" / "{edition-…}" tags; strip
        # them before mapping so the folder resolves to the same fake title as
        # the record, then re-emit them with remapped ids.
        tags = "".join(m.group(0) for m in FOLDER_TAG.finditer(part))
        base, year = split_year(FOLDER_TAG.sub("", part).strip())
        mapped = M.title(base, kind)
        if M.scanning:
            out.append(part)
            continue
        tags = FOLDER_TAG.sub(lambda m: remap_folder_tag(m, mapped), tags)
        out.append((split_year(mapped)[0] + year + (" " + tags if tags else "")).strip())
    return "/".join(out)


FOLDER_TAG = re.compile(r"\{[A-Za-z]+-[^}]*\}")


def remap_folder_tag(match, title) -> str:
    text = match.group(0)
    scheme = text[1:].split("-", 1)[0].lower()
    if scheme in ("tmdb", "tvdb"):
        return "{%s-%d}" % (scheme, M.ident(title, scheme, "int"))
    if scheme == "imdb":
        return "{imdb-%s}" % M.ident(title, "imdb", "imdb")
    if scheme == "edition":
        return "{edition-DEMO}"
    return "{%s-demo}" % scheme


def art_url(kind: str, title, cover: str) -> str:
    return "https://example.invalid/%s/%s/%s.jpg" % (kind, slugify(title or "item"),
                                                     slugify(cover or "image"))


def plex_media_path(raw: str, field: str) -> str:
    match = re.search(r"/(\d+)/", raw + "/")
    return "/library/metadata/%s/%s/1" % (match.group(1) if match else "0", field)


def remap_guid(raw: str, idkey: str) -> str:
    if not isinstance(raw, str) or "://" not in raw:
        return raw
    scheme, rest = raw.split("://", 1)
    low = scheme.lower()
    if "imdb" in low:
        return "%s://%s" % (scheme, M.ident(idkey, "imdb", "imdb"))
    if "tmdb" in low or "themoviedb" in low:
        return "%s://%d" % (scheme, M.ident(idkey, "tmdb", "int"))
    if "tvdb" in low or "thetvdb" in low:
        return "%s://%d" % (scheme, M.ident(idkey, "tvdb", "int"))
    if "mbid" in low or "musicbrainz" in low:
        return "%s://%s" % (scheme, M.ident(idkey, "mbid", "uuid"))
    if low == "plex":
        head = rest.partition("/")[0]
        return "plex://%s/%s" % (head, hashlib.sha256(
            ("plex|" + idkey).encode("utf-8")).hexdigest()[:24])
    return "%s://%s" % (scheme, M.ident(idkey, "guid", "hex"))


# --------------------------------------------------------------------------
# Field dispatch
# --------------------------------------------------------------------------

ID_INT_KEYS = {"tmdbid": "tmdb", "tvdbid": "tvdb", "tvrageid": "tvrage",
               "tvmazeid": "tvmaze", "discogsid": "discogs", "tadbid": "tadb",
               "credittmdbid": "tmdb"}
FOREIGN_KEYS = {"foreignid", "foreignartistid", "foreignalbumid", "foreigntrackid",
                "foreignreleaseid", "foreignrecordingid", "mbid", "musicbrainzid"}
GUID_KEYS = {"guid", "parentguid", "grandparentguid"}
PATH_KEYS = {"path", "relativepath", "folder", "foldername", "originalfilepath",
             "sourcepath", "sourcerelativepath", "importedpath", "droppedpath",
             "outputpath", "file", "content_path", "save_path", "download_path",
             "storage", "rootfolderpath", "root_path", "temp_path"}
OVERVIEW_KEYS = {"overview", "description", "summary", "plot", "biography"}
ART_KEYS = {"remoteurl", "remoteposter", "remotecover", "coverurl", "url",
            "poster_path", "backdrop_path", "profile_path", "still_path", "logo_path"}
PLEX_IMAGE_KEYS = {"thumb", "art", "parentthumb", "grandparentthumb",
                   "grandparentart", "grandparenttheme", "theme", "banner"}
DERIVED_TITLE_KEYS = {"sorttitle", "cleantitle", "titleslug", "titlesort", "sortname",
                      "cleanname", "slug", "grandparentslug", "originaltitle",
                      "original_title", "original_name"}
BLANK_KEYS = {"place_of_birth", "homepage", "website", "youtubetrailerid",
              "facebook_id", "instagram_id", "twitter_id", "wikidata_id",
              "freebase_id", "freebase_mid", "report", "url_info", "mediumname",
              "disambiguation"}
NEEDS_ID = set(ID_INT_KEYS) | FOREIGN_KEYS | GUID_KEYS | {"imdbid", "imdb_id", "titleslug"}


def rewrite(value, client, key=None, parent_key=None, ctx=None):
    if isinstance(value, dict):
        return rewrite_object(value, client, parent_key=key, ctx=ctx)
    if isinstance(value, list):
        return [rewrite(v, client, key=key, parent_key=parent_key, ctx=ctx) for v in value]
    return value


def rewrite_object(d: dict, client: str, parent_key=None, ctx=None):
    kind = entity_kind(d, client, parent_key)
    release_node = is_release_node(d, parent_key)
    prim = primary_title_key(d, kind, client, release_node)
    if client == "plex" and parent_key == "Player":
        prim = None                      # the viewer's device, not media
    hint = ctx.get("title") if ctx else None

    fake_title = None
    if prim is not None:
        raw = d[prim]
        if kind == "section":
            mapped = SECTION_BY_TYPE.get(d.get("type"))
            if mapped is None:
                fake_title = M.title(raw, "section")
            else:
                fake_title = mapped
                M.register(split_year(raw)[0], mapped)
                M._reserve(mapped)
        elif kind == "episode":
            fake_title = "Episode %s" % d.get(
                "episodeNumber", d.get("episode_number", d.get("index", 1)))
        elif kind == "track":
            fake_title = "Track %s" % d.get(
                "trackNumber", d.get("absoluteTrackNumber", d.get("index", 1)))
        elif kind == "person":
            fake_title = M.title(raw, "person")
        elif release_node:
            fake_title = release_name(raw, kind, release_hint(d, client, kind, hint), client)
        else:
            fake_title = M.title(raw, kind)

    entity_title = hint if release_node else (fake_title or hint)

    idkey = None
    if parent_key == "Guid" or any(k.lower() in NEEDS_ID for k in d):
        idkey = compute_idkey(kind, entity_title, hint, d)

    child_ctx = {"title": entity_title, "kind": kind, "cover": d.get("coverType")}

    out = {}
    for k in sorted(d.keys()):
        out[k] = rewrite_field(k, d[k], d, client, kind, prim, fake_title,
                               entity_title, release_node, parent_key, child_ctx, idkey)
    return out


def compute_idkey(kind, entity_title, hint, d):
    if kind in ("episode", "track"):
        return "%s/%s" % (hint or "", entity_title or "")
    if entity_title:
        return entity_title
    if isinstance(d.get("id"), int):
        return "id:%d" % d["id"]
    ORPHAN[0] += 1
    return "orphan:%d" % ORPHAN[0]


def release_hint(d, client, kind, fallback):
    return fallback


def rewrite_field(k, v, d, client, kind, prim, fake_title, entity_title,
                  release_node, parent_key, child_ctx, idkey):
    lk = k.lower()

    if k == prim and fake_title is not None:
        M.count_field()
        return fake_title

    if isinstance(v, (dict, list)):
        if lk == "alternatetitles" and isinstance(v, list):
            return [rewrite_alt_title(e, client, kind, entity_title, i)
                    for i, e in enumerate(v)]
        if lk == "actions" and client == "sabnzbd" and all(isinstance(e, str) for e in v):
            M.count_field()
            return [sab_action(e) for e in v]
        if lk == "also_known_as" and all(isinstance(e, str) for e in v):
            return [M.title(e, "person") for e in v]
        if lk == "label" and client == "lidarr" and all(isinstance(e, str) for e in v):
            M.count_field()
            return [M.title(e, "label") for e in v]
        if lk == "releasegroups" and all(isinstance(e, str) for e in v):
            return ["DEMO" for _ in v]
        return rewrite(v, client, key=k, parent_key=parent_key, ctx=child_ctx)

    if v is None or isinstance(v, bool):
        return v

    if isinstance(v, int):
        if lk in ID_INT_KEYS:
            M.count_field()
            return M.ident(idkey, ID_INT_KEYS[lk], "int")
        return v

    if not isinstance(v, str):
        return v

    # --- external ids ----------------------------------------------------
    if lk in FOREIGN_KEYS:
        M.count_field()
        return M.ident(idkey, lk, "uuid" if _is_uuid(v) or client == "lidarr" else "hex")
    if lk in ("imdbid", "imdb_id"):
        M.count_field()
        return M.ident(idkey, "imdb", "imdb") if v.startswith("tt") else v
    if lk in GUID_KEYS and "://" in v:
        M.count_field()
        return remap_guid(v, idkey)
    if lk == "id" and parent_key == "Guid":
        M.count_field()
        return remap_guid(v, idkey)

    # --- titles and their derivations ------------------------------------
    if lk in DERIVED_TITLE_KEYS:
        M.count_field()
        return derived_title(lk, v, d, kind, entity_title, idkey)
    if lk in OVERVIEW_KEYS:
        M.count_field()
        return OVERVIEW.get("person" if lk == "biography" else kind, OVERVIEW["generic"])
    if lk == "tagline":
        M.count_field()
        return TAGLINE
    if lk in BLANK_KEYS:
        return "" if v else v

    # --- release / file names --------------------------------------------
    if lk in ("sourcetitle", "releasetitle", "scenename", "nzb_name", "filename"):
        M.count_field()
        return release_name(v, kind, entity_title, client)
    if lk == "magnet_uri":
        M.count_field()
        return "magnet:?xt=urn:btih:%s&dn=%s" % ("0" * 40, dotted(fake_title or "Open Title"))
    if lk in PATH_KEYS and ("/" in v or split_extension(v)[1]
                            or lk in ("folder", "foldername")):
        M.count_field()
        return rebuild_path(v, kind, entity_title, client)
    if (client == "qbittorrent" and "/" in v
            and (lk.endswith("_path") or lk.endswith("_dir") or lk.endswith("_dir_fin"))):
        M.count_field()
        return rebuild_path(v, kind, entity_title, client)
    if parent_key == "links":
        M.count_field()
        if lk == "url":
            return "https://example.invalid/links/%s/%s" % (
                slugify(entity_title or "item"), slugify(link_label(d.get("name") or "link")))
        if lk == "name":
            return link_label(v)

    # --- artwork ----------------------------------------------------------
    if lk in ART_KEYS:
        if lk != "url" or parent_key == "images" or art_host(v):
            M.count_field()
            if not is_http(v) and lk.endswith("_path"):
                return "/%s-%s.jpg" % (slugify(entity_title or "item"),
                                       slugify(lk[: -len("_path")]))
            return art_url(kind, entity_title, d.get("coverType") or child_ctx.get("cover") or lk)
    if art_host(v):
        M.count_field()
        return art_url(kind, entity_title, d.get("coverType") or lk)
    if client == "plex" and lk in PLEX_IMAGE_KEYS and v.startswith("/"):
        M.count_field()
        field = lk.replace("grandparent", "").replace("parent", "") or "thumb"
        return plex_media_path(v, field)

    # --- Plex / TMDB specifics -------------------------------------------
    if lk in ("librarysectiontitle", "title1"):
        M.count_field()
        return M.known(v) or M.title(v, "section")
    if lk in ("parenttitle", "grandparenttitle", "title2"):
        if re.fullmatch(r"(Season|Series|Disc|Volume|CD) \d+", v):
            return v                     # Plex's synthetic season/disc labels
        M.count_field()
        return M.title(v, "series" if lk == "grandparenttitle" else kind)
    if lk == "tag":
        if parent_key in ("Role", "Director", "Writer", "Producer"):
            M.count_field()
            return M.title(v, "person")
        if parent_key == "Collection":
            M.count_field()
            return M.title(v, "collection")
        return v
    if lk in ("role", "character"):
        M.count_field()
        return M.title(v, "character")
    if client == "plex" and parent_key == "Player":
        M.count_field()
        return {"address": "10.0.0.2", "remotepublicaddress": "198.51.100.2",
                "title": "Demo Player", "device": "Demo Player", "model": "demo",
                "vendor": "Demo"}.get(lk, v)
    if lk == "alt" and client == "plex":
        M.count_field()
        return entity_title or "artwork"
    if lk == "name" and client == "tmdb":
        if parent_key in ("cast", "crew", "created_by") and "title" not in d:
            M.count_field()
            return M.title(v, "person")
        if "site" in d and "key" in d:
            M.count_field()
            return "Trailer"
        if kind in ("series", "movie", "episode") and parent_key not in (
                "genres", "networks", "production_companies", "spoken_languages"):
            M.count_field()
            return fake_title or M.title(v, kind)
        return v
    if lk == "name" and release_node and client in ("qbittorrent", "sabnzbd"):
        M.count_field()
        return release_name(v, kind, entity_title, client)

    # --- remaining identifying free text ---------------------------------
    if lk in ("studio", "network"):
        M.count_field()
        return M.title(v, "studio")
    if lk == "indexer":
        M.count_field()
        return M.title(v, "indexer")
    if lk == "releasegroup":
        return "DEMO"
    if lk == "label" and client == "lidarr" and parent_key == "releases":
        M.count_field()
        return M.title(v, "label")

    return v


def _is_uuid(value: str) -> bool:
    return bool(re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", value))


def derived_title(lk, v, d, kind, entity_title, idkey):
    base = entity_title or M.known(v) or M.title(v, kind)
    if not isinstance(base, str):
        return v
    base = split_year(base)[0]
    if lk in ("sorttitle", "titlesort", "sortname"):
        return re.sub(r"^(the|a|an)\s+", "", base.lower()).strip()
    if lk in ("cleantitle", "cleanname"):
        return norm(base)
    if lk in ("titleslug", "slug", "grandparentslug"):
        suffix = "-%d" % M.ident(idkey, "tmdb", "int") if isinstance(d.get("tmdbId"), int) else ""
        return slugify(base) + suffix
    return base


def rewrite_alt_title(entry, client, kind, entity_title, index):
    if not isinstance(entry, dict):
        return entry
    out = {}
    for k in sorted(entry.keys()):
        v = entry[k]
        if k.lower() == "title" and isinstance(v, str):
            if M.scanning:
                out[k] = v
            else:
                M.count_field()
                base = entity_title or M.known(v) or M.title(v, kind)
                out[k] = "%s (Alt %d)" % (split_year(base)[0], index + 1)
        elif isinstance(v, (dict, list)):
            out[k] = rewrite(v, client, key=k, ctx={"title": entity_title, "kind": kind})
        else:
            out[k] = rewrite_field(k, v, entry, client, kind, None, None, entity_title,
                                   False, "alternateTitles",
                                   {"title": entity_title}, entity_title)
    return out


# --------------------------------------------------------------------------
# Free-text sweep (runs once every mapping is known)
# --------------------------------------------------------------------------

def build_sweeps():
    """One combined alternation, so a replacement is never re-scanned."""
    table = {}
    for real, fake in M.by_real.items():
        if real == fake or len(real) < 4:
            continue
        for variant, replacement in ((real, fake),
                                     (real.replace(" ", "."), dotted(fake)),
                                     (real.replace(" ", "_"), fake.replace(" ", "_"))):
            table.setdefault(variant.lower(), replacement)
    if not table:
        return None
    keys = sorted(table, key=len, reverse=True)
    pattern = re.compile(r"(?<![A-Za-z0-9])(%s)(?![A-Za-z0-9])"
                         % "|".join(re.escape(k) for k in keys), re.IGNORECASE)
    return pattern, table


def sweep(node, sweeps, key=None, inside=False):
    if sweeps is None:
        return node
    if isinstance(node, dict):
        return {k: sweep(v, sweeps, k, inside or (key or "").lower() in FREETEXT_KEYS)
                for k, v in node.items()}
    if isinstance(node, list):
        return [sweep(v, sweeps, key, inside) for v in node]
    if isinstance(node, str) and node and (inside or (key or "").lower() in FREETEXT_KEYS):
        pattern, table = sweeps
        return pattern.sub(lambda m: table.get(m.group(0).lower(), m.group(0)), node)
    return node


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def fixture_files():
    return sorted(glob.glob(os.path.join(FIXTURE_ROOT, "**", "*.json"), recursive=True))


def client_of(path: str) -> str:
    return os.path.basename(os.path.dirname(path))


def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def dump(value) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def process_corpus(entries):
    out = []
    for entry in entries:
        item = dict(entry)
        client = item.get("client", "generic")
        M.client = "corpus"
        body = item.get("body")
        if isinstance(body, str) and body.strip()[:1] in ("{", "["):
            try:
                parsed = json.loads(body)
            except ValueError:
                parsed = None
            if parsed is not None:
                rewritten = rewrite(parsed, client)
                if not M.scanning:
                    item["body"] = json.dumps(rewritten, sort_keys=True,
                                              separators=(",", ":"), ensure_ascii=False)
        out.append(item)
    return out


def main():
    parser = argparse.ArgumentParser(description="Anonymize MediaKit fixtures + corpus.")
    parser.add_argument("--check", action="store_true",
                        help="report whether anything would change, write nothing")
    args = parser.parse_args()

    files = fixture_files()
    corpus_entries = load(CORPUS) if os.path.exists(CORPUS) else []

    # Pass 1 — reserve every value that is already anonymized.
    M.scanning = True
    for path in files:
        M.client = client_of(path)
        rewrite(load(path), M.client)
    process_corpus(corpus_entries)

    # Pass 2 — rewrite.
    M.scanning = False
    ORPHAN[0] = 0
    M.fields = 0
    M.per_client.clear()
    results = {}
    counts = defaultdict(lambda: {"files": 0})
    for path in files:
        M.client = client_of(path)
        results[path] = rewrite(load(path), M.client)
        counts[M.client]["files"] += 1
    corpus_out = process_corpus(corpus_entries)
    counts["corpus"]["files"] = 1 if corpus_entries else 0

    # Pass 3 — free-text sweep with the completed mapping.
    sweeps = build_sweeps()
    for path in list(results):
        results[path] = sweep(results[path], sweeps)
    corpus_out = sweep(corpus_out, sweeps)

    changed = []
    for path, value in sorted(results.items()):
        text = dump(value)
        with open(path, "r", encoding="utf-8") as handle:
            if handle.read() == text:
                continue
        changed.append(path)
        if not args.check:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
    if corpus_entries:
        text = dump(corpus_out)
        with open(CORPUS, "r", encoding="utf-8") as handle:
            same = handle.read() == text
        if not same:
            changed.append(CORPUS)
            if not args.check:
                with open(CORPUS, "w", encoding="utf-8") as handle:
                    handle.write(text)

    print("anonymize_fixtures — %s" % ("check (no writes)" if args.check else "applied"))
    print("%-13s %6s %8s %8s %8s" % ("kind", "files", "changed", "titles", "fields"))
    for kind in sorted(counts):
        kind_changed = sum(1 for p in changed
                           if (p == CORPUS if kind == "corpus" else client_of(p) == kind))
        stats = M.per_client.get(kind, {"titles": 0, "fields": 0})
        print("%-13s %6d %8d %8d %8d" % (kind, counts[kind]["files"], kind_changed,
                                         stats["titles"], stats["fields"]))
    total_files = len(files) + (1 if corpus_entries else 0)
    total_titles = sum(s["titles"] for s in M.per_client.values())
    print("%-13s %6d %8d %8d %8d" % ("TOTAL", total_files, len(changed),
                                     total_titles, M.fields))
    print("distinct real values replaced: %d"
          % len([r for r, f in M.by_real.items() if r != f]))
    for kind in sorted(M.assigned):
        print("  pool %-11s assigned %d" % (kind, M.assigned[kind]))
    if args.check and changed:
        print("WOULD CHANGE %d file(s)" % len(changed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
