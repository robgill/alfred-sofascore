#!/bin/bash
# Selection and AppleScript-shape tests. Uses tests/bin/osascript instead of macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/tests/bin:$PATH"
export FAKE_OSASCRIPT_LOG="$(mktemp)"
export SOFA_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/sofascore_search.sh"

export SOFA_BUNDLE_ROOT
SOFA_BUNDLE_ROOT="$(mktemp -d)"
# Keep the real disk check, and point it at bundles created from FAKE_INSTALLED.
eval "$(declare -f browser_on_disk | sed '1s/browser_on_disk/browser_on_disk_impl/')"
materialize_fake_apps() {
  local root="$SOFA_BUNDLE_ROOT" name
  rm -rf "$root"
  mkdir -p "$root/Applications" "$root/Home/Applications" "$root/System/Applications"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      Safari)
        mkdir -p "$root/System/Applications/Safari.app"
        ;;
      *)
        mkdir -p "$root/Applications/${name}.app"
        ;;
    esac
  done <<< "${FAKE_INSTALLED-}"
}
browser_on_disk() {
  materialize_fake_apps
  browser_on_disk_impl "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf '%s\n' '--- log ---' >&2
  cat "$FAKE_OSASCRIPT_LOG" >&2 || true
  exit 1
}

reset_state() {
  unset SOFA_CHOSEN_BROWSER SOFA_BROWSER SOFA_RUNNING SOFA_INSTALLED sofa_browser || true
  SOFA_CHOSEN_BROWSER=""
  SOFA_BROWSER=""
  export FAKE_RUNNING=""
  export FAKE_INSTALLED=""
  export FAKE_TABS=""
  unset FAKE_XHR_FAIL FAKE_XHR_AS_ERROR || true
  FAKE_XHR_FAIL=""
  FAKE_XHR_AS_ERROR=""
  export FAKE_XHR_BODY=$'200\n{"results":[]}'
  : > "$FAKE_OSASCRIPT_LOG"
}

xhr_scripts() {
  awk 'BEGIN{p=0} /^===== CALL =====$/{buf=""; p=1; next} /^===== END =====$/{if (p && (buf ~ /execute / || buf ~ /do JavaScript/)) {print buf; print "\034"} p=0; next} p{buf = buf $0 "\n"}' "$FAKE_OSASCRIPT_LOG"
}

probe_apps() {
  awk 'BEGIN{p=0} /^===== CALL =====$/{buf=""; p=1; next} /^===== END =====$/{if (p && buf ~ /contains "sofascore.com"/ && buf !~ /execute / && buf !~ /do JavaScript/) print buf; p=0; next} p{buf = buf $0 "\n"}' "$FAKE_OSASCRIPT_LOG" \
    | sed -n 's/.*tell application "\([^"]*\)".*/\1/p'
}

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" != "$want" ]; then
    printf 'got: [%s]\nwant: [%s]\n' "$got" "$want" >&2
    fail "$msg"
  fi
}

# 1. Existing Sofascore tab wins over a running Chrome with no tab.
reset_state
export FAKE_RUNNING=$'Google Chrome\nSafari'
export FAKE_INSTALLED=$'Google Chrome\nSafari'
export FAKE_TABS="Safari"
export sofa_browser="auto"
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "Safari" "existing Safari tab should win"
browser_xhr "/api/v1/search/all?q=liverpool" >/dev/null
xhr="$(xhr_scripts)"
printf '%s' "$xhr" | grep -q 'tell application "Safari"' || fail "safari tell missing"
printf '%s' "$xhr" | grep -q 'do JavaScript' || fail "safari should do JavaScript"
printf '%s' "$xhr" | grep -q 'execute ' && fail "safari script must not execute javascript" || true
printf '%s' "$xhr" | grep -q 'current tab' || fail "safari should restore current tab"
printf '%s' "$xhr" | grep -q 'active tab' && fail "safari has no active tab property" || true
printf '%s' "$xhr" | grep -q 'activate' && fail "safari script should not activate" || true
probes="$(probe_apps | tr '\n' ' ')"
printf '%s' "$probes" | grep -q "Google Chrome" || fail "should probe running Chrome first"
printf '%s' "$probes" | grep -q "Safari" || fail "should probe Safari"
# Edge was not running, so it must not be told (that would launch it).
printf '%s\n' "$probes" | grep -qx "Microsoft Edge" && fail "must not probe Edge when it is not running" || true

