#!/bin/bash
# Remember + open. Only needs the URL in $1 (works without Alfred variables).
set -euo pipefail
arg="${1:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${alfred_workflow_data:-}"
if [ -z "$DATA_DIR" ]; then
  DATA_DIR="$HOME/Library/Application Support/Alfred/Workflow Data/com.robgill.sofascore"
fi
mkdir -p "$DATA_DIR"
RECENTS="$DATA_DIR/recents.json"
HITS="$DATA_DIR/last_hits.json"
KW="${sofa_keyword:-sofa}"

# Cmd+Enter / browse: team:ID or league:ID
if [[ "$arg" == team:* ]]; then
  tid="${arg#team:}"
  tid="${tid%% *}"
  osascript -e "tell application id \"com.runningwithcrayons.Alfred\" to search \"${KW} team:${tid} \"" >/dev/null 2>&1 || true
  exit 0
fi
if [[ "$arg" == league:* ]]; then
  lid="${arg#league:}"
  lid="${lid%% *}"
  osascript -e "tell application id \"com.runningwithcrayons.Alfred\" to search \"${KW} league:${lid} \"" >/dev/null 2>&1 || true
  exit 0
fi

url="$arg"
if [ -z "$url" ] || [[ "$url" != http* ]]; then
  exit 0
fi

# Setup guide — open only, do not pollute recents
if [[ "$url" == *"how-to-enable-allow-javascript-from-apple-events"* ]]; then
  open "$url"
  exit 0
fi

export SOFA_URL="$url"
export SOFA_RECENTS="$RECENTS"
export SOFA_HITS="$HITS"
export SOFA_TITLE="${sofa_title:-}"
export SOFA_KIND="${sofa_kind:-}"
export SOFA_ID="${sofa_id:-}"
export SOFA_SPORT="${sofa_sport:-}"

python3 <<'PY'
import json, os, pathlib, subprocess, re

url = os.environ["SOFA_URL"]
path = pathlib.Path(os.environ["SOFA_RECENTS"])
hits_path = pathlib.Path(os.environ["SOFA_HITS"])

title = os.environ.get("SOFA_TITLE") or ""
kind = os.environ.get("SOFA_KIND") or ""
sid = os.environ.get("SOFA_ID") or None
sport = os.environ.get("SOFA_SPORT") or ""

if hits_path.exists():
    try:
        hits = json.loads(hits_path.read_text())
        hit = hits.get(url) or {}
        title = title or hit.get("title") or ""
        kind = kind or hit.get("kind") or ""
        sid = sid or hit.get("id")
        sport = sport or hit.get("sport") or ""
    except Exception:
        pass

if not title:
    m = re.search(r"/(team|player|manager|tournament|match)/([^/]+)/", url)
    if m:
        kind = kind or m.group(1)
        title = m.group(2).replace("-", " ").title()
    else:
        title = url

if not kind:
    kind = "link"
if not sport:
    sport = "football"

recents = []
if path.exists():
    try:
        recents = json.loads(path.read_text())
    except Exception:
        recents = []

recents = [r for r in recents if r.get("url") != url]
entry = {"url": url, "title": title, "kind": kind, "sport": sport}
if sid not in (None, ""):
    try:
        entry["id"] = int(sid)
    except Exception:
        entry["id"] = sid
recents.insert(0, entry)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(recents[:20], indent=2))
subprocess.run(["open", url], check=False)
PY
