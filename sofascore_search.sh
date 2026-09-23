#!/bin/bash
# Sofascore search. Cloudflare blocks raw HTTP, so requests run as synchronous
# XHR in a sofascore.com tab via Apple Events.
#
# AppleScript (literal app names; a variable `tell` cannot see browser verbs):
#   Chromium family — `execute <tab> javascript`:
#     "Google Chrome", "Microsoft Edge", "Brave Browser", "Chromium", "Vivaldi"
#   Safari — `do JavaScript <js> in <tab>` and `current tab` (not `active tab`).
# Existing tabs are reused and the browser is not activated. A new window is
# only created when that browser has none (macOS will focus it in that case).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preference order when several browsers qualify. Safari is last because it
# ships on every Mac and would otherwise hide a browser the user installed.
# Google Chrome remains the last-known-good name if nothing is installed.
BROWSER_ORDER=(
  "Google Chrome"
  "Microsoft Edge"
  "Brave Browser"
  "Chromium"
  "Vivaldi"
  "Safari"
)

is_supported_app() {
  case "$1" in
    "Google Chrome"|"Microsoft Edge"|"Brave Browser"|"Chromium"|"Vivaldi"|"Safari")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

browser_family() {
  if [ "$1" = "Safari" ]; then
    printf '%s' "safari"
  else
    printf '%s' "chromium"
  fi
}

# Workflow Configuration `sofa_browser`. Empty means Automatic.
normalize_browser_pref() {
  local pref
  pref="$(printf '%s' "${sofa_browser:-auto}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$pref" in
    ""|auto|automatic|default) printf '%s' "" ;;
    chrome|"google chrome") printf '%s' "Google Chrome" ;;
    safari) printf '%s' "Safari" ;;
    edge|"microsoft edge"|"ms edge") printf '%s' "Microsoft Edge" ;;
    brave|"brave browser") printf '%s' "Brave Browser" ;;
    chromium) printf '%s' "Chromium" ;;
    vivaldi) printf '%s' "Vivaldi" ;;
    *) printf '%s' "" ;;
  esac
}

app_in_list() {
  local needle="$1"
  local list="$2"
  [ -n "$needle" ] || return 1
  printf '%s\n' "$list" | grep -Fxq -- "$needle"
}

invoke_osascript() {
  # $1 script file, $2 optional JS argument (passed to `on run argv`)
  local script="$1"
  local js="${2:-}"
  local err
  err="$(mktemp)"
  SOFA_OSA_OUT=""
  SOFA_OSA_ERR=""
  SOFA_OSA_STATUS=0
  set +e
  if [ -n "$js" ]; then
    SOFA_OSA_OUT="$(osascript "$script" "$js" 2>"$err")"
  else
    SOFA_OSA_OUT="$(osascript "$script" 2>"$err")"
  fi
  SOFA_OSA_STATUS=$?
  set -e
  # tr -s is portable across macOS bash; GNU sed's \+ is not.
  SOFA_OSA_ERR="$(tr '\n' ' ' < "$err" | tr -s '[:space:]' ' ')"
  SOFA_OSA_ERR="${SOFA_OSA_ERR# }"
  SOFA_OSA_ERR="${SOFA_OSA_ERR% }"
  rm -f "$err"
}

load_running() {
  local script
  script="$(mktemp)"
  cat > "$script" <<'APPLESCRIPT'
tell application "System Events"
  set procNames to name of every process
end tell
set AppleScript's text item delimiters to linefeed
return procNames as text
APPLESCRIPT
  invoke_osascript "$script"
  rm -f "$script"
  if [ "$SOFA_OSA_STATUS" -ne 0 ]; then
    SOFA_RUNNING=""
    return
  fi
  SOFA_RUNNING="$SOFA_OSA_OUT"
}

load_installed() {
  local script
  script="$(mktemp)"
  cat > "$script" <<'APPLESCRIPT'
set names to {"Google Chrome", "Microsoft Edge", "Brave Browser", "Chromium", "Vivaldi", "Safari"}
set found to {}
repeat with n in names
  try
    set p to POSIX path of (path to application (contents of n))
    if p is not missing value and p is not "" then set end of found to (contents of n)
  end try
end repeat
if (count of found) is 0 then return ""
set AppleScript's text item delimiters to linefeed
return found as text
APPLESCRIPT
  invoke_osascript "$script"
  rm -f "$script"
  if [ "$SOFA_OSA_STATUS" -ne 0 ]; then
    SOFA_INSTALLED=""
    return
  fi
  SOFA_INSTALLED="$SOFA_OSA_OUT"
}

