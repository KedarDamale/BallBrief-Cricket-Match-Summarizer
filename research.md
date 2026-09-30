Yes — for your project I would go **Playwright-only** and treat ESPNcricinfo as a website, not as an API.

That means:

```text
ESPN page
   ↓
Playwright/WebKit
   ├── __NEXT_DATA__
   ├── JSON/XHR/fetch responses
   ├── DOM as fallback
   └── SVG/canvas/image assets if present
             ↓
your normalized cricket schema
             ↓
NLU over commentary
```

That is also broadly the direction the maintained `python-espncricinfo` package has taken: it now uses Playwright/WebKit to load ESPNcricinfo pages and extract `__NEXT_DATA__` because of Akamai restrictions on older direct API access. :chatgpt-content-reference{index="0"}

The important caveat is **Hawk-Eye**: Playwright can capture Hawk-Eye-derived data **only if ESPN actually sends that data to the browser**. Hawk-Eye itself says its tracking feeds are provided to partners; I found no public raw tracking feed. :chatgpt-content-reference{index="1"}

---

# What I would extract

| Label | What you can collect | Confidence |
|---|---|---:|
| `match_discovery` | match IDs, series IDs, match cards | ✅ verified |
| `match_metadata` | status, date, format, title, scheduled overs | ✅ verified |
| `series` | ID, name, slug | ✅ verified |
| `venue` | ground ID, ground name, city/location | ✅ verified |
| `teams` | IDs, names, abbreviations, home team | ✅ verified |
| `toss` | winner + bat/bowl | ✅ verified |
| `result` | winner + result text/status | ✅ verified |
| `rosters` | squads / match players | ✅ verified |
| `innings` | runs, wickets, overs, target | ✅ verified |
| `batting_scorecard` | player, runs, balls, 4s, 6s, SR, dismissal | ✅ verified |
| `bowling_scorecard` | overs, maidens, runs, wickets, economy, wides, no-balls, dots | ✅ verified |
| `extras` | byes, leg-byes, wides, no-balls | ✅ verified |
| `fall_of_wickets` | wicket sequence | ✅ verified |
| `commentary` | ball-by-ball natural-language descriptions | ✅ available via page/network |
| `delivery_events` | runs/wicket/ball IDs/etc. when included with commentary payload | ✅ commonly present |
| `player_profile` | name, role, batting/bowling style, DOB, teams | ✅ page-accessible |
| `network_json` | every JSON response loaded by page | ✅ |
| `raw_next_data` | full ESPN Next.js state | ✅ |
| `wagon_wheel` | only if ESPN sends underlying data to browser | ⚠️ inspect dynamically |
| `pitch_map` | same | ⚠️ |
| `ball_speed` | if included in page/commentary/tracking payload | ⚠️ |
| `trajectory` | only if tracking payload is sent | ⚠️ |
| `release_point` | same | ⚠️ |
| `bounce_coordinates` | same | ⚠️ |
| `swing/seam` | only if ESPN actually receives/displays it | ⚠️ |
| raw Hawk-Eye `(x,y,z,t)` | no evidence of general public exposure | ❌ not guaranteed |

The verified match fields above come directly from current ESPNcricinfo `__NEXT_DATA__` parsing: teams, innings, batsmen, bowlers, FOW, extras, toss, result, venue, series and players are all present in current code. :chatgpt-content-reference{index="2"}

---

# 1. Base Playwright collector

This should be the foundation of everything.

```python
from __future__ import annotations

import asyncio
import json
from typing import Any

from playwright.async_api import (
    async_playwright,
    Browser,
    BrowserContext,
    Page,
    Response,
)


class ESPNBrowser:
    def __init__(self):
        self.browser: Browser | None = None
        self.context: BrowserContext | None = None
        self._pw = None

    async def __aenter__(self):
        self._pw = await async_playwright().start()

        # Current maintained ESPNcricinfo scraper uses WebKit.
        self.browser = await self._pw.webkit.launch(
            headless=True
        )

        self.context = await self.browser.new_context(
            user_agent=(
                "Mozilla/5.0 "
                "(Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/605.1.15 "
                "(KHTML, like Gecko) "
                "Version/16.0 Safari/605.1.15"
            )
        )

        return self

    async def __aexit__(self, exc_type, exc, tb):
        if self.context:
            await self.context.close()

        if self.browser:
            await self.browser.close()

        if self._pw:
            await self._pw.stop()

    async def new_page(self) -> Page:
        if not self.context:
            raise RuntimeError("Browser not initialized")

        return await self.context.new_page()
```

