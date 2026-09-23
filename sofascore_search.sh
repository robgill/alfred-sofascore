#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${alfred_workflow_data:-}"
if [ -z "$DATA_DIR" ]; then
  DATA_DIR="$HOME/Library/Application Support/Alfred/Workflow Data/com.robgill.sofascore"
fi
mkdir -p "$DATA_DIR"

query="${1:-}"
query="$(printf "%s" "$query" | python3 -c "import sys; print(sys.stdin.read().strip())")"
export SOFA_QUERY="$query"
export SOFA_RECENTS="$DATA_DIR/recents.json"
export SOFA_HITS="$DATA_DIR/last_hits.json"
export SOFA_NAME_FILTER=""
export SOFA_TEAM_ID=""
export SOFA_LEAGUE_ID=""

chrome_xhr() {
  export SOFA_PATH="$1"
  osascript <<'APPLESCRIPT'
set apiPath to do shell script "printf %s \"$SOFA_PATH\""
tell application "Google Chrome"
  if (count of windows) = 0 then
    make new window with properties {mode:normal}
    set URL of active tab of window 1 to "https://www.sofascore.com/"
    delay 3
  end if

  set targetTab to missing value
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          if (URL of t) contains "sofascore.com" then
            set targetTab to t
            exit repeat
          end if
        end try
      end repeat
    end try
    if targetTab is not missing value then exit repeat
  end repeat

  if targetTab is missing value then
    set w to window 1
    set previousTab to active tab of w
    tell w
      set targetTab to make new tab with properties {URL:"https://www.sofascore.com/"}
    end tell
    try
      set active tab of w to previousTab
    end try
    delay 3
  end if

  set js to "(() => { try { var x=new XMLHttpRequest(); x.open('GET'," & quoted form of apiPath & ",false); x.setRequestHeader('X-Requested-With','XMLHttpRequest'); x.setRequestHeader('Accept','*/*'); x.send(null); return String(x.status)+String.fromCharCode(10)+x.responseText; } catch(e) { return 'JS_ERROR'+String.fromCharCode(10)+String(e); } })()"
  try
    return execute targetTab javascript js
  on error errMsg
    return "AS_ERROR::" & errMsg
  end try
end tell
APPLESCRIPT
}

save_json_cache() {
  export SOFA_CACHE="$1"
  python3 -c "
import os, pathlib
raw = os.environ.get(\"SOFA_RAW\", \"\")
path = pathlib.Path(os.environ[\"SOFA_CACHE\"])
if \"\\n\" in raw:
    status, body = raw.split(\"\\n\", 1)
    if status.strip() == \"200\" and body.strip():
        path.write_text(body)
"
}

fetch_league_teams() {
  # $1 = unique tournament id → sets SOFA_RAW to teams JSON (200\\n...)
  local lid="$1"
  local seasons_raw season_id
  seasons_raw="$(chrome_xhr "/api/v1/unique-tournament/${lid}/seasons")"
  season_id="$(SOFA_SEASONS_RAW="$seasons_raw" python3 -c "
import os, json
raw = os.environ.get(\"SOFA_SEASONS_RAW\", \"\")
if \"\\n\" not in raw:
    raise SystemExit(\"\")
status, body = raw.split(\"\\n\", 1)
if status.strip() != \"200\":
    raise SystemExit(\"\")
data = json.loads(body)
seasons = data.get(\"seasons\") or []
print(seasons[0][\"id\"] if seasons else \"\")
")"
  if [ -z "$season_id" ]; then
    export SOFA_RAW="$seasons_raw"
    return
  fi
  export SOFA_RAW="$(chrome_xhr "/api/v1/unique-tournament/${lid}/season/${season_id}/teams")"
}

MODE="search"
if [ -z "$query" ] || [ ${#query} -lt 2 ]; then
  MODE="recents"
  export SOFA_RAW=""
elif [[ "$query" == team:* ]]; then
  MODE="team_players"
  REST="${query#team:}"
  export SOFA_TEAM_ID="${REST%% *}"
  if [[ "$REST" == *" "* ]]; then
    export SOFA_NAME_FILTER="$(printf "%s" "${REST#* }" | python3 -c "import sys; print(sys.stdin.read().strip())")"
  fi
  CACHE="$DATA_DIR/squad_${SOFA_TEAM_ID}.json"
  if [ -n "${SOFA_NAME_FILTER}" ] && [ -f "$CACHE" ]; then
    export SOFA_RAW="200"$'\n'"$(cat "$CACHE")"
  else
    export SOFA_RAW="$(chrome_xhr "/api/v1/team/${SOFA_TEAM_ID}/players")"
    save_json_cache "$CACHE"
  fi
elif [[ "$query" == league:* ]]; then
  MODE="league_teams"
  REST="${query#league:}"
  export SOFA_LEAGUE_ID="${REST%% *}"
  if [[ "$REST" == *" "* ]]; then
    export SOFA_NAME_FILTER="$(printf "%s" "${REST#* }" | python3 -c "import sys; print(sys.stdin.read().strip())")"
  fi
  CACHE="$DATA_DIR/league_${SOFA_LEAGUE_ID}_teams.json"
  if [ -n "${SOFA_NAME_FILTER}" ] && [ -f "$CACHE" ]; then
    export SOFA_RAW="200"$'\n'"$(cat "$CACHE")"
  else
    fetch_league_teams "$SOFA_LEAGUE_ID"
    save_json_cache "$CACHE"
  fi
else
  ENC="$(python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ[\"SOFA_QUERY\"]))")"
  export SOFA_RAW="$(chrome_xhr "/api/v1/search/all?q=${ENC}")"
fi
export SOFA_MODE="$MODE"
python3 "$DIR/_format_results.py"
