### ESPNcricinfo data

ESPNcricinfo does **not appear to offer a supported public cricket developer API**. However, its website uses internal JSON endpoints, and several open-source packages wrap those endpoints or scrape the site. These are unofficial and can change. :chatgpt-content-reference{index="0"}

A particularly interesting current Python option is **`pycricinfo`**. It was updated in 2026, uses ESPNcricinfo's undocumented APIs/scraping, represents responses with Pydantic models, and can optionally expose them through a FastAPI wrapper. It's still marked pre-release, though. :chatgpt-content-reference{index="1"}

```bash
pip install pycricinfo
```

There is also the older:

```bash
pip install python-espncricinfo
```

but the PyPI release itself is quite old. The actively modified GitHub code is more interesting because it now works around ESPN's newer architecture. :chatgpt-content-reference{index="2"}

What's especially relevant to you is that the current code references ESPN's commentary endpoint in roughly this form:

```text
https://hsapi.espncricinfo.com/v1/pages/match/comments
```

with parameters such as:

```text
leagueId
eventId
period
page
filter=full
```

The library's current implementation explicitly constructs that endpoint for retrieving match commentary. :chatgpt-content-reference{index="3"}

So you can potentially get something like:

```json
{
  "over": 17,
  "ball": 3,
  "batter": "Virat Kohli",
  "bowler": "Mitchell Starc",
  "runs": 4,
  "commentary": "Full outside off, Kohli drives beautifully through cover..."
}
```

and then feed `commentary` into your NLU system.

The important caveat is that these are **internal/undocumented interfaces**, not an API contract you should assume will remain stable.

---

## An even better data source for your research project: Cricsheet

For the structured side of your project, I would actually use **Cricsheet alongside ESPN**, rather than relying entirely on ESPN.

Cricsheet currently provides ball-by-ball data for nearly **23,000 matches**, including Tests, ODIs, T20Is, IPL, BBL, PSL, The Hundred, SA20 and many other competitions. Data is directly downloadable as JSON, YAML, CSV and XML. :chatgpt-content-reference{index="4"}

JSON is their main and most complete format. :chatgpt-content-reference{index="5"}

For example:

```json
{
  "overs": [
    {
      "over": 14,
      "deliveries": [
        {
          "batter": "V Kohli",
          "bowler": "MA Starc",
          "non_striker": "RG Sharma",
          "runs": {
            "batter": 4,
            "extras": 0,
            "total": 4
          }
        }
      ]
    }
  ]
}
```

For your system I'd combine:

```text
Cricsheet
   ↓
Reliable structured ball data

ESPN commentary
   ↓
Rich natural-language description

         ↓ JOIN ON MATCH + INNINGS + BALL

Complete delivery record
```

That is much stronger than trying to derive everything from commentary.

---

# Now the bad news: Hawk-Eye

There is **no normal free/public Hawk-Eye cricket API** comparable to something like an OpenWeather API.

Hawk-Eye itself says it produces ball/player tracking data and provides multiple types of **data feeds to partners**, including live, delayed, play-by-play and summary feeds. :chatgpt-content-reference{index="6"}

For cricket specifically, Hawk-Eye describes its technology as providing precise ball tracking and UltraEdge and says it covers more than 1,000 cricket match days per year across 15 countries. :chatgpt-content-reference{index="7"}

But access is primarily through contractual relationships with:

```text
sports federations
leagues
teams
broadcasters
commercial analytics companies
```

rather than a public:

```text
GET /hawkeye/cricket/match/12345
```

API.

Hawk-Eye's own privacy/data documentation confirms that it shares tracking data and products with sporting customers such as federations, leagues, teams and broadcasters. :chatgpt-content-reference{index="8"}

---

# What Hawk-Eye data would contain

If you actually had the full ball-tracking feed, it could contain dramatically richer information than commentary.

Conceptually:

```json
{
  "delivery_id": "17.3",

  "release": {
    "x": 0.17,
    "y": 1.94,
    "z": 18.7
  },

  "speed": {
    "release_kph": 143.2
  },

  "pitch": {
    "x": -0.31,
    "y": 5.82
  },

  "bounce_height": 0.48,

  "trajectory": [
    {"t": 0.00, "x": 0.17, "y": 18.7, "z": 1.94},
    {"t": 0.02, "x": 0.16, "y": 18.0, "z": 1.90},
    {"t": 0.04, "x": 0.15, "y": 17.2, "z": 1.85}
  ],

  "movement": {
    "swing_deg": 1.7,
    "seam_deg": 0.8
  },

  "impact": {
    "x": -0.12,
    "height": 0.72
  }
}
```

With data like that you can create real:

```text
pitch maps
release maps
line maps
length maps
bounce maps
swing charts
seam movement
pace distributions
trajectory visualisations
bowling heatmaps
```

That's very different from estimating these things from text.

---

# There are commercial routes to Hawk-Eye data

There are cricket analytics platforms that explicitly integrate Hawk-Eye.