The current library specifically uses WebKit because its maintainers found headless WebKit was not blocked by the same Akamai behavior. :chatgpt-content-reference{index="3"}

---

# 2. Universal page capture

For **every ESPN page**, capture three things:

```text
HTML/DOM
__NEXT_DATA__
network JSON
```

```python
class PageCapture:
    def __init__(self):
        self.next_data: dict | None = None
        self.network_json: list[dict] = []
        self.html: str | None = None


async def capture_page(
    browser: ESPNBrowser,
    url: str,
    wait_ms: int = 5000,
) -> PageCapture:

    page = await browser.new_page()

    output = PageCapture()

    async def handle_response(response: Response):
        content_type = response.headers.get(
            "content-type",
            ""
        ).lower()

        if "json" not in content_type:
            return

        try:
            body = await response.json()
        except Exception:
            return

        output.network_json.append({
            "url": response.url,
            "status": response.status,
            "body": body,
        })

    page.on("response", handle_response)

    await page.goto(
        url,
        wait_until="domcontentloaded",
        timeout=60_000,
    )

    await page.wait_for_timeout(wait_ms)

    output.html = await page.content()

    next_script = page.locator(
        "script#__NEXT_DATA__"
    )

    if await next_script.count():
        raw = await next_script.text_content()

        if raw:
            output.next_data = json.loads(raw)

    await page.close()

    return output
```

Now you are no longer dependent on knowing ESPN's private APIs.

---

# 3. Match discovery

Verified page:

```text
https://www.espncricinfo.com/live-cricket-match-results
```

Date-specific:

```text
https://www.espncricinfo.com/live-cricket-match-results?date=2026-09-30
```

The current scraper reads match IDs from:

```python
props.appPageProps.data.data.content.matches
``` :chatgpt-content-reference{index="4"}


Code:

```python
async def get_match_discovery(
    browser: ESPNBrowser,
    date: str,
):
    url = (
        "https://www.espncricinfo.com/"
        f"live-cricket-match-results?date={date}"
    )

    capture = await capture_page(
        browser,
        url,
    )

    nd = capture.next_data

    if not nd:
        return []

    try:
        matches = (
            nd["props"]
              ["appPageProps"]
              ["data"]
              ["data"]
              ["content"]
              ["matches"]
        )
    except (KeyError, TypeError):
        return []

    output = []

    for m in matches:
        output.append({
            "label": "match_discovery",

            "match_id":
                m.get("objectId"),

            "series_id":
                (m.get("series") or {})
                .get("objectId"),

            "raw":
                m,
        })

    return output
```

---

# 4. Full scorecard page

Use:

```text
https://www.espncricinfo.com/series/x-{series_id}/x-{match_id}/full-scorecard
```

This exact structure is used by the current Playwright implementation. :chatgpt-content-reference{index="5"}

```python
def full_scorecard_url(
    series_id: int,
    match_id: int,
):
    return (
        "https://www.espncricinfo.com/"
        f"series/x-{series_id}/"
        f"x-{match_id}/"
        "full-scorecard"
    )
```

---

# 5. Extract ESPN's main data object

Current pages have two known shapes.

```python
def get_app_data(
    next_data: dict,
) -> dict:

    app_data = (
        next_data
        ["props"]
        ["appPageProps"]
        ["data"]
    )

    # current/live pages
    if (
        "match" in app_data
        and "content" in app_data
    ):
        return app_data

    # wrapped page form
    if "data" in app_data:
        return app_data["data"]

    raise KeyError(
        "Unknown ESPN __NEXT_DATA__ structure"
    )
```

This is exactly the distinction current ESPNcricinfo tooling handles. :chatgpt-content-reference{index="6"}

---

# 6. `match_metadata`