# 2. Configured browser does not override a tab that already exists elsewhere.
reset_state
export FAKE_RUNNING=$'Safari\nVivaldi'
export FAKE_INSTALLED=$'Safari\nVivaldi\nGoogle Chrome'
export FAKE_TABS="Safari"
export sofa_browser="Vivaldi"
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "Safari" "existing tab beats browser preference"

# 3. Preference is used when nobody has a Sofascore tab, even if it is not running.
reset_state
export FAKE_RUNNING=$'Google Chrome\nSafari'
export FAKE_INSTALLED=$'Google Chrome\nSafari\nMicrosoft Edge'
export FAKE_TABS=""
export sofa_browser="edge"
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "Microsoft Edge" "edge alias should select Microsoft Edge"
browser_xhr "/api/v1/team/1/players" >/dev/null
xhr="$(xhr_scripts)"
printf '%s' "$xhr" | grep -q 'tell application "Microsoft Edge"' || fail "edge tell missing"
printf '%s' "$xhr" | grep -q 'mode:normal' && fail "mode:normal is Chrome-only so other dictionaries still compile" || true
printf '%s' "$xhr" | grep -q 'execute targetTab javascript' || fail "edge should use execute javascript"
printf '%s' "$xhr" | grep -q 'set active tab of w to previousTab' || fail "edge should restore the previous tab"
printf '%s' "$xhr" | grep -q 'make new tab with properties {URL:"https://www.sofascore.com/"}' || fail "edge should open sofascore"
printf '%s' "$xhr" | grep -q 'activate' && fail "chromium script should not activate" || true
printf '%s' "$xhr" | grep -q 'do JavaScript' && fail "edge is not Safari" || true
# Preference was not running, so it was not probed.
probe_apps | grep -qx "Microsoft Edge" && fail "must not probe a browser that is not running" || true

# 4. Automatic: first running browser in Chrome, Edge, Brave, Chromium, Vivaldi, Safari order.
reset_state
export FAKE_RUNNING=$'Vivaldi\nBrave Browser'
export FAKE_INSTALLED=$'Vivaldi\nBrave Browser\nSafari'
export sofa_browser="automatic"
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "Brave Browser" "Brave should beat Vivaldi when both are running"

# 5. Nothing running: Chrome if installed, else a third-party browser before stock Safari.
reset_state
export FAKE_RUNNING=""
export FAKE_INSTALLED=$'Safari\nVivaldi'
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "Vivaldi" "installed Vivaldi should beat always-present Safari"

reset_state
export FAKE_RUNNING=""
export FAKE_INSTALLED=$'Safari\nGoogle Chrome'
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "Google Chrome" "Chrome is the preferred installed default"

reset_state
export FAKE_RUNNING=""
export FAKE_INSTALLED="Safari"
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "Safari" "Safari is used when it is the only browser"

# 6. Nothing on disk: do not invent Google Chrome (that tell opens "Where is …?").
reset_state
export FAKE_RUNNING=""
export FAKE_INSTALLED=""
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "" "must not invent a browser that is not on disk"
browser_xhr "/api/v1/search/all?q=liverpool" >/dev/null
if grep 'tell application' "$FAKE_OSASCRIPT_LOG" | grep -v 'System Events' | grep -q .; then
  fail "must not tell a browser when none is on disk"
fi
if grep -q 'Microsoft Edge' "$FAKE_OSASCRIPT_LOG" || grep -q 'Google Chrome' "$FAKE_OSASCRIPT_LOG"; then
  fail "must not name a missing browser in AppleScript"
fi

