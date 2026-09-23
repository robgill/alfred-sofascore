# Sofascore Search for Alfred

Search Sofascore for teams, players, leagues, and matches from Alfred — without relying on the old `/search?q=` URL (Sofascore’s site no longer supports that).

![Demo](images/demo.gif)

**Download:** [Latest release](https://github.com/robgill/alfred-sofascore/releases/latest) (grab the `.alfredworkflow` file and double-click to install)

## Setup

Two tiny chores, then you’ll be up and searching:

1. **Allow JavaScript from Apple Events** in the browser you search with. Supported browsers are **Google Chrome**, **Safari**, **Microsoft Edge**, **Brave Browser**, **Chromium**, and **Vivaldi** — turn that setting on for whichever one you use. If you don't know how, hit ↩ on your first search and it will open the instructions.

2. **Keep a Sofascore tab open** in that browser. The first search opens the site in the background when it isn’t already open, and later searches reuse that tab. This shouldn’t interrupt your flow, but just be mindful of what is going on.

Sofascore’s API cannot be called with a direct request — Cloudflare blocks raw HTTP — so search runs as JavaScript inside a Sofascore tab.

Workflow Configuration has a **Browser** setting. Automatic reuses a supported browser that already has Sofascore open. If none does, it uses one that’s already running, then one that’s installed, and otherwise Google Chrome. Pin a browser there if you want a specific one when a new tab has to be opened.

That’s it. No API keys, no accounts. I hope this is useful. If so, consider following me on [X](https://x.com/rob_gill_) — I never post on there, but if you want to get in touch to let me know your thoughts, please do. ;)

## Usage

Keyword: `sofa` (changeable in Workflow Configuration, along with the browser)

* <kbd>↩</kbd> Open the result on Sofascore
* <kbd>⇥</kbd> Drill into a team’s squad, or a league’s clubs
* <kbd>⌘</kbd><kbd>↩</kbd> Same as Tab (squad / clubs)

After Tab on a team, type to filter players (for example `ma` for Marcus Rashford). After Tab on a league, type to filter clubs (for example `man` for Manchester City and Manchester United).

Tabbing into a team or league also saves it to recents. Type the keyword alone (with a trailing space) to browse them. ↩ opens the Sofascore homepage; arrow down or select a recent to open that result.

## Requirements

- [Alfred](https://www.alfredapp.com/) with Powerpack
- macOS
- Any one of Google Chrome, Safari, Microsoft Edge, Brave Browser, Chromium, or Vivaldi, with **Allow JavaScript from Apple Events** enabled
- A Sofascore tab in that browser (Cloudflare blocks a direct API client, so the request has to run in the page)
- System `python3` (no pip/brew packages)

## Privacy

Recents live only on your Mac, in Alfred’s Workflow Data for this workflow (bundle `com.robgill.sofascore`). They are not included in the `.alfredworkflow` export. Squad and league lists are temporary files in that workflow’s cache, and those are left out of the export too.

## Licence

MIT