```python
def extract_match_metadata(data: dict):
    match = data.get("match", {})

    return {
        "label": "match_metadata",

        "match_id":
            match.get("objectId"),

        "title":
            match.get("title"),

        "status":
            match.get("status"),

        "status_text":
            match.get("statusText"),

        "format":
            match.get("format"),

        "international_class_id":
            match.get("internationalClassId"),

        "season":
            match.get("season"),

        "start_date":
            match.get("startDate"),

        "scheduled_overs":
            match.get("scheduledOvers"),

        "cancelled":
            match.get("isCancelled"),

        "floodlit":
            match.get("floodlit"),

        "raw":
            match,
    }
```

Those fields are all currently present in the match parser. :chatgpt-content-reference{index="7"}

---

# 7. `series`

```python
def extract_series(data: dict):
    series = (
        data
        .get("match", {})
        .get("series", {})
    )

    return {
        "label": "series",

        "series_id":
            series.get("objectId"),

        "name":
            series.get("name"),

        "slug":
            series.get("slug"),

        "raw":
            series,
    }
```

---

# 8. `venue`

```python
def extract_venue(data: dict):
    ground = (
        data
        .get("match", {})
        .get("ground", {})
    )

    town = ground.get("town") or {}

    return {
        "label": "venue",

        "ground_id":
            ground.get("objectId"),

        "name":
            ground.get("name"),

        "long_name":
            ground.get("longName"),

        "location":
            ground.get("location"),

        "town":
            town.get("name"),

        "raw":
            ground,
    }
```

Current parsing confirms ground ID, long name, location and town. :chatgpt-content-reference{index="8"}

---

# 9. `teams`

```python
def extract_teams(data: dict):
    teams = (
        data
        .get("match", {})
        .get("teams", [])
    )

    result = []

    for item in teams:
        team = item.get("team") or {}

        result.append({
            "label": "team",

            "team_id":
                team.get("objectId"),

            "internal_id":
                team.get("id"),

            "name":
                team.get("name"),

            "long_name":
                team.get("longName"),

            "abbreviation":
                team.get("abbreviation"),

            "is_home":
                item.get("isHome"),

            "raw":
                item,
        })

    return result
```

These exact team fields are currently normalized by the maintained scraper. :chatgpt-content-reference{index="9"}

---

# 10. `toss`

```python
def extract_toss(data: dict):
    match = data.get("match", {})

    choice = match.get(
        "tossWinnerChoice"
    )

    choice_name = {
        1: "bat",
        2: "bowl",
    }.get(choice)

    return {
        "label": "toss",

        "winner_internal_team_id":
            match.get(
                "tossWinnerTeamId"
            ),

        "choice_code":
            choice,

        "choice":
            choice_name,
    }
```

The current implementation maps `1 = bat`, `2 = bowl`. :chatgpt-content-reference{index="10"}

---

# 11. `result`

```python
def extract_result(data: dict):
    match = data.get("match", {})

    return {
        "label": "result",

        "winner_internal_team_id":
            match.get(
                "winnerTeamId"
            ),

        "status":
            match.get("status"),

        "status_text":
            match.get("statusText"),
    }
```

---

# 12. `rosters`

Path:

```text
content.matchPlayers.teamPlayers
```

verified in the current code. :chatgpt-content-reference{index="11"}

```python
def extract_rosters(data: dict):
    match_players = (
        data
        .get("content", {})
        .get("matchPlayers", {})
    )

    teams = match_players.get(
        "teamPlayers",
        []
    )

    result = []

    for team_entry in teams:
        team = team_entry.get("team") or {}

        result.append({
            "label": "roster",

            "team": {
                "id":
                    team.get("objectId"),

                "name":
                    team.get("name"),

                "long_name":
                    team.get("longName"),
            },

            "players":
                team_entry.get(
                    "players",
                    []
                ),

            "raw":
                team_entry,
        })

    return result
```

Keep raw player objects because ESPN can include additional metadata.

---

# 13. `innings`

Path:

```text
content.innings
```

Verified current fields include:

```text
team
runs
wickets
overs
event
inningNumber
inningBatsmen
inningBowlers
inningFallOfWickets
extras
byes
legbyes
wides
noballs
target
``` :chatgpt-content-reference{index="12"}