# YES if a running browser already has a sofascore.com tab. Does not launch.
probe_tab() {
  local app="$1"
  local script out
  is_supported_app "$app" || return 1
  script="$(mktemp)"
  cat > "$script" <<APPLESCRIPT
tell application "$app"
  if (count of windows) = 0 then return "NO"
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          if (URL of t) contains "sofascore.com" then return "YES"
        end try
      end repeat
    end try
  end repeat
end tell
return "NO"
APPLESCRIPT
  invoke_osascript "$script"
  rm -f "$script"
  if [ "$SOFA_OSA_STATUS" -ne 0 ]; then
    return 1
  fi
  out="$(printf '%s' "$SOFA_OSA_OUT" | tr -d '[:space:]')"
  [ "$out" = "YES" ]
}

choose_browser() {
  local pref b
  pref="$(normalize_browser_pref)"
  load_running

  if [ -n "$pref" ] && app_in_list "$pref" "$SOFA_RUNNING" && probe_tab "$pref"; then
    printf '%s' "$pref"
    return
  fi
  for b in "${BROWSER_ORDER[@]}"; do
    if [ "$b" = "$pref" ]; then
      continue
    fi
    if app_in_list "$b" "$SOFA_RUNNING" && probe_tab "$b"; then
      printf '%s' "$b"
      return
    fi
  done

  load_installed
  if [ -n "$pref" ] && app_in_list "$pref" "$SOFA_INSTALLED"; then
    printf '%s' "$pref"
    return
  fi
  for b in "${BROWSER_ORDER[@]}"; do
    if app_in_list "$b" "$SOFA_RUNNING"; then
      printf '%s' "$b"
      return
    fi
  done
  for b in "${BROWSER_ORDER[@]}"; do
    if app_in_list "$b" "$SOFA_INSTALLED"; then
      printf '%s' "$b"
      return
    fi
  done
  printf '%s' "Google Chrome"
}

ensure_browser() {
  if [ -z "${SOFA_CHOSEN_BROWSER:-}" ]; then
    SOFA_CHOSEN_BROWSER="$(choose_browser)"
    export SOFA_CHOSEN_BROWSER
    export SOFA_BROWSER="$SOFA_CHOSEN_BROWSER"
  fi
}

xhr_javascript() {
  SOFA_API_PATH="$1" python3 -c '
import json, os
path = os.environ["SOFA_API_PATH"]
print(
    "(() => { try { var x=new XMLHttpRequest(); x.open(\"GET\", %s, false);"
    " x.setRequestHeader(\"X-Requested-With\",\"XMLHttpRequest\");"
    " x.setRequestHeader(\"Accept\",\"*/*\"); x.send(null);"
    " return String(x.status)+String.fromCharCode(10)+x.responseText;"
    " } catch(e) { return \"JS_ERROR\"+String.fromCharCode(10)+String(e); } })()"
    % json.dumps(path)
)
'
}

write_chromium_script() {
  local app="$1"
  local script="$2"
  # `mode:normal` is in Chrome's dictionary. Other Chromium browsers share
  # `execute javascript` but a missing `mode` term fails compilation, not the try.
  local new_window="make new window"
  if [ "$app" = "Google Chrome" ]; then
    new_window="make new window with properties {mode:normal}"
  fi
  cat > "$script" <<APPLESCRIPT
on run argv
  set jsCode to item 1 of argv
  try
    tell application "$app"
      if (count of windows) = 0 then
        $new_window
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

      return execute targetTab javascript jsCode
    end tell
  on error errMsg
    return "AS_ERROR::" & errMsg
  end try
end run
APPLESCRIPT
}

write_safari_script() {
  local script="$1"
  cat > "$script" <<'APPLESCRIPT'
on run argv
  set jsCode to item 1 of argv
  try
    tell application "Safari"
      if (count of windows) = 0 then
        make new document with properties {URL:"https://www.sofascore.com/"}
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
        set previousTab to current tab of w
        tell w
          set targetTab to make new tab with properties {URL:"https://www.sofascore.com/"}
        end tell
        try
          set current tab of w to previousTab
        end try
        delay 3
      end if

      return do JavaScript jsCode in targetTab
    end tell
  on error errMsg
    return "AS_ERROR::" & errMsg
  end try
end run
APPLESCRIPT
}

