#!/usr/bin/env python3
import json, os, pathlib

raw = os.environ.get("SOFA_RAW", "")
mode = os.environ.get("SOFA_MODE", "search")

def _nonempty_env(name):
    return (os.environ.get(name) or "").strip()

def workflow_data_dir():
    raw = _nonempty_env("alfred_workflow_data")
    if not raw:
        return None
    return pathlib.Path(raw)

def recents_file():
    raw = _nonempty_env("SOFA_RECENTS")
    if raw:
        return pathlib.Path(raw)
    base = workflow_data_dir()
    if base is None:
        return None
    return base / "recents.json"

def hits_path():
    raw = _nonempty_env("SOFA_HITS")
    if raw:
        return pathlib.Path(raw)
    recents_raw = _nonempty_env("SOFA_RECENTS")
    if recents_raw:
        return pathlib.Path(recents_raw).with_name("last_hits.json")
    base = workflow_data_dir()
    if base is None:
        return None
    return base / "last_hits.json"

def emit(items):
    try:
        cache_path = hits_path()
        if cache_path is not None:
            cache = {}
            if cache_path.exists():
                try:
                    cache = json.loads(cache_path.read_text())
                except Exception:
                    cache = {}
            for it in items:
                url = it.get("arg")
                if not url or not str(url).startswith("http"):
                    continue
                vars_ = it.get("variables") or {}
                cache[url] = {
                    "url": url,
                    "title": vars_.get("sofa_title") or it.get("title") or url,
                    "kind": vars_.get("sofa_kind") or "link",
                    "id": vars_.get("sofa_id"),
                    "sport": vars_.get("sofa_sport") or "football",
                }
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            if len(cache) > 200:
                cache = dict(list(cache.items())[-200:])
            cache_path.write_text(json.dumps(cache))
    except Exception:
        pass
    print(json.dumps({"items": items}))

def item(url, title, kind, eid=None, sport="football", subtitle=""):
    variables = {
        "sofa_title": title,
        "sofa_kind": kind or "link",
        "sofa_sport": sport or "football",
    }
    if eid is not None:
        variables["sofa_id"] = str(eid)
    out = {
        "title": title,
        "subtitle": subtitle,
        "arg": url,
        "autocomplete": title,
        "valid": True,
        "variables": variables,
    }
    if kind == "team" and eid is not None:
        out["autocomplete"] = "team:%s " % eid
        out["mods"] = {
            "cmd": {
                "subtitle": "Show squad (same as Tab)",
                "arg": "team:%s" % eid,
                "variables": {
                    "sofa_title": title,
                    "sofa_kind": "browse_team",
                    "sofa_id": str(eid),
                    "sofa_sport": sport or "football",
                },
            }
        }
    if kind in ("uniqueTournament", "tournament", "league") and eid is not None:
        out["autocomplete"] = "league:%s " % eid
        out["mods"] = {
            "cmd": {
                "subtitle": "Show teams (same as Tab)",
                "arg": "league:%s" % eid,
                "variables": {
                    "sofa_title": title,
                    "sofa_kind": "browse_league",
                    "sofa_id": str(eid),
                    "sofa_sport": sport or "football",
                },
            }
        }
    return out

def load_recents():
    path = recents_file()
    if path is None or not path.exists():
        return []
    try:
        return json.loads(path.read_text())
    except Exception:
        return []

def lookup_hit_by_id(eid):
    """Find cached metadata for a team/league id from the last result list."""
    if eid in (None, ""):
        return None
    sid = str(eid)
    path = hits_path()
    if path is None or not path.exists():
        return None
    try:
        cache = json.loads(path.read_text())
    except Exception:
        return None
    # Prefer exact kind matches later; any id match is fine
    for row in cache.values():
        if str(row.get("id") or "") == sid:
            return row
    return None