```python
def extract_innings(data: dict):
    innings = (
        data
        .get("content", {})
        .get("innings", [])
    )

    result = []

    for inn in innings:
        team = inn.get("team") or {}

        result.append({
            "label": "innings",

            "innings_number":
                inn.get("inningNumber"),

            "team_id":
                team.get("objectId"),

            "team":
                team.get("name"),

            "runs":
                inn.get("runs"),

            "wickets":
                inn.get("wickets"),

            "overs":
                inn.get("overs"),

            "target":
                inn.get("target"),

            "event":
                inn.get("event"),

            "raw":
                inn,
        })

    return result
```

---

# 14. `batting_scorecard`

```python
def extract_batting_scorecard(
    innings: dict,
):
    result = []

    for raw in innings.get(
        "inningBatsmen",
        []
    ):
        player = raw.get("player") or {}

        dismissal = (
            raw.get("dismissalText")
            or {}
        )

        result.append({
            "label":
                "batting_scorecard",

            "player_id":
                player.get("objectId"),

            "name":
                player.get("name"),

            "full_name":
                player.get("longName"),

            "runs":
                raw.get("runs"),

            "balls":
                raw.get("balls"),

            "minutes":
                raw.get("minutes"),

            "fours":
                raw.get("fours"),

            "sixes":
                raw.get("sixes"),

            "strike_rate":
                raw.get("strikerate"),

            "is_out":
                raw.get("isOut"),

            "batted_type":
                raw.get("battedType"),

            "dismissal":
                dismissal.get("long"),

            "raw":
                raw,
        })

    return result
```

Current implementation confirms those batting fields. :chatgpt-content-reference{index="13"}

---

# 15. `bowling_scorecard`

```python
def extract_bowling_scorecard(
    innings: dict,
):
    result = []

    for raw in innings.get(
        "inningBowlers",
        []
    ):
        player = raw.get("player") or {}

        result.append({
            "label":
                "bowling_scorecard",

            "player_id":
                player.get("objectId"),

            "name":
                player.get("name"),

            "full_name":
                player.get("longName"),

            "overs":
                raw.get("overs"),

            "maidens":
                raw.get("maidens"),

            "runs_conceded":
                raw.get("conceded"),

            "wickets":
                raw.get("wickets"),

            "economy":
                raw.get("economy"),

            "wides":
                raw.get("wides"),

            "no_balls":
                raw.get("noballs"),

            "dots":
                raw.get("dots"),

            "raw":
                raw,
        })

    return result
```

These fields are directly confirmed in current code. :chatgpt-content-reference{index="14"}

---

# 16. `extras`

```python
def extract_extras(innings: dict):
    return {
        "label": "extras",

        "total":
            innings.get("extras"),

        "byes":
            innings.get("byes"),

        "leg_byes":
            innings.get("legbyes"),

        "wides":
            innings.get("wides"),

        "no_balls":
            innings.get("noballs"),
    }
``` :chatgpt-content-reference{index="15"}


---

# 17. `fall_of_wickets`

```python
def extract_fall_of_wickets(
    innings: dict,
):
    return {
        "label": "fall_of_wickets",

        "wickets":
            innings.get(
                "inningFallOfWickets",
                [],
            ),
    }
```

Verified path. :chatgpt-content-reference{index="16"}

---

# 18. Ball-by-ball commentary

For this one I would **not even depend on the known comments URL**.

Open ESPN's normal commentary page:

```python
def commentary_page_url(
    series_id: int,
    match_id: int,
):
    return (
        "https://www.espncricinfo.com/"
        f"series/x-{series_id}/"
        f"x-{match_id}/"
        "ball-by-ball-commentary"
    )
```

Then capture every JSON response.

---

# 19. Automatically detect commentary payloads

Rather than relying on URL names:

```python
def walk_objects(obj):
    if isinstance(obj, dict):
        yield obj

        for value in obj.values():
            yield from walk_objects(value)

    elif isinstance(obj, list):
        for item in obj:
            yield from walk_objects(item)
```

Then detect objects that look like delivery commentary:

```python
def looks_like_delivery(
    obj: dict,
) -> bool:

    keys = set(obj.keys())

    strong_keys = {
        "overNumber",
        "ballNumber",
    }

    if not strong_keys.issubset(keys):
        return False

    supporting = {
        "title",
        "totalRuns",
        "batsmanRuns",
        "isWicket",
        "commentTextItems",
    }

    return bool(
        keys.intersection(supporting)
    )
```

Extractor:

```python
def extract_commentary_from_network(
    network_json: list[dict],
):
    deliveries = []

    seen = set()

    for response in network_json:
        body = response["body"]

        for obj in walk_objects(body):

            if not isinstance(obj, dict):
                continue

            if not looks_like_delivery(obj):
                continue

            key = (
                obj.get("inningNumber"),
                obj.get("overNumber"),
                obj.get("ballNumber"),
                obj.get("id"),
            )

            if key in seen:
                continue

            seen.add(key)

            deliveries.append({
                "label":
                    "ball_commentary",

                "innings":
                    obj.get(
                        "inningNumber"
                    ),

                "over":
                    obj.get(
                        "overNumber"
                    ),

                "ball":
                    obj.get(
                        "ballNumber"
                    ),

                "total_runs":
                    obj.get(
                        "totalRuns"
                    ),

                "batter_runs":
                    obj.get(
                        "batsmanRuns"
                    ),

                "is_four":
                    obj.get(
                        "isFour"
                    ),

                "is_six":
                    obj.get(
                        "isSix"
                    ),

                "is_wicket":
                    obj.get(
                        "isWicket"
                    ),

                "byes":
                    obj.get("byes"),

                "leg_byes":
                    obj.get(
                        "legbyes"
                    ),

                "wides":
                    obj.get(
                        "wides"
                    ),

                "no_balls":
                    obj.get(
                        "noballs"
                    ),

                "batter_id":
                    obj.get(
                        "batsmanPlayerId"
                    ),

                "bowler_id":
                    obj.get(
                        "bowlerPlayerId"
                    ),

                "title":
                    obj.get("title"),

                "dismissal":
                    obj.get(
                        "dismissalText"
                    ),

                "comment_pre":
                    obj.get(
                        "commentPreTextItems"
                    ),

                "comment":
                    obj.get(
                        "commentTextItems"
                    ),

                "comment_post":
                    obj.get(
                        "commentPostTextItems"
                    ),

                "videos":
                    obj.get(
                        "commentVideos"
                    ),

                "timestamp":
                    obj.get(
                        "timestamp"
                    ),

                "raw":
                    obj,
            })

    return deliveries
```

Those delivery-level field names have historically appeared in ESPNcricinfo commentary payloads, including innings, over, ball, runs, four/six/wicket flags, extras, batter/bowler IDs, dismissal text and commentary blocks. :chatgpt-content-reference{index="17"}

Most importantly, the code above only accepts them **if the browser actually sees them**.

---

# 20. Trigger lazy-loaded commentary

ESPN may not load the entire innings immediately.

So scroll:

```python
async def auto_scroll(
    page: Page,
    max_rounds: int = 100,
):
    previous_height = 0

    for _ in range(max_rounds):

        current_height = await page.evaluate(
            "document.body.scrollHeight"
        )

        if current_height == previous_height:
            break

        previous_height = current_height

        await page.evaluate(
            "window.scrollTo("
            "0, document.body.scrollHeight"
            ")"
        )

        await page.wait_for_timeout(
            1200
        )
```

---

# 21. Commentary crawler

```python
async def crawl_commentary(
    browser: ESPNBrowser,
    series_id: int,
    match_id: int,
):
    page = await browser.new_page()

    network: list[dict] = []

    async def on_response(response):
        ctype = response.headers.get(
            "content-type",
            ""
        ).lower()

        if "json" not in ctype:
            return

        try:
            body = await response.json()
        except Exception:
            return

        network.append({
            "url": response.url,
            "status": response.status,
            "body": body,
        })

    page.on(
        "response",
        on_response
    )

    await page.goto(
        commentary_page_url(
            series_id,
            match_id,
        ),
        wait_until="domcontentloaded",
        timeout=60_000,
    )

    await auto_scroll(page)

    await page.wait_for_timeout(
        3000
    )

    await page.close()

    return {
        "label":
            "commentary_capture",

        "deliveries":
            extract_commentary_from_network(
                network
            ),

        "raw_network":
            network,
    }
```