browser_xhr() {
  local api_path="$1"
  local app family script js
  if [ -z "${SOFA_CHOSEN_BROWSER:-}" ]; then
    SOFA_CHOSEN_BROWSER="$(choose_browser)"
  fi
  app="$SOFA_CHOSEN_BROWSER"
  if ! is_supported_app "$app"; then
    printf '%s' "AS_ERROR::No supported browser is available"
    return 0
  fi
  family="$(browser_family "$app")"
  js="$(xhr_javascript "$api_path")"
  script="$(mktemp)"
  if [ "$family" = "safari" ]; then
    write_safari_script "$script"
  else
    write_chromium_script "$app" "$script"
  fi
  invoke_osascript "$script" "$js"
  rm -f "$script"
  if [ "$SOFA_OSA_STATUS" -ne 0 ]; then
    printf 'AS_ERROR::%s' "${SOFA_OSA_ERR:-Apple Events failed}"
    return 0
  fi
  printf '%s' "$SOFA_OSA_OUT"
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
  ensure_browser
  seasons_raw="$(browser_xhr "/api/v1/unique-tournament/${lid}/seasons")"
  if [[ "$seasons_raw" == AS_ERROR::* || "$seasons_raw" == JS_ERROR* ]]; then
    export SOFA_RAW="$seasons_raw"
    return
  fi
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
  export SOFA_RAW="$(browser_xhr "/api/v1/unique-tournament/${lid}/season/${season_id}/teams")"
}

main() {
  DATA_DIR="${alfred_workflow_data:-}"
  CACHE_DIR="${alfred_workflow_cache:-}"
  if [ -z "$DATA_DIR" ] || [ -z "$CACHE_DIR" ]; then
    printf '%s\n' '{"items":[{"title":"Alfred did not set workflow paths","subtitle":"alfred_workflow_data and alfred_workflow_cache must be set. Run this Script Filter from Alfred.","valid":false}]}'
    exit 0
  fi
  mkdir -p "$DATA_DIR" "$CACHE_DIR"

  query="${1:-}"
  query="$(printf "%s" "$query" | python3 -c "import sys; print(sys.stdin.read().strip())")"
  export SOFA_QUERY="$query"
  export SOFA_RECENTS="$DATA_DIR/recents.json"
  export SOFA_HITS="$DATA_DIR/last_hits.json"
  export SOFA_NAME_FILTER=""
  export SOFA_TEAM_ID=""
  export SOFA_LEAGUE_ID=""

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
    CACHE="$CACHE_DIR/squad_${SOFA_TEAM_ID}.json"
    if [ -n "${SOFA_NAME_FILTER}" ] && [ -f "$CACHE" ]; then
      export SOFA_RAW="200"$'\n'"$(cat "$CACHE")"
    else
      ensure_browser
      export SOFA_RAW="$(browser_xhr "/api/v1/team/${SOFA_TEAM_ID}/players")"
      save_json_cache "$CACHE"
    fi
  elif [[ "$query" == league:* ]]; then
    MODE="league_teams"
    REST="${query#league:}"
    export SOFA_LEAGUE_ID="${REST%% *}"
    if [[ "$REST" == *" "* ]]; then
      export SOFA_NAME_FILTER="$(printf "%s" "${REST#* }" | python3 -c "import sys; print(sys.stdin.read().strip())")"
    fi
    CACHE="$CACHE_DIR/league_${SOFA_LEAGUE_ID}_teams.json"
    if [ -n "${SOFA_NAME_FILTER}" ] && [ -f "$CACHE" ]; then
      export SOFA_RAW="200"$'\n'"$(cat "$CACHE")"
    else
      fetch_league_teams "$SOFA_LEAGUE_ID"
      save_json_cache "$CACHE"
    fi
  else
    ENC="$(python3 -c "import os,urllib.parse; print(urllib.parse.quote(os.environ[\"SOFA_QUERY\"]))")"
    ensure_browser
    export SOFA_RAW="$(browser_xhr "/api/v1/search/all?q=${ENC}")"
  fi
  export SOFA_MODE="$MODE"
  python3 "$DIR/_format_results.py"
}

if [ "${SOFA_SOURCE_ONLY:-}" != "1" ]; then
  main "$@"
fi