def remember_browse(kind, eid, title=None, url=None, sport="football"):
    """Save a team/league when Tab drills in (Script Filter runs; Open action does not)."""
    path = recents_file()
    if path is None:
        return
    # Only on the initial drill-in, not every filter keystroke
    if (os.environ.get("SOFA_NAME_FILTER") or "").strip():
        return
    hit = lookup_hit_by_id(eid) or {}
    title = title or hit.get("title") or ("%s %s" % (kind, eid))
    sport = sport or hit.get("sport") or "football"
    url = url or hit.get("url")
    if not url:
        if kind == "team":
            url = "https://www.sofascore.com/football/team/x/%s" % eid
        else:
            url = "https://www.sofascore.com/football/tournament/x/%s" % eid
    try:
        recents = load_recents()
    except Exception:
        recents = []
    recents = [r for r in recents if r.get("url") != url and str(r.get("id") or "") != str(eid)]
    entry = {"url": url, "title": title, "kind": kind, "sport": sport, "id": int(eid) if str(eid).isdigit() else eid}
    recents.insert(0, entry)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(recents[:20], indent=2))
    except Exception:
        pass


def sport_of(ent, default="football"):
    if isinstance(ent.get("sport"), dict) and ent["sport"].get("slug"):
        return ent["sport"]["slug"]
    cat = ent.get("category")
    if isinstance(cat, dict) and isinstance(cat.get("sport"), dict):
        return cat["sport"].get("slug") or default
    return default

def url_for(typ, ent):
    eid = ent.get("id")
    slug = ent.get("slug") or "x"
    sport = sport_of(ent)
    if typ == "team":
        return "https://www.sofascore.com/%s/team/%s/%s" % (sport, slug, eid), sport
    if typ == "player":
        return "https://www.sofascore.com/%s/player/%s/%s" % (sport, slug, eid), sport
    if typ in ("uniqueTournament", "tournament", "league"):
        return "https://www.sofascore.com/%s/tournament/%s/%s" % (sport, slug, eid), sport
    if typ == "manager":
        return "https://www.sofascore.com/%s/manager/%s/%s" % (sport, slug, eid), sport
    if typ == "event":
        custom = ent.get("customId")
        if custom:
            return "https://www.sofascore.com/%s/match/%s/%s" % (sport, slug, custom), sport
        return "https://www.sofascore.com/%s/match/%s/%s" % (sport, slug, eid), sport
    return "https://www.sofascore.com/", sport

if mode == "recents":
    items = []
    for row in load_recents()[:15]:
        url = row.get("url") or "https://www.sofascore.com/"
        title = row.get("title") or url
        kind = row.get("kind") or "recent"
        eid = row.get("id")
        sport = row.get("sport") or "football"
        it = item(url, title, kind, eid, sport, "recent · %s" % kind)
        if kind == "team" and eid is not None:
            it["autocomplete"] = "team:%s " % eid
        if kind in ("uniqueTournament", "tournament", "league") and eid is not None:
            it["autocomplete"] = "league:%s " % eid
        items.append(it)
    if not items:
        items = [{
            "title": "No recent Sofascore searches yet",
            "subtitle": "Try: sofa liverpool — Tab on a team or league",
            "valid": False,
        }]
    emit(items)
    raise SystemExit

GUIDE_URL = "https://forum.actions.work/t/how-to-enable-allow-javascript-from-apple-events-in-your-browsers/87"
browser_name = (os.environ.get("SOFA_BROWSER") or "").strip() or "the browser"

if raw.startswith("AS_ERROR::"):
    detail = raw.split("::", 1)[1].strip()
    low = detail.lower()
    js_disabled = (
        not detail
        or "javascript" in low
        or "apple event" in low
        or "not authorized" in low
        or "not allowed" in low
        or "-1743" in low
    )
    if js_disabled:
        title = "Allow JavaScript from Apple Events"
        subtitle = "↩ Open setup guide (Chrome, Safari, Edge, Brave, Chromium, Vivaldi)"
    else:
        title = "Couldn’t control %s" % browser_name
        subtitle = (detail or "↩ Open setup guide")[:140]
    emit([{
        "title": title,
        "subtitle": subtitle,
        "arg": GUIDE_URL,
        "valid": True,
    }])
    raise SystemExit

if raw.startswith("JS_ERROR"):
    emit([{
        "title": "JavaScript error in %s" % browser_name,
        "subtitle": raw.split("\n", 1)[-1][:160],
        "valid": False,
    }])
    raise SystemExit

if "\n" in raw:
    status, body = raw.split("\n", 1)
else:
    status, body = "?", raw
status, body = status.strip(), body.strip()
if status not in ("200", "201") or not body:
    emit([{
        "title": "Sofascore HTTP %s" % status,
        "subtitle": (body or ("empty — open sofascore.com in %s" % browser_name))[:160],
        "valid": False,
    }])
    raise SystemExit