---

# 22. `player_profile`

You can also Playwright-load:

```text
https://www.espncricinfo.com/player/player-name-{player_id}
```

The older/current player structures contain things such as:

```text
name
first name
full name
DOB
age
playing role
batting style
bowling style
major teams
``` :chatgpt-content-reference{index="18"}


Generic approach:

```python
async def capture_player(
    browser: ESPNBrowser,
    player_id: int,
):
    url = (
        "https://www.espncricinfo.com/"
        f"player/player-name-{player_id}"
    )

    capture = await capture_page(
        browser,
        url,
    )

    return {
        "label": "player_profile",

        "player_id": player_id,

        "next_data":
            capture.next_data,

        "network_json":
            capture.network_json,
    }
```

I would again inspect and normalize the observed current JSON instead of assuming today's player-page nesting remains forever.

---

# 23. Generic network-data discovery

This part is extremely useful.

Print every JSON URL ESPN loads:

```python
def print_network_inventory(
    network_json: list[dict],
):
    for item in network_json:
        print(
            item["status"],
            item["url"],
        )
```

Now you'll discover future ESPN features without updating your crawler beforehand.

---

# 24. Recursively inspect every available key

```python
def collect_keys(
    obj,
    prefix="",
    output=None,
):
    if output is None:
        output = set()

    if isinstance(obj, dict):

        for key, value in obj.items():

            path = (
                f"{prefix}.{key}"
                if prefix
                else key
            )

            output.add(path)

            collect_keys(
                value,
                path,
                output,
            )

    elif isinstance(obj, list):

        for item in obj[:3]:
            collect_keys(
                item,
                prefix + "[]",
                output,
            )

    return output
```

Usage:

```python
keys = collect_keys(
    captured_json
)

for key in sorted(keys):
    print(key)
```

That tells you exactly what ESPN exposes today.

---

# Now Hawk-Eye

This needs a very strict distinction.

Hawk-Eye states that it generates ball/player tracking data and supplies data feeds to partners, including live, delayed, play-by-play and summary feeds. It also specifically describes cricket tracking systems capable of producing pitch maps and related visualizations. :chatgpt-content-reference{index="19"}

But:

> There is no evidence I found that ESPNcricinfo generally exposes the raw Hawk-Eye partner feed to anonymous browsers.

So we should **probe for it**, not assume it exists.

---

# 25. `tracking_candidate`

Search every browser JSON response for tracking-related fields.

```python
TRACKING_TERMS = {
    "hawkeye",
    "hawk_eye",
    "tracking",
    "trajectory",
    "balltracking",
    "ball_tracking",

    "pitchmap",
    "pitch_map",

    "wagonwheel",
    "wagon_wheel",

    "beehive",

    "releasepoint",
    "release_point",

    "bounce",
    "bouncepoint",
    "bounce_point",

    "impact",
    "impactpoint",

    "speed",
    "velocity",

    "swing",
    "seam",

    "coordinates",
    "coordinate",

    "x",
    "y",
    "z",
}


def find_tracking_candidates(
    obj,
    path="root",
):
    candidates = []

    if isinstance(obj, dict):

        lower_keys = {
            str(k).lower()
            for k in obj.keys()
        }

        matched = (
            lower_keys
            & TRACKING_TERMS
        )

        if matched:
            candidates.append({
                "label":
                    "tracking_candidate",

                "path":
                    path,

                "matched_keys":
                    sorted(matched),

                "payload":
                    obj,
            })

        for key, value in obj.items():

            candidates.extend(
                find_tracking_candidates(
                    value,
                    f"{path}.{key}",
                )
            )

    elif isinstance(obj, list):

        for i, value in enumerate(obj):

            candidates.extend(
                find_tracking_candidates(
                    value,
                    f"{path}[{i}]",
                )
            )

    return candidates
```

---