For example, **CricViz Centurion** says it uses official third-party ball-tracking sources including Hawk-Eye and Virtual Eye to analyze speed, line and length. :chatgpt-content-reference{index="9"}

**NV Play** also explicitly lists Hawk-Eye ball-tracking integration among its supported data integrations. :chatgpt-content-reference{index="10"}

So the commercial chain is more like:

```text
Hawk-Eye cameras
       ↓
Hawk-Eye tracking system
       ↓
Official data feed
       ↓
League / broadcaster / team
       ↓
CricViz / NV Play / analytics systems
```

rather than:

```text
developer → free Hawk-Eye API
```

---

# Can you scrape Hawk-Eye data from ESPN?

Usually **not the actual underlying tracking dataset**.

You may sometimes see graphics on broadcasts/websites showing:

```text
pitch position
wagon wheel
ball trajectory
speed
projected path
```

but seeing the visualization does not mean the complete `(x,y,z,t)` tracking feed is exposed through ESPN's commentary API.

That's an important distinction:

```text
ESPN commentary

"short of a length outside off"
```

versus:

```text
Hawk-Eye

pitch_x = 0.42
pitch_y = 7.21
release_speed = 143.7
bounce_height = 0.81
trajectory = [...]
```

The second is actual sensor/computer-vision-derived tracking.

---

# For your project, this is what I would build

You can still make a **very impressive cricket analytics project without Hawk-Eye**.

Use:

```text
                    ┌────────────────┐
                    │   Cricsheet    │
                    │                │
                    │ score          │
                    │ runs           │
                    │ wickets        │
                    │ batter         │
                    │ bowler         │
                    └───────┬────────┘
                            │
                            │ join
                            │
┌────────────────┐          ▼
│ ESPN Cricinfo  │    ┌──────────────┐
│                │───▶│ Delivery DB  │
│ commentary     │    └───────┬──────┘
└────────────────┘            │
                              ▼
                     ┌─────────────────┐
                     │ NLU Extractor   │
                     │                 │
                     │ line            │
                     │ length          │
                     │ shot            │
                     │ field position  │
                     │ bowling type    │
                     │ movement words  │
                     └────────┬────────┘
                              │
                              ▼
                       Structured JSON
                              │
             ┌────────────────┼────────────────┐
             ▼                ▼                ▼
        Pitch maps       Wagon wheels     Strategy
        heat maps        shot maps        analysis
```

Your extracted delivery might become:

```json
{
  "match_id": 12345,
  "innings": 1,
  "over": 17,
  "ball": 3,

  "bowler": "Mitchell Starc",
  "batter": "Virat Kohli",

  "delivery": {
    "line": "outside_off",
    "length": "full",
    "type": null,
    "speed_kph": 143.8
  },

  "shot": {
    "type": "cover_drive",
    "region": "cover",
    "aerial": false
  },

  "result": {
    "runs": 4,
    "wicket": false
  },

  "source": {
    "structured": "cricsheet",
    "commentary": "espncricinfo",
    "tracking": null
  }
}
```

Then distinguish carefully between **observed structured facts** and **NLU-estimated facts**:

```json
{
  "line": {
    "value": "outside_off",
    "source": "commentary_nlu",
    "confidence": 0.96
  },

  "length": {
    "value": "full",
    "source": "commentary_nlu",
    "confidence": 0.91
  }
}
```

That way you're not pretending an estimated pitch position is Hawk-Eye precision.

### Best stack for your project

| Need | Source I'd use |
|---|---|
| Match list/results | ESPN / Cricsheet |
| Scorecard | ESPN |
| Batter/bowler | Cricsheet + ESPN |
| Runs/wickets/extras | **Cricsheet** |
| Full commentary | **ESPNcricinfo** |
| Line | Commentary NLU |
| Length | Commentary NLU |
| Shot type | Commentary NLU |
| Fielding region | Commentary NLU |
| Exact pitch coordinates | **Hawk-Eye required** |
| Exact ball trajectory | **Hawk-Eye required** |
| Swing/seam measurement | **Hawk-Eye/tracking provider** |
| Exact wagon-wheel coordinates | Tracking/scoring provider |
| Strategy insights | **Your analytics model** |

So for a portfolio/research version, **Cricsheet + ESPN commentary + your own NLU is probably the sweet spot**. You can build almost everything you described—bowler targeting patterns, approximate pitch maps, batter scoring zones, shot selection, matchup analysis, phases, and inferred strategy—while making it clear which metrics are inferred rather than true Hawk-Eye tracking. :chatgpt-content-reference{index="11"}


If you mean the current **`python-espncricinfo`** package, then **no, not every endpoint I listed is exposed cleanly as a first-class wrapper method**.

The package mainly focuses on **matches, summaries, series, and players**. Its current match implementation actually fetches ESPNcricinfo pages with Playwright and extracts embedded `__NEXT_DATA__`, partly because some older direct ESPN endpoints are blocked by Akamai. :chatgpt-content-reference{index="0"}