# 7. JS payload stays a synchronous same-origin XHR.
reset_state
export FAKE_RUNNING="Chromium"
export FAKE_INSTALLED="Chromium"
export FAKE_TABS="Chromium"
export sofa_browser="Chromium"
ensure_browser
browser_xhr '/api/v1/search/all?q=a"b' >/dev/null
js="$(awk 'BEGIN{p=0} /^----- JS -----$/{p=1; next} /^===== END =====$/{p=0} p{print}' "$FAKE_OSASCRIPT_LOG")"
printf '%s' "$js" | grep -q 'XMLHttpRequest' || fail "xhr missing"
printf '%s' "$js" | grep -F -q 'X-Requested-With' || fail "missing X-Requested-With"
printf '%s' "$js" | grep -F -q 'Accept' || fail "missing Accept"
printf '%s' "$js" | grep -F -q ', false)' || fail "XHR must be synchronous"
printf '%s' "$js" | grep -F -q '/api/v1/search/all?q=a\"b' || fail "quote in path must be JSON-escaped inside JS"

# 8. Choosing a browser is cached for the second request (league seasons + teams).
reset_state
export FAKE_RUNNING="Google Chrome"
export FAKE_INSTALLED="Google Chrome"
export FAKE_TABS="Google Chrome"
calls_before="$(grep -c 'System Events' "$FAKE_OSASCRIPT_LOG" || true)"
ensure_browser
browser_xhr "/api/v1/unique-tournament/8/seasons" >/dev/null
# Command substitution is how the Script Filter captures each response.
browser_xhr "/api/v1/unique-tournament/8/season/1/teams" >/dev/null
captured="$(browser_xhr "/api/v1/unique-tournament/8/season/1/teams")"
printf '%s' "$captured" | grep -q '200' || fail "captured xhr status missing"
events="$(grep -c 'System Events' "$FAKE_OSASCRIPT_LOG" || true)"
assert_eq "$events" "1" "running-browser scan should happen once"
xhr_count="$(xhr_scripts | awk 'BEGIN{n=0} /\034/{n++} END{print n}')"
assert_eq "$xhr_count" "3" "repeat fetches must not scan browsers again"
printf '%s' "$(xhr_scripts)" | grep -q 'mode:normal' || fail "Chrome should still open a normal window"

# 9. Apple Events failure becomes AS_ERROR and the formatter keeps the guide URL.
reset_state
export FAKE_RUNNING="Brave Browser"
export FAKE_INSTALLED="Brave Browser"
export FAKE_TABS="Brave Browser"
export sofa_browser="Brave Browser"
export FAKE_XHR_AS_ERROR="Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events."
data="$(mktemp -d)"
cache="$(mktemp -d)"
export alfred_workflow_data="$data"
export alfred_workflow_cache="$cache"
out="$(main "arsenal")"
printf '%s' "$out" | grep -q 'how-to-enable-allow-javascript-from-apple-events-in-your-browsers/87' || fail "guide URL missing"
printf '%s' "$out" | grep -q 'Allow JavaScript from Apple Events' || fail "guide title missing"
printf '%s' "$out" | grep -q '"valid": true' || fail "guide item should be actionable with return"

# 10. A non-JS osascript failure is still returned, with the guide as the action.
reset_state
export FAKE_RUNNING="Vivaldi"
export FAKE_INSTALLED="Vivaldi"
export FAKE_TABS=""
export sofa_browser="Vivaldi"
export FAKE_XHR_FAIL="execution error: Vivaldi got an error: Application isn’t running. (-600)"
out="$(main "chelsea")"
printf '%s' "$out" | grep -q 'how-to-enable-allow-javascript-from-apple-events-in-your-browsers/87' || fail "non-js failure should still link the guide"
printf '%s' "$out" | grep -q 'control Vivaldi' || fail "non-js failure should name Vivaldi"

# 11. osascript non-zero during XHR is wrapped, and a league drill stops after the first failure.
reset_state
export FAKE_RUNNING="Microsoft Edge"
export FAKE_INSTALLED="Microsoft Edge"
export FAKE_TABS="Microsoft Edge"
export sofa_browser="auto"
export FAKE_XHR_FAIL="execution error: not allowed (-1743)"
out="$(main "league:42")"
printf '%s' "$out" | grep -q 'Allow JavaScript from Apple Events' || fail "1743 should look like an Apple Events setup error"
xhr_count="$(xhr_scripts | awk 'BEGIN{n=0} /\034/{n++} END{print n}')"
assert_eq "$xhr_count" "1" "league fetch should not send a second XHR after AS_ERROR"

