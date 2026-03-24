import logging
import os
import sys
import uuid
from datetime import datetime, timezone

import requests
from firebase_admin import initialize_app, firestore
from firebase_functions import https_fn, options

from urllib.parse import urlparse, parse_qs, unquote

from scraper import get_all_team_urls, get_match_urls_for_team, parse_match_detail, parse_team_schedule, parse_club_address
from power_rating import build_player_records, compute_power_rating
from matcher import match_player_to_uid
from writer import write_league_stats, write_unmatched, write_run_log, write_league_teams, write_league_matches, write_league_schedule

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=getattr(logging, os.environ.get("LOG_LEVEL", "INFO").upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("scraper.main")

# ---------------------------------------------------------------------------
# Firebase Initialization
# ---------------------------------------------------------------------------

import google.auth.exceptions
try:
    initialize_app()
except ValueError:
    pass
except google.auth.exceptions.DefaultCredentialsError:
    log.warning("Skipping ADC init during module load.")

db = None
def get_db():
    global db
    if db is None:
        try:
            db = firestore.client()
        except:
            pass
    return db

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

MATCH_THRESHOLD = int(os.environ.get("MATCH_THRESHOLD", "75"))

# ---------------------------------------------------------------------------
# League site definitions
# Each entry: league_name shown in the app, base_url for that league's site.
# The standings switcher on each site gives the division list.
# ---------------------------------------------------------------------------

LEAGUE_SITES = [
    {
        "league_name": "Saturday Women's League",
        "base_url": "https://northshoreww.tenniscores.com",
    },
    {
        "league_name": "Weekday Women's League",
        "base_url": "https://northshore.tenniscores.com",
    },
]

# mod= parameter that triggers the standings/division-browser view on all sites
STANDINGS_MOD = "nndz-TjJiOWtOR3QzTU4yakRrY1NjN1FMcGpx"

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def get_all_users() -> list:
    """Load all user documents from Firestore. Returns list of {uid, displayName}."""
    users = []
    _db = get_db()
    for doc in _db.collection("users").stream():
        data = doc.to_dict() or {}
        display = (
            data.get("displayName")
            or data.get("display_name")
            or ""
        ).strip()
        if display:
            users.append({"uid": doc.id, "displayName": display})
    log.info(f"Loaded {len(users)} users from Firestore")
    return users


def derive_team_rankings(all_matches: list) -> tuple:
    """
    Build a proxy team ranking from aggregate win counts across all scraped matches.
    Returns ({ team_name_lower: rank_int }, total_teams).
    """
    win_counts: dict = {}

    for match in all_matches:
        home_line_wins = sum(
            1 for line in match.get("lines", [])
            if line.get("home_games_won", 0) > line.get("home_games_lost", 0)
        )
        away_line_wins = len(match.get("lines", [])) - home_line_wins

        home_key = match.get("home_team", "").lower()
        away_key = match.get("away_team", "").lower()

        win_counts[home_key] = win_counts.get(home_key, 0) + home_line_wins
        win_counts[away_key] = win_counts.get(away_key, 0) + away_line_wins

    sorted_teams = sorted(win_counts.items(), key=lambda x: x[1], reverse=True)
    rankings = {team: rank + 1 for rank, (team, _) in enumerate(sorted_teams)}

    log.info(f"Derived rankings for {len(rankings)} teams")
    return rankings, len(rankings)


# ---------------------------------------------------------------------------
# Cloud Functions
# ---------------------------------------------------------------------------

def _scrape_all_league_teams(session: requests.Session) -> list:
    """
    Scrape all league sites to build a hierarchical league → division → team list.

    For each site:
      1. Fetch the main page to get the standings_switcher (division list).
      2. For each division, fetch the standings page and extract team links
         from the `table.division_standings` element only (not the sidebar).
      3. Build a doc dict with league_name, division_name, team_name, team_url.

    Returns list of team dicts ready for write_league_teams().
    """
    from bs4 import BeautifulSoup

    teams = []

    for site in LEAGUE_SITES:
        league_name = site["league_name"]
        base_url = site["base_url"]
        log.info(f"Scraping league: {league_name} ({base_url})")

        try:
            resp = session.get(base_url, headers=HEADERS, timeout=20)
            resp.raise_for_status()
        except Exception as e:
            log.warning(f"  Failed to fetch main page: {e}")
            continue

        soup = BeautifulSoup(resp.text, "lxml")
        switcher = soup.find("select", id="standings_switcher")
        if not switcher:
            log.warning(f"  No standings_switcher found on {base_url}")
            continue

        options = switcher.find_all("option")
        log.info(f"  Found {len(options)} divisions")

        for opt in options:
            division_name = opt.get_text(" ", strip=True)
            div_id = opt.get("value", "").strip()
            if not div_id or not division_name:
                continue

            div_url = f"{base_url}/?mod={STANDINGS_MOD}&did={div_id}"
            try:
                dr = session.get(div_url, headers=HEADERS, timeout=20)
                dr.raise_for_status()
            except Exception as e:
                log.warning(f"    Failed to fetch division page {div_url}: {e}")
                continue

            div_soup = BeautifulSoup(dr.text, "lxml")

            # Only read team links from the division_standings table,
            # not from the sidebar or other navigation links.
            table = div_soup.find("table", class_="division_standings")
            if not table:
                log.warning(f"    No division_standings table for {division_name}")
                continue

            count_before = len(teams)
            seen_in_div: set = set()
            for a in table.find_all("a", href=True):
                href = a["href"]
                if "team=" not in href:
                    continue
                team_name = a.get_text(strip=True)
                if not team_name:
                    continue

                # Build absolute team URL
                if href.startswith("http"):
                    team_url = href
                elif href.startswith("?"):
                    team_url = f"{base_url}/{href}"
                else:
                    team_url = f"{base_url}/{href.lstrip('/')}"

                # Deduplicate within this division (same link may repeat)
                if team_url in seen_in_div:
                    continue
                seen_in_div.add(team_url)

                teams.append({
                    "league_name": league_name,
                    "division_name": division_name,
                    "team_name": team_name,
                    "team_url": team_url,
                })

            added = len(teams) - count_before
            log.info(f"    {division_name}: {added} teams")

    log.info(f"Total teams scraped across all leagues: {len(teams)}")
    return teams


@https_fn.on_call(timeout_sec=540, memory=options.MemoryOption.GB_1)
def refresh_team_names(req: https_fn.CallableRequest) -> any:
    """
    Scrapes all configured league sites using a hierarchical approach:
    League site → standings_switcher (divisions) → division_standings table (teams).

    Writes to `league_teams` with league_name, division_name, team_name, team_url.
    Doc ID = team= URL param (unique per team per division), so the same club
    name in two divisions gets two separate documents.
    """
    log.info("Starting refresh_team_names (hierarchical)...")
    session = requests.Session()
    teams = _scrape_all_league_teams(session)
    if not teams:
        return {"status": "error", "message": "No teams discovered from any league site"}
    write_league_teams(get_db(), teams)
    log.info(f"refresh_team_names complete. Wrote {len(teams)} team docs.")
    return {"status": "success", "teamsScraped": len(teams)}


@https_fn.on_call(timeout_sec=540, memory=options.MemoryOption.GB_1)
def refresh_team_schedules(req: https_fn.CallableRequest) -> any:
    """
    Reads the team schedule table (all matches: played + upcoming) and writes
    date/opponent/time entries to league_matches. Score and player-line data
    are NOT collected here — see refresh_player_ratings for that.

    If teamName is provided, scrapes only that team. Otherwise scrapes all.
    Accepts optional seasonYear (int) to anchor the year for date inference;
    defaults to a heuristic based on the current month.
    """
    log.info("Starting refresh_team_schedules...")
    session = requests.Session()

    data = req.data if hasattr(req, "data") and req.data else {}
    target_team_url = data.get("teamUrl")    # preferred: exact URL
    target_team_name = data.get("teamName")  # fallback: name-based lookup
    season_start_year = data.get("seasonYear")  # optional int

    _db = get_db()

    if target_team_url:
        # Precise: look up by the stored team_url field (supports new schema).
        # Also fall back to the legacy URL field name.
        log.info(f"Targeting team by URL: {target_team_url}")
        teams_ref = list(_db.collection("league_teams")
                         .where("team_url", "==", target_team_url).stream())
        if not teams_ref:
            # Legacy docs store URL in capital field
            teams_ref = list(_db.collection("league_teams")
                             .where("URL", "==", target_team_url).stream())
        team_urls = [(target_team_url, t.to_dict().get("team_name") or t.to_dict().get("Name", ""))
                     for t in teams_ref] or [(target_team_url, "")]
    elif target_team_name:
        log.info(f"Targeting team by name: {target_team_name}")
        teams_ref = list(_db.collection("league_teams")
                         .where("team_name", "==", target_team_name).stream())
        if not teams_ref:
            teams_ref = list(_db.collection("league_teams")
                             .where("Name", "==", target_team_name).stream())
        team_urls = [(t.to_dict().get("team_url") or t.to_dict().get("URL", ""),
                      t.to_dict().get("team_name") or t.to_dict().get("Name", ""))
                     for t in teams_ref if t.to_dict().get("team_url") or t.to_dict().get("URL")]
    else:
        # No filter: scrape all teams
        all_docs = list(_db.collection("league_teams").stream())
        team_urls = [(t.to_dict().get("team_url") or t.to_dict().get("URL", ""),
                      t.to_dict().get("team_name") or t.to_dict().get("Name", ""))
                     for t in all_docs if t.to_dict().get("team_url") or t.to_dict().get("URL")]

    if not team_urls:
        return {"status": "error", "message": "No league teams found. Run refresh_team_names first."}

    # Build a name→URL lookup from league_teams so we can resolve opponent addresses
    # without HTML link extraction (the schedule table has no links to opponent pages).
    # Supports both old schema (Name/URL) and new schema (team_name/team_url).
    all_team_docs = list(_db.collection("league_teams").stream())
    name_to_url: dict = {}
    for doc in all_team_docs:
        d = doc.to_dict()
        n = (d.get("team_name") or d.get("Name", "")).strip().lower()
        u = (d.get("team_url") or d.get("URL", "")).strip()
        if n and u:
            name_to_url[n] = u
    log.info(f"Loaded {len(name_to_url)} team name→URL entries for address lookup")

    total_matches = 0
    # Cache club addresses keyed by team URL to avoid duplicate fetches.
    address_cache: dict = {}

    for i, (team_url, team_name) in enumerate(team_urls):
        if not team_url:
            continue
        log.info(f"Scraping schedule for team {i+1}/{len(team_urls)}: {team_url}")
        scraped_name, schedule = parse_team_schedule(team_url, session, season_start_year)
        name = scraped_name or team_name
        if schedule:
            # Enrich away matches with the opponent venue address.
            # Resolve opponent URL via name_to_url, then fetch address once per URL.
            for m in schedule:
                if m["is_home"]:
                    continue
                opp_name = m["opponent"].strip().lower()
                opp_url = name_to_url.get(opp_name, "")
                if not opp_url:
                    log.debug(f"  No URL found for opponent {m['opponent']!r}")
                    continue
                if opp_url not in address_cache:
                    log.info(f"  Fetching venue address for {m['opponent']!r} from {opp_url}")
                    address_cache[opp_url] = parse_club_address(opp_url, session)
                addr = address_cache[opp_url]
                if addr:
                    m["location"] = addr

            write_league_schedule(_db, name, schedule, team_url=team_url)
            total_matches += len(schedule)

    log.info(f"refresh_team_schedules complete. Wrote {total_matches} schedule entries.")
    return {"status": "success", "matchesScraped": total_matches}


@https_fn.on_call(timeout_sec=540, memory=options.MemoryOption.GB_1)
def refresh_player_ratings(req: https_fn.CallableRequest) -> any:
    """
    Scrapes played match detail pages (print_match.php) for scores and player-line
    data, then computes power ratings for all matched players.

    This is separate from refresh_team_schedules, which reads the schedule table
    for dates/opponents but has no score data.
    """
    log.info("Starting refresh_player_ratings...")

    # 0. Scrape match detail pages (played matches only — these have scores).
    log.info("Step 0: Scraping played match detail pages from the league site...")
    data_in = req.data if hasattr(req, "data") and req.data else {}
    target_team = data_in.get("teamName")
    session = requests.Session()
    _db = get_db()

    if target_team:
        teams_ref = _db.collection("league_teams").where("Name", "==", target_team).stream()
    else:
        teams_ref = _db.collection("league_teams").stream()

    team_urls = [t.to_dict().get("URL") for t in teams_ref if t.to_dict().get("URL")]
    seen_match_urls: set = set()
    scraped_matches = []
    for team_url in team_urls:
        _, match_urls, _, _ = get_match_urls_for_team(team_url, session)
        for match_url in match_urls:
            if match_url in seen_match_urls:
                continue
            seen_match_urls.add(match_url)
            match = parse_match_detail(match_url, session)
            if match:
                scraped_matches.append(match)

    if scraped_matches:
        write_league_matches(_db, scraped_matches)
        log.info(f"Wrote {len(scraped_matches)} played match detail records.")

    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + str(uuid.uuid4())[:8]
    
    from scraper import Match, MatchLine
    
    _db = get_db()
    
    # 1. Read matches
    log.info("Reading league_matches...")
    matches_ref = _db.collection("league_matches").stream()
    matches_data = [m.to_dict() for m in matches_ref]
    
    all_matches = []
    for data in matches_data:
        try:
            # Reconstruct MatchLine objects
            lines = [MatchLine(
                line_number=l.get("line_number", 0),
                home_player1=l.get("home_player1", ""),
                home_player2=l.get("home_player2", ""),
                away_player1=l.get("away_player1", ""),
                away_player2=l.get("away_player2", ""),
                home_games_won=l.get("home_games_won", 0),
                home_games_lost=l.get("home_games_lost", 0),
                score_string=l.get("score_string", ""),
                tiebreak=l.get("tiebreak")
            ) for l in data.get("lines", [])]
            
            match = Match(
                match_date=data.get("match_date", ""),
                home_team=data.get("home_team", ""),
                away_team=data.get("away_team", ""),
                level=data.get("level", ""),
                lines=lines,
                match_url=data.get("match_url", "")
            )
            all_matches.append(match)
        except Exception as e:
            log.warning(f"Error parsing match doc: {e}")
    
    if not all_matches:
        return {"status": "error", "message": "No matches found. Run refresh_team_schedules first."}

    # 2. Derive team rankings
    log.info("Deriving team rankings...")
    team_rankings, total_teams = derive_team_rankings(matches_data)

    # 3. Build player records
    log.info("Building player records...")
    player_records = build_player_records(all_matches, team_rankings, total_teams)
    log.info(f"Found {len(player_records)} unique player names")

    # 4. Match users
    log.info("Matching to Firestore users...")
    users = get_all_users()
    
    stats = {
        "players_matched": 0,
        "players_unmatched": 0,
        "players_ambiguous": 0,
    }

    # 5. Write stats
    for scraped_name, records in player_records.items():
        uid, status = match_player_to_uid(scraped_name, users, MATCH_THRESHOLD)

        if status == "matched":
            pr = compute_power_rating(records)
            write_league_stats(_db, uid, scraped_name, pr, records, len(records))
            stats["players_matched"] += 1
        else:
            write_unmatched(_db, scraped_name, status, records, run_id)
            if status == "ambiguous":
                stats["players_ambiguous"] += 1
            else:
                stats["players_unmatched"] += 1

    log.info(f"refresh_player_ratings logic complete. Stats: {stats}")
    return {"status": "success", "stats": stats}