Roughly:

| Data / endpoint family | Covered by `python-espncricinfo`? |
|---|---:|
| Recent/current matches | Yes |
| Match metadata | Yes |
| Full scorecard / innings | Yes |
| Batting scorecard | Yes |
| Bowling scorecard | Yes |
| Team/player lists for match | Yes |
| Toss/result/venue/officials | Yes |
| Series information | Yes |
| Player profile | Yes |
| Player stats | Yes, partly via ESPN stats pages |
| Ball-by-ball commentary | **Partially / internally referenced** |
| `/match/comments` URL generation | Yes |
| All commentary pages automatically downloaded | Not as cleanly as you'd expect |
| `/site/v2/.../summary` | Internally referenced |
| `/site/v2/.../scoreboard` | Not really a dedicated public wrapper API |
| `/site/v2/.../news` | No obvious high-level wrapper |
| Team `/pages/team/home` | Not a major first-class interface |
| Scheduled/results-by-date endpoints | Some equivalent functionality, not necessarily direct wrapper for every route |
| Hawk-Eye data | **No** |
| Exact pitch coordinates | **No** |
| Ball trajectory | **No** |

The interesting bit is in `Match`.

The package currently contains this method:

```python
def innings_comms_url(self, innings=1, page=1):
    return (
        f"https://hsapi.espncricinfo.com/v1/pages/match/comments"
        f"?lang=en&leagueId={self.series_id}&eventId={self.match_id}"
        f"&period={innings}&page={page}&filter=full&liveTest=false"
    )
```

So the author knows about and exposes the commentary endpoint URL internally. :chatgpt-content-reference{index="1"}

It also contains:

```python
def _espn_api_url(self):
    return (
        f"https://site.api.espn.com/apis/site/v2/sports/cricket/"
        f"{self.series_id}/summary?event={self.match_id}"
    )
```

and the older core endpoint:

```python
self.event_url = (
    "http://core.espnuk.org/v2/sports/cricket/leagues/"
    f"{self.series_id}/events/{match_id}"
)
```

So the package uses multiple ESPN data sources underneath. :chatgpt-content-reference{index="2"}

For players it directly references both:

```text
core.espnuk.org/v2/sports/cricket/athletes/{playerId}
```

and:

```text
hs-consumer-api.espncricinfo.com/v1/pages/player/home?playerId={playerId}
``` :chatgpt-content-reference{index="3"}


The bigger limitation for **your project** is commentary. The modern package's `get_comms_json()` currently says commentary is available in its fetched page content and returns `None`, rather than providing a polished method like:

```python
match.get_all_deliveries()
```

that automatically paginates every innings' `/comments` endpoint. :chatgpt-content-reference{index="4"}

So I would actually use the package for discovery/metadata:

```python
from espncricinfo.match import Match

matches = Match.get_recent_matches(date="2026-09-29")

for ref in matches:
    print(ref.series_id, ref.match_id)
```

then instantiate:

```python
match = Match(
    match_id=1478914,
    series_id=1478874
)
```

and use fields like:

```python
match.description
match.result
match.all_innings
match.team_1_players
match.team_2_players
```

But for the thing you care about most—

```text
EVERY BALL
+
FULL COMMENTARY
```

—I would probably call the commentary endpoint yourself:

```python
import requests

BASE = "https://hsapi.espncricinfo.com/v1/pages/match/comments"


def get_commentary(series_id, match_id, innings, page=1):
    params = {
        "lang": "en",
        "leagueId": series_id,
        "eventId": match_id,
        "period": innings,
        "page": page,
        "filter": "full",
        "liveTest": "false",
    }

    r = requests.get(
        BASE,
        params=params,
        headers={
            "User-Agent": "Mozilla/5.0"
        },
        timeout=20,
    )

    r.raise_for_status()

    return r.json()
```

Then paginate:

```python
all_comments = []

page = 1

while True:
    data = get_commentary(
        series_id=1478874,
        match_id=1478914,
        innings=1,
        page=page,
    )

    comments = data.get("comments", [])

    if not comments:
        break

    all_comments.extend(comments)

    page += 1
```

Though the exact location of `comments` in the returned JSON may vary, so inspect one real response first.

For your architecture, I'd therefore do:

```text
python-espncricinfo
        ↓
match discovery
series ID
match ID
scorecard
players
innings
metadata

        +

direct ESPN commentary endpoint
        ↓
full ball-by-ball commentary

        ↓

your parser / NLU
        ↓
rich delivery JSON
```

That is better than relying completely on the package.

And to be clear: **nothing in `python-espncricinfo` gives you actual Hawk-Eye tracking data.** It does not solve exact pitch location, trajectory, bounce coordinates, seam movement, etc.

If you want, I can next give you a **single Python client class that wraps all the ESPN endpoints we found directly**, including match discovery, scorecard, summary, player data, and automatic pagination of every commentary ball, so you don't need `python-espncricinfo` at all.