try:
    data = json.loads(body)
except Exception:
    emit([{"title": "Bad JSON from Sofascore", "subtitle": body[:140], "valid": False}])
    raise SystemExit

items = []
needle = (os.environ.get("SOFA_NAME_FILTER") or "").strip().lower()

if mode == "team_players":
    players = data.get("players") or []
    tid = os.environ.get("SOFA_TEAM_ID") or ""
    remember_browse("team", tid)
    for row in players:
        ent = row.get("player") if isinstance(row, dict) and "player" in row else row
        if not isinstance(ent, dict):
            continue
        name = ent.get("name") or ent.get("shortName") or "Player"
        short = ent.get("shortName") or ""
        hay = ("%s %s" % (name, short)).lower()
        if needle and needle not in hay:
            continue
        href, sport = url_for("player", ent)
        bits = ["player"]
        if isinstance(ent.get("country"), dict) and ent["country"].get("name"):
            bits.append(ent["country"]["name"])
        pos = row.get("position") if isinstance(row, dict) else None
        if pos:
            bits.append(str(pos))
        it = item(href, name, "player", ent.get("id"), sport, " · ".join(bits))
        it["autocomplete"] = ("team:%s %s" % (tid, name)).strip()
        items.append(it)
    if not items:
        if needle:
            items = [{"title": "No players matching “%s”" % needle, "subtitle": "Team %s" % tid, "valid": False}]
        else:
            items = [{"title": "No players returned", "subtitle": "Team id %s" % tid, "valid": False}]
    emit(items)
    raise SystemExit

if mode == "league_teams":
    teams = data.get("teams") or []
    lid = os.environ.get("SOFA_LEAGUE_ID") or ""
    remember_browse("uniqueTournament", lid)
    for ent in teams:
        if not isinstance(ent, dict):
            continue
        name = ent.get("name") or ent.get("shortName") or "Team"
        short = ent.get("shortName") or ""
        hay = ("%s %s" % (name, short)).lower()
        if needle and needle not in hay:
            continue
        href, sport = url_for("team", ent)
        bits = ["team"]
        if isinstance(ent.get("country"), dict) and ent["country"].get("name"):
            bits.append(ent["country"]["name"])
        bits.append("Tab = squad")
        it = item(href, name, "team", ent.get("id"), sport, " · ".join(bits))
        # Keep league prefix while filtering; Tab on a team still drills to squad
        it["autocomplete"] = "team:%s " % ent.get("id")
        # But while typing a league filter, Alfred uses the query string — autocomplete only on Tab
        items.append(it)
    # Sort by name for easier scanning
    items.sort(key=lambda x: (x.get("title") or "").lower())
    if not items:
        if needle:
            items = [{"title": "No teams matching “%s”" % needle, "subtitle": "League %s" % lid, "valid": False}]
        else:
            items = [{"title": "No teams returned", "subtitle": "League id %s" % lid, "valid": False}]
    emit(items)
    raise SystemExit

results = data.get("results") if isinstance(data, dict) else None
if not results:
    emit([{"title": "No results", "subtitle": "Try another query", "valid": False}])
    raise SystemExit

for row in results[:12]:
    typ = row.get("type") or "unknown"
    ent = row.get("entity") or {}
    name = ent.get("name") or ent.get("shortName") or "Unknown"
    href, sport = url_for(typ, ent)
    bits = [typ]
    if isinstance(ent.get("country"), dict) and ent["country"].get("name"):
        bits.append(ent["country"]["name"])
    cat = ent.get("category")
    if isinstance(cat, dict) and cat.get("name"):
        bits.append(cat["name"])
    if isinstance(ent.get("team"), dict) and ent["team"].get("name"):
        bits.append(ent["team"]["name"])
    if isinstance(ent.get("sport"), dict) and ent["sport"].get("name"):
        bits.append(ent["sport"]["name"])
    if typ == "team":
        bits.append("Tab = squad")
    if typ in ("uniqueTournament", "tournament"):
        bits.append("Tab = teams")
    items.append(item(href, name, typ, ent.get("id"), sport, " · ".join(bits)))

emit(items or [{"title": "No parseable results", "valid": False}])