# 12. Cached squad filter does not talk to a browser. Successful search still formats JSON.
reset_state
export FAKE_RUNNING="Google Chrome"
export FAKE_INSTALLED="Google Chrome"
export FAKE_TABS="Google Chrome"
export FAKE_XHR_BODY=$'200\n{"results":[{"type":"team","entity":{"id":44,"name":"Liverpool","slug":"liverpool","sport":{"slug":"football"}}}]}'
out="$(main "liverpool")"
printf '%s' "$out" | grep -q 'Liverpool' || fail "search result was not formatted"
mkdir -p "$cache"
printf '%s' '{"players":[]}' > "$cache/squad_44.json"
: > "$FAKE_OSASCRIPT_LOG"
out="$(main "team:44 rash")"
printf '%s' "$out" | grep -q 'No players matching' || fail "cached squad filter failed"
if [ -s "$FAKE_OSASCRIPT_LOG" ]; then
  fail "cached squad filter must not call osascript"
fi

# 13. Source is not a Chrome-only tell.
if grep -q 'tell application "Google Chrome"' "$ROOT/sofascore_search.sh"; then
  fail "source still hardcodes tell application \"Google Chrome\""
fi
grep -q 'do JavaScript' "$ROOT/sofascore_search.sh" || fail "source missing Safari do JavaScript"
grep -q 'execute targetTab javascript' "$ROOT/sofascore_search.sh" || fail "source missing Chromium execute"
for name in "Google Chrome" "Safari" "Microsoft Edge" "Brave Browser" "Chromium" "Vivaldi"; do
  grep -q "$name" "$ROOT/sofascore_search.sh" || fail "missing browser $name"
  grep -q "$name" "$ROOT/README.md" || fail "README missing $name"
  grep -q "$name" "$ROOT/info.plist" || fail "info.plist missing $name"
done
grep -q 'com.robgill.sofascore' "$ROOT/README.md" || fail "privacy bundle id missing"
grep -q 'alfred_workflow_data' "$ROOT/sofascore_search.sh" || fail "must read alfred_workflow_data"
grep -q 'alfred_workflow_cache' "$ROOT/sofascore_search.sh" || fail "must read alfred_workflow_cache"
if grep -q 'Application Support' "$ROOT/sofascore_search.sh" "$ROOT/_format_results.py" "$ROOT/open_and_remember.sh"; then
  fail "scripts must not hardcode Application Support"
fi
grep -q '<string>1.2.2</string>' "$ROOT/info.plist" || fail "version was not bumped"
if grep -q '<string>1.2.1</string>' "$ROOT/info.plist"; then
  fail "info.plist still says 1.2.1"
fi
if grep -v '^[[:space:]]*#' "$ROOT/sofascore_search.sh" | grep -q 'path to application'; then
  fail "sofascore_search.sh must not call path to application"
fi
grep -q 'browser_on_disk' "$ROOT/sofascore_search.sh" || fail "browser_on_disk missing"
grep -q 'path to application' "$ROOT/README.md" || fail "README should explain path to application"

# 14. Missing Alfred paths still produce a Script Filter item and do not exit the shell when main is a subprocess.
missing="$(env -u SOFA_SOURCE_ONLY -u alfred_workflow_data -u alfred_workflow_cache bash "$ROOT/sofascore_search.sh" "liverpool")"
printf '%s' "$missing" | grep -q 'Alfred did not set workflow paths' || fail "missing env should explain itself"