# 26. Probe the entire page for Hawk-Eye-like data

```python
def probe_tracking(
    network_json: list[dict],
):
    findings = []

    for response in network_json:

        found = find_tracking_candidates(
            response["body"]
        )

        for item in found:

            item["source_url"] = (
                response["url"]
            )

            findings.append(item)

    return findings
```

If ESPN is sending something like:

```json
{
  "pitchMap": {
    "x": 0.31,
    "y": 6.72
  }
}
```

or:

```json
{
  "trajectory": [
    {
      "x": 0.2,
      "y": 12.5,
      "z": 1.7
    }
  ]
}
```

you'll catch it automatically.

But **do not label it `hawkeye` just because it contains coordinates**.

Use:

```text
tracking_candidate
```

until you identify the provider.

---

# 27. Detect Hawk-Eye URLs themselves

```python
def find_tracking_urls(
    network_json: list[dict],
):
    keywords = [
        "hawk",
        "tracking",
        "trajectory",
        "wagon",
        "pitch",
        "beehive",
    ]

    results = []

    for item in network_json:

        url = item["url"].lower()

        if any(
            k in url
            for k in keywords
        ):
            results.append({
                "label":
                    "tracking_network_request",

                "url":
                    item["url"],

                "status":
                    item["status"],

                "body":
                    item["body"],
            })

    return results
```

---

# 28. What if ESPN renders a pitch map as SVG?

Playwright can inspect it.

```python
async def collect_svg(
    page: Page,
):
    svgs = page.locator("svg")

    count = await svgs.count()

    result = []

    for i in range(count):

        svg = svgs.nth(i)

        html = await svg.evaluate(
            "(el) => el.outerHTML"
        )

        result.append({
            "label":
                "svg_graphic",

            "index":
                i,

            "svg":
                html,
        })

    return result
```

If the wagon wheel/pitch map is SVG, the coordinates might literally be in:

```text
<line x1="" y1="" x2="" y2="">
<circle cx="" cy="">
<path d="">
```

Those can potentially be normalized.

---

# 29. Canvas-based visualization

Canvas is harder.

You can detect it:

```python
async def detect_canvas(
    page: Page,
):
    count = await page.locator(
        "canvas"
    ).count()

    return {
        "label": "canvas_count",
        "count": count,
    }
```

And export a visual snapshot:

```python
async def capture_canvases(
    page: Page,
):
    canvases = page.locator(
        "canvas"
    )

    result = []

    for i in range(
        await canvases.count()
    ):

        canvas = canvases.nth(i)

        data_url = await canvas.evaluate(
            """
            canvas =>
                canvas.toDataURL(
                    "image/png"
                )
            """
        )

        result.append({
            "label":
                "canvas_graphic",

            "index":
                i,

            "image_data_url":
                data_url,
        })

    return result
```

But that gives you pixels, **not necessarily Hawk-Eye coordinates**.

---

# 30. Final complete scraper