# 15. Empty and short queries open the homepage first; recents follow. Homepage is not saved.
reset_state
data="$(mktemp -d)"
cache="$(mktemp -d)"
export alfred_workflow_data="$data"
export alfred_workflow_cache="$cache"
cat > "$data/recents.json" <<'JSON'
[
  {"url": "https://www.sofascore.com/", "title": "Homepage leftover", "kind": "link"},
  {"url": "https://www.sofascore.com/football/team/liverpool/44", "title": "Liverpool", "kind": "team", "id": 44, "sport": "football"},
  {"url": "https://sofascore.com", "title": "Bare homepage", "kind": "link"}
]
JSON
before="$(cat "$data/recents.json")"
assert_recents_home() {
  local label="$1"
  python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
items = data["items"]
first = items[0]
if first.get("title") != "Open Sofascore" or first.get("arg") != "https://www.sofascore.com/" or first.get("valid") is not True:
    raise SystemExit("first item is not the homepage")
if first.get("subtitle") != "www.sofascore.com":
    raise SystemExit("homepage subtitle")
titles = [it.get("title") for it in items]
if "Homepage leftover" in titles or "Bare homepage" in titles:
    raise SystemExit("homepage recent was listed")
if titles[1] != "Liverpool":
    raise SystemExit("recent did not follow homepage: %s" % titles)
' <<<"$2" || fail "$label"
}
out="$(main "")"
assert_recents_home "empty query" "$out"
out="$(main " ")"
assert_recents_home "blank query" "$out"
out="$(main "s")"
assert_recents_home "one-character query" "$out"
rm -f "$data/recents.json"
out="$(main "")"
python3 -c '
import json, sys
items = json.loads(sys.stdin.read())["items"]
if items[0].get("title") != "Open Sofascore" or items[0].get("valid") is not True:
    raise SystemExit("empty recents missing homepage")
if items[1].get("title") != "No recent Sofascore searches yet" or items[1].get("valid") is not False:
    raise SystemExit("empty recents hint missing")
if len(items) != 2:
    raise SystemExit("unexpected empty recents items")
' <<<"$out" || fail "no recents yet"

open_dir="$(mktemp -d)"
export OPEN_LOG="$(mktemp)"
cat > "$open_dir/open" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${OPEN_LOG:?}"
EOF
chmod +x "$open_dir/open"
export PATH="$open_dir:$ROOT/tests/bin:$PATH"
printf '%s\n' "$before" > "$data/recents.json"
for u in \
  "https://www.sofascore.com/" \
  "https://www.sofascore.com" \
  "http://www.sofascore.com/" \
  "https://sofascore.com/" \
  "http://sofascore.com" \
  "HTTPS://WWW.SOFASCORE.COM/"
do
  : > "$OPEN_LOG"
  alfred_workflow_data="$data" "$ROOT/open_and_remember.sh" "$u"
  if [ "$(cat "$data/recents.json")" != "$before" ]; then
    fail "homepage variant was saved: $u"
  fi
  assert_eq "$(cat "$OPEN_LOG")" "$u" "homepage variant was not opened: $u"
done
guide="https://forum.actions.work/t/how-to-enable-allow-javascript-from-apple-events-in-your-browsers/87"
: > "$OPEN_LOG"
alfred_workflow_data="$data" "$ROOT/open_and_remember.sh" "$guide"
if [ "$(cat "$data/recents.json")" != "$before" ]; then
  fail "setup guide was saved"
fi
: > "$OPEN_LOG"
alfred_workflow_data="$data" \
  sofa_title="Liverpool" sofa_kind="team" sofa_id="44" sofa_sport="football" \
  "$ROOT/open_and_remember.sh" "https://www.sofascore.com/football/team/liverpool/44"
python3 -c '
import json, os, sys
path = sys.argv[1]
recents = json.loads(open(path).read())
if not recents or recents[0].get("url") != "https://www.sofascore.com/football/team/liverpool/44":
    raise SystemExit("team url was not remembered")
if recents[0].get("title") != "Liverpool":
    raise SystemExit("team title")
' "$data/recents.json" || fail "opening a result should still save a recent"
assert_eq "$(cat "$OPEN_LOG")" "https://www.sofascore.com/football/team/liverpool/44" "team url was not opened"

# 16. A running or pinned browser that is not on disk is never named in AppleScript.
reset_state
export FAKE_RUNNING=$'Microsoft Edge\nGoogle Chrome'
export FAKE_INSTALLED="Google Chrome"
export FAKE_TABS=""
export sofa_browser="edge"
ensure_browser
assert_eq "$SOFA_CHOSEN_BROWSER" "Google Chrome" "missing Edge must fall through to Chrome on disk"
if grep -q 'Microsoft Edge' "$FAKE_OSASCRIPT_LOG"; then
  fail "AppleScript named Microsoft Edge even though it is not on disk"
fi
browser_xhr "/api/v1/search/all?q=bra" >/dev/null
if grep -q 'Microsoft Edge' "$FAKE_OSASCRIPT_LOG"; then
  fail "XHR named Microsoft Edge even though it is not on disk"
fi
printf '%s' "$(xhr_scripts)" | grep -q 'tell application "Google Chrome"' || fail "Chrome on disk should be told"

reset_state
export FAKE_INSTALLED="Safari"
export FAKE_RUNNING="Safari"
probe_tab "Microsoft Edge" && fail "probe_tab should refuse Edge when it is not on disk" || true
probe_tab "Brave Browser" && fail "probe_tab should refuse Brave when it is not on disk" || true
probe_tab "Vivaldi" && fail "probe_tab should refuse Vivaldi when it is not on disk" || true
if grep -q 'tell application' "$FAKE_OSASCRIPT_LOG"; then
  fail "probe_tab emitted tell application for a browser that is not on disk"
fi

for missing in "Microsoft Edge" "Brave Browser" "Chromium" "Vivaldi" "Safari"; do
  reset_state
  export FAKE_INSTALLED="Google Chrome"
  export SOFA_CHOSEN_BROWSER="$missing"
  export SOFA_BROWSER="$missing"
  browser_xhr "/api/v1/search/all?q=x" >/dev/null
  if grep -q "tell application \"$missing\"" "$FAKE_OSASCRIPT_LOG"; then
    fail "browser_xhr told $missing which is not on disk"
  fi
  if grep -q 'tell application "' "$FAKE_OSASCRIPT_LOG"; then
    fail "browser_xhr substituted another tell for missing $missing"
  fi
done

# 17. Known bundle paths, including Home Applications and System Safari.
path_root="$(mktemp -d)"
mkdir -p "$path_root/Home/Applications/Google Chrome.app"
mkdir -p "$path_root/System/Applications/Safari.app"
mkdir -p "$path_root/Applications/Brave Browser.app"
(
  SOFA_BUNDLE_ROOT="$path_root"
  browser_on_disk_impl "Google Chrome"
) || fail "Chrome in Home/Applications should count"
(
  SOFA_BUNDLE_ROOT="$path_root"
  browser_on_disk_impl "Safari"
) || fail "Safari in System/Applications should count"
(
  SOFA_BUNDLE_ROOT="$path_root"
  browser_on_disk_impl "Brave Browser"
) || fail "Brave in /Applications should count"
if (
  SOFA_BUNDLE_ROOT="$path_root"
  browser_on_disk_impl "Microsoft Edge"
); then
  fail "missing Edge bundle must not count as installed"
fi
mkdir -p "$path_root/Applications/Safari.app"
(
  SOFA_BUNDLE_ROOT="$path_root"
  browser_on_disk_impl "Safari"
) || fail "Safari in /Applications should count"
rm -rf "$path_root/System/Applications/Safari.app" "$path_root/Applications/Safari.app"
if (
  SOFA_BUNDLE_ROOT="$path_root"
  browser_on_disk_impl "Safari"
); then
  fail "Safari without a bundle must not count"
fi

# 18. A search with no bundle on disk explains itself and does not blame Chrome.
reset_state
export FAKE_RUNNING=""
export FAKE_INSTALLED=""
data="$(mktemp -d)"
cache="$(mktemp -d)"
export alfred_workflow_data="$data"
export alfred_workflow_cache="$cache"
out="$(main "arsenal")"
printf '%s' "$out" | grep -q 'No supported browser is installed' || fail "missing bundles should say no browser is installed"
printf '%s' "$out" | grep -q 'Where is' || fail "missing bundles should mention cancelling Where is dialogs"
printf '%s' "$out" | grep -q 'Google Chrome' && fail "must not claim it tried Google Chrome" || true
if grep 'tell application' "$FAKE_OSASCRIPT_LOG" | grep -v 'System Events' | grep -q .; then
  fail "main must not tell a browser when nothing is on disk"
fi

printf '%s\n' "ok"