```python
async def scrape_match_everything(
    series_id: int,
    match_id: int,
):

    async with ESPNBrowser() as browser:

        scorecard_url = (
            "https://www.espncricinfo.com/"
            f"series/x-{series_id}/"
            f"x-{match_id}/"
            "full-scorecard"
        )

        score_capture = await capture_page(
            browser,
            scorecard_url,
        )

        if not score_capture.next_data:
            raise RuntimeError(
                "No __NEXT_DATA__ found"
            )

        data = get_app_data(
            score_capture.next_data
        )

        innings_raw = (
            data
            .get("content", {})
            .get("innings", [])
        )

        commentary = await crawl_commentary(
            browser,
            series_id,
            match_id,
        )

        batting = []
        bowling = []
        extras = []
        fow = []

        for inn in innings_raw:

            batting.append(
                extract_batting_scorecard(
                    inn
                )
            )

            bowling.append(
                extract_bowling_scorecard(
                    inn
                )
            )

            extras.append(
                extract_extras(
                    inn
                )
            )

            fow.append(
                extract_fall_of_wickets(
                    inn
                )
            )

        all_network = (
            score_capture.network_json
            +
            commentary["raw_network"]
        )

        tracking_candidates = (
            probe_tracking(
                all_network
            )
        )

        tracking_urls = (
            find_tracking_urls(
                all_network
            )
        )

        return {

            # ---------------------
            # MATCH
            # ---------------------

            "match_metadata":
                extract_match_metadata(
                    data
                ),

            "series":
                extract_series(
                    data
                ),

            "venue":
                extract_venue(
                    data
                ),

            "teams":
                extract_teams(
                    data
                ),

            "toss":
                extract_toss(
                    data
                ),

            "result":
                extract_result(
                    data
                ),

            # ---------------------
            # PLAYERS
            # ---------------------

            "rosters":
                extract_rosters(
                    data
                ),

            # ---------------------
            # INNINGS
            # ---------------------

            "innings":
                extract_innings(
                    data
                ),

            "batting_scorecards":
                batting,

            "bowling_scorecards":
                bowling,

            "extras":
                extras,

            "fall_of_wickets":
                fow,

            # ---------------------
            # COMMENTARY
            # ---------------------

            "ball_by_ball":
                commentary[
                    "deliveries"
                ],

            # ---------------------
            # TRACKING / HAWKEYE
            # ---------------------

            "tracking_candidates":
                tracking_candidates,

            "tracking_network_requests":
                tracking_urls,

            # ---------------------
            # RAW
            # ---------------------

            "raw_next_data":
                score_capture.next_data,

            "raw_page_data":
                data,

            "raw_network_json":
                all_network,
        }
```

Run:

```python
async def main():

    dataset = await scrape_match_everything(
        series_id=1478874,
        match_id=1478914,
    )

    with open(
        "espn_match_full.json",
        "w",
        encoding="utf-8",
    ) as f:

        json.dump(
            dataset,
            f,
            indent=2,
            ensure_ascii=False,
        )


asyncio.run(main())
```

---

# What should feed your NLU?

Only the commentary-specific part:

```json
{
  "innings": 1,
  "over": 14,
  "ball": 3,

  "batter_id": 123,
  "bowler_id": 456,

  "total_runs": 4,
  "is_wicket": false,

  "commentary": "Short and wide outside off, cut hard through backward point."
}
```

Then your NLU adds:

```json
{
  "delivery": {
    "length": "short",
    "line": "wide_outside_off"
  },

  "shot": {
    "type": "cut",
    "region": "backward_point"
  }
}
```

So don't use NLU to infer:

```text
runs
wicket
batter
bowler
extras
```

when ESPN already gives them structurally.

Use NLU for:

```text
line
length
shot
shot direction
field region
movement
bowling variation
attacking/defensive intent
misc tactical description
```

---

## Hawk-Eye conclusion

For the scraper architecture, absolutely include:

```python
tracking_candidates
tracking_network_requests
svg_graphics
canvas_graphics
```

from day one.

But your schema should be:

```json
{
  "tracking": {
    "available": false,
    "provider": null,
    "raw": null
  }
}
```

until a particular match actually exposes tracking data.

If ESPN sends genuine Hawk-Eye-derived coordinates to the browser, Playwright can capture them because the browser must receive them to render the visualization. If ESPN only sends a prerendered image/video, you **cannot claim exact Hawk-Eye coordinates** from it. Hawk-Eye's public material confirms tracking and partner data feeds exist, but not a generally public raw cricket feed. :chatgpt-content-reference{index="20"}

So the architecture I'd settle on is:

```text
                 ESPNCRICINFO
                      │
                Playwright/WebKit
                      │
      ┌───────────────┼────────────────┐
      │               │                │
 __NEXT_DATA__     Network JSON       DOM
      │               │                │
 scorecards       commentary       SVG/canvas
 metadata         tracking?        fallback
 players               │
 innings               │
      └───────────────┬┘
                      │
              NORMALIZED MATCH
                      │
        ┌─────────────┴─────────────┐
        │                           │
   structural data            commentary
                                    │
                                   NLU
                                    │
                   line / length / shot /
                   region / movement
                                    │
                              ANALYTICS
                                    │
                         STRATEGY ENGINE
```

That gives you the most future-resistant version of this project without depending directly on ESPN's internal endpoint names.
