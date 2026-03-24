"""
scraper.py — BeautifulSoup scraper for northshore.tenniscores.com

Discovers all team URLs from the main page, then for each team fetches
every match detail page. Returns a list of Match objects with per-line
player pairing and score data.
"""

import re
import logging
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
from urllib.parse import urlparse, urljoin

import requests
from bs4 import BeautifulSoup

BASE_URL = "https://northshore.tenniscores.com"
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Accept-Encoding": "gzip, deflate, br",
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "same-origin",
    "Referer": BASE_URL,
}


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class MatchLine:
    line_number: int
    home_player1: str
    home_player2: str
    away_player1: str
    away_player2: str
    home_games_won: int
    home_games_lost: int
    score_string: str          # e.g. "6-3, 7-5"
    tiebreak: Optional[str]    # e.g. "15 vs. 14", or None


@dataclass
class Match:
    match_date: str            # YYYY-MM-DD
    home_team: str
    away_team: str
    level: str
    lines: list = field(default_factory=list)   # list[MatchLine]
    match_url: str = ""
    location: str = ""         # Venue name; empty if not found on the page
    start_time: str = ""       # e.g. "10:00 AM"; empty if not found


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def _get_soup(url: str, session: requests.Session) -> Optional[BeautifulSoup]:
    try:
        resp = session.get(url, headers=HEADERS, timeout=20)
        resp.raise_for_status()
        return BeautifulSoup(resp.text, "lxml")
    except Exception as exc:
        logging.warning(f"Failed to fetch {url}: {exc}")
        return None


# ---------------------------------------------------------------------------
# Team discovery
# ---------------------------------------------------------------------------

def get_all_team_urls(session: requests.Session) -> list:
    """
    Fetch the main page and any AJAX standings endpoints to collect
    every team page URL found on the site.
    """
    team_urls: set = set()

    def _harvest_team_links(soup: BeautifulSoup):
        for a in soup.find_all("a", href=True):
            href = a["href"]
            if "team=nndz-" not in href:
                continue
            if href.startswith("http"):
                team_urls.add(href)
            elif href.startswith("?"):
                team_urls.add(f"{BASE_URL}/{href}")
            else:
                team_urls.add(f"{BASE_URL}/{href.lstrip('/')}")

    # Main page
    main_soup = _get_soup(BASE_URL, session)
    if not main_soup:
        logging.error("Cannot reach main page — aborting team discovery")
        return []
    _harvest_team_links(main_soup)

    # Division switcher → AJAX standings endpoints contain more team links
    switcher = (
        main_soup.find("select", id="standings_switcher")
        or main_soup.find("div", id="standings_switcher")
    )
    if switcher:
        for opt in switcher.find_all("option"):
            div_id = opt.get("value", "").strip()
            if not div_id:
                continue
            standings_soup = _get_soup(
                f"{BASE_URL}/print_standings.php?print&div={div_id}", session
            )
            if standings_soup:
                _harvest_team_links(standings_soup)

    logging.info(f"Discovered {len(team_urls)} unique team URLs")
    return list(team_urls)


# ---------------------------------------------------------------------------
# Team page — extract match detail URLs
# ---------------------------------------------------------------------------

def get_match_urls_for_team(team_url: str, session: requests.Session) -> tuple:
    """
    Returns (team_name: str, match_detail_urls: list[str], level: str, gender: str).
    level  — NTRP level string e.g. "3.5" or "" if not found.
    gender — "Men" | "Women" | "Mixed" | "" if not found.
    """
    soup = _get_soup(team_url, session)
    if not soup:
        return "", [], "", ""

    # Team name: in the first row of the team_roster_table header
    team_name = ""
    roster_table = soup.find("table", class_="team_roster_table")
    if roster_table:
        first_row = roster_table.find("tr")
        if first_row:
            first_cell = first_row.find("td") or first_row.find("th")
            if first_cell:
                team_name = first_cell.get_text(strip=True)

    # Level: scan the first ~1000 chars of page text for an NTRP pattern (2.5–6.0).
    # tenniscores pages typically show the division level in a heading or sidebar.
    page_text = soup.get_text(separator=" ")
    level = ""
    level_m = re.search(r'\b([2-6]\.[05])\b', page_text[:2000])
    if level_m:
        level = level_m.group(1)

    # Gender: check page title + team name + early page text for keywords.
    gender = ""
    search_text = (team_name + " " + page_text[:800]).lower()
    if any(kw in search_text for kw in ("women", "ladies", "female", "girl")):
        gender = "Women"
    elif any(kw in search_text for kw in ("men's", "mens", " men ", "male")):
        gender = "Men"
    elif "mixed" in search_text:
        gender = "Mixed"

    # Match result links — scan the whole page to be safe.
    match_urls_set = set()
    for a in soup.find_all("a", href=True):
        href = a["href"]
        if "print_match.php" not in href:
            continue
        if href.startswith("http"):
            match_urls_set.add(href)
        else:
            match_urls_set.add(f"{BASE_URL}/{href.lstrip('/')}")
    match_urls = list(match_urls_set)

    logging.info(
        f"  Team '{team_name}' (Level={level or '?'}, Gender={gender or '?'}): "
        f"{len(match_urls)} match URLs"
    )
    return team_name, match_urls, level, gender


# ---------------------------------------------------------------------------
# Team schedule page parser (all matches, played + upcoming)
# ---------------------------------------------------------------------------

def parse_team_schedule(
    team_url: str,
    session: requests.Session,
    season_start_year: Optional[int] = None,
) -> tuple:
    """
    Parse the team schedule table (table.team_schedule) on the team page.
    Returns (team_name: str, schedule: list[dict]).

    Each schedule dict:
      match_date    — YYYY-MM-DD (year inferred from season)
      is_home       — True if the team is the home side
      opponent      — opponent team name string
      opponent_url  — absolute URL to the opponent's club page (may be "")
      start_time    — e.g. "09:30 am" or "" if not listed
    """
    soup = _get_soup(team_url, session)
    if not soup:
        return "", []

    # Team name
    team_name = ""
    roster_table = soup.find("table", class_="team_roster_table")
    if roster_table:
        first_row = roster_table.find("tr")
        if first_row:
            first_cell = first_row.find("td") or first_row.find("th")
            if first_cell:
                team_name = first_cell.get_text(strip=True)

    # Infer season years from current date if not provided.
    # Leagues typically run September–April: months ≥ 9 belong to start_year,
    # months ≤ 8 belong to start_year + 1.
    if season_start_year is None:
        now = datetime.now()
        season_start_year = now.year if now.month >= 9 else now.year - 1
    season_end_year = season_start_year + 1

    sched_table = soup.find("table", class_="team_schedule")
    if not sched_table:
        logging.warning(f"No team_schedule table found at {team_url}")
        return team_name, []

    schedule = []
    for row in sched_table.find_all("tr", class_="team_schedule_tr"):
        cells = row.find_all("td")
        if not cells:
            continue

        # Date cell: "09/27 (H)" or "09/27 (A)"
        date_raw = cells[0].get_text(strip=True)
        date_m = re.match(r'(\d{2})/(\d{2})\s*\((H|A)\)', date_raw)
        if not date_m:
            continue  # Snow Date, Holiday Break, Playoffs rows — skip

        month = int(date_m.group(1))
        day = int(date_m.group(2))
        is_home = date_m.group(3) == "H"
        year = season_start_year if month >= 9 else season_end_year
        match_date = f"{year}-{month:02d}-{day:02d}"

        # Opponent from <strong> inside the desc cell.
        # The <strong> is often wrapped in an <a> linking to the opponent's page.
        desc_cell = cells[1]
        strong = desc_cell.find("strong")
        if not strong:
            continue  # no opponent = special row
        opponent = strong.get_text(strip=True)
        if not opponent:
            continue

        # Extract opponent club URL from the nearest <a> tag.
        opponent_url = ""
        link_tag = desc_cell.find("a", href=True)
        if link_tag:
            href = link_tag["href"]
            # Resolve relative URLs using the base of the current team_url.
            parsed_base = urlparse(team_url)
            base = f"{parsed_base.scheme}://{parsed_base.netloc}"
            opponent_url = urljoin(base, href)

        # Start time — result cell first (clean time for unplayed matches),
        # then fall back to the orange span in the desc cell.
        start_time = ""
        if len(cells) > 2:
            result_text = cells[2].get_text(" ", strip=True)
            t_m = re.search(r'\b(\d{1,2}:\d{2}\s*(?:am|pm))\b', result_text, re.I)
            if t_m:
                start_time = t_m.group(1)
        if not start_time:
            orange_span = desc_cell.find("span", class_="exsm-font-orange")
            if orange_span:
                t_m = re.search(
                    r'\b(\d{1,2}:\d{2}\s*(?:am|pm))\b',
                    orange_span.get_text(" ", strip=True),
                    re.I,
                )
                if t_m:
                    start_time = t_m.group(1)

        schedule.append({
            "match_date": match_date,
            "is_home": is_home,
            "opponent": opponent,
            "opponent_url": opponent_url,
            "start_time": start_time,
        })

    logging.info(f"  Team '{team_name}': {len(schedule)} scheduled matches parsed")
    return team_name, schedule


# ---------------------------------------------------------------------------
# Club address lookup
# ---------------------------------------------------------------------------

# Matches a US-style street address.
# Handles both "31 Tozer Rd Beverly MA 01915" and "9 Webster StreetWoburn, MA 01801-1550"
# (tenniscores sometimes concatenates street type + city with no space, and uses comma
# before state abbreviation).
_ADDRESS_RE = re.compile(
    r'\d+\s+[A-Za-z0-9][\w\s\.\-,]+'  # number + street (comma allowed for "City, ST" format)
    r'[A-Z]{2}\s+\d{5}(?:-\d{4})?',   # state abbrev + zip (no \b — handles no-space concat)
)


def parse_club_address(club_url: str, session: requests.Session) -> str:
    """
    Fetch an opponent club's page and return its venue address string,
    or '' if none can be found.

    Primary strategy: tenniscores pages always have a "Get Directions" Google Maps
    link whose href contains the full address as the q= parameter. This is the most
    reliable source across all clubs.

    Fallback: scan text nodes for a US address pattern (for any clubs that don't
    have a Maps link).
    """
    from urllib.parse import unquote_plus

    soup = _get_soup(club_url, session)
    if not soup:
        return ""

    # 1. Google Maps "Get Directions" link — most reliable.
    maps_link = soup.find("a", href=re.compile(r"maps\.google\.com.*[?&]q=", re.I))
    if maps_link:
        m = re.search(r"[?&]q=([^&]+)", maps_link["href"])
        if m:
            return unquote_plus(m.group(1)).strip()

    # 2. Single text node containing a full US address.
    for text_node in soup.find_all(string=_ADDRESS_RE):
        m = _ADDRESS_RE.search(text_node)
        if m:
            return m.group(0).strip()

    logging.debug(f"  No address found on {club_url}")
    return ""


# ---------------------------------------------------------------------------
# Score parsing
# ---------------------------------------------------------------------------

def _parse_score(score_str: str) -> tuple:
    """
    Parse a raw score string into (home_games_won, home_games_lost, tiebreak_str|None).

    Handles:
      "6-3, 7-5"
      "1-6, 6-6 (Tiebreak: 15 vs. 14)"
      "Set 1: 6-3  Set 2: 7-5"
    """
    tiebreak: Optional[str] = None

    # Extract tiebreak info before stripping it
    tb_match = re.search(r'\(Tiebreak:\s*(\d+)\s*vs\.?\s*(\d+)\)', score_str, re.I)
    if tb_match:
        tiebreak = f"{tb_match.group(1)} vs. {tb_match.group(2)}"
        score_str = re.sub(r'\s*\([^)]*Tiebreak[^)]*\)', '', score_str, flags=re.I)

    # Remove "Set N:" labels
    score_str = re.sub(r'Set\s+\d+\s*:', ' ', score_str, flags=re.I)

    home_games = 0
    away_games = 0
    for home, away in re.findall(r'(\d+)-(\d+)', score_str):
        home_games += int(home)
        away_games += int(away)

    # Tiebreak winner gets 1 extra game credit
    if tb_match:
        if int(tb_match.group(1)) > int(tb_match.group(2)):
            home_games += 1
        else:
            away_games += 1

    return home_games, away_games, tiebreak


# ---------------------------------------------------------------------------
# Match detail page parser
# ---------------------------------------------------------------------------

def parse_match_detail(url: str, session: requests.Session) -> Optional[Match]:
    """
    Parse a print_match.php page into a Match object.
    Returns None on fetch failure or if no line data is found.
    """
    soup = _get_soup(url, session)
    if not soup:
        return None

    full_text = soup.get_text(separator="\n")

    # --- Match date ---
    match_date = datetime.now().strftime("%Y-%m-%d")  # fallback
    # Primary: some pages use "Match Date:" label.
    # Fallback: this site embeds the date in the header line as
    #   "Level 1        March 6, 2026" — no "Match Date:" label at all.
    date_search = (
        re.search(r'Match Date:\s*(.+)', full_text, re.I)
        or re.search(r'Level\s+\S+\s+(\w[^\n]+)', full_text, re.I)
    )
    if date_search:
        raw = date_search.group(1).strip().split("\n")[0].strip()
        # Clean suffix like "st", "nd", "rd", "th" from the day part.
        raw_cleaned = re.sub(r'(?<=\d)(st|nd|rd|th)\b', '', raw)
        for fmt in ("%A, %B %d, %Y", "%A, %b %d, %Y", "%B %d, %Y", "%b %d, %Y", "%m/%d/%Y"):
            try:
                match_date = datetime.strptime(raw_cleaned, fmt).strftime("%Y-%m-%d")
                break
            except ValueError:
                continue

    # --- Team names ---
    home_team, away_team = "", ""
    header_div = soup.find("div", class_="datelocheader")
    if header_div:
        header_text = header_div.get_text(separator=" ", strip=True)
        # format: "Away Team @ Home Team:"
        if "@" in header_text:
            split_at = header_text.split("@")
            away_team = split_at[0].strip()
            home_part = split_at[1].split(":")[0].strip()
            home_team = home_part
    else:
        # Fallback to old regex just in case
        home_m = re.search(r'Home Team:\s*(.+)', full_text, re.I)
        away_m = re.search(r'Away Team:\s*(.+)', full_text, re.I)
        if home_m:
            home_team = home_m.group(1).strip().split("\n")[0].strip()
        if away_m:
            away_team = away_m.group(1).strip().split("\n")[0].strip()

    # --- Level ---
    level = ""
    level_m = re.search(r'Level:\s*(.+)', full_text, re.I)
    if level_m:
        level = level_m.group(1).strip().split("\n")[0].strip()

    # --- Location / Venue ---
    location = ""
    loc_m = re.search(r'(?:Location|Venue|Facility):\s*(.+)', full_text, re.I)
    if loc_m:
        location = loc_m.group(1).strip().split("\n")[0].strip()

    # --- Start time ---
    start_time = ""
    time_m = re.search(r'(?:Start\s+)?Time:\s*(\d{1,2}:\d{2}\s*(?:AM|PM)?)', full_text, re.I)
    if time_m:
        start_time = time_m.group(1).strip()

    # --- Line-by-line results ---
    # The match detail table uses class="standings-table2".
    # Row structure (typical):
    #   Row A: "Line 1"  (or "Line 1: Player1 / Player2 vs. Player3 / Player4")
    #   Row B: score info  "Set 1: 1-6  Set 2: 4-6"
    # Sometimes players and scores are in the same row; sometimes split.
    table_count = len(soup.find_all("table", class_="standings-table2"))
    lines = _parse_lines(soup)

    if not lines:
        logging.warning(
            f"No line data in {url} "
            f"(html_len={len(soup.get_text())}, standings_tables={table_count})"
        )
        return None

    return Match(
        match_date=match_date,
        home_team=home_team,
        away_team=away_team,
        level=level,
        lines=lines,
        match_url=url,
        location=location,
        start_time=start_time,
    )


def _parse_lines(soup: BeautifulSoup) -> list:
    """
    Extract MatchLine objects from the match detail page.

    Each line is a separate <table class="standings-table2"> with exactly 2 rows:
      Row 0: [Line N, '', 'Home P1/Home P2', set1_home, set2_home, (tb_home)]
      Row 1: ['',     'Away P1/Away P2',     set1_away, set2_away, (tb_away)]

    Scores are game counts per set. Tiebreak winner gets +1 game.
    Players may have "(S)" suffix for substitutes — stripped before storing.
    """
    lines = []

    for table in soup.find_all("table", class_="standings-table2"):
        rows = table.find_all("tr")
        if len(rows) < 2:
            continue

        home_cells = [td.get_text(strip=True) for td in rows[0].find_all(["td", "th"])]
        away_cells = [td.get_text(strip=True) for td in rows[1].find_all(["td", "th"])]

        if not home_cells:
            continue

        # Row 0 must start with "Line N"
        line_m = re.match(r'Line\s+(\d+)', home_cells[0], re.I)
        if not line_m:
            continue

        line_number = int(line_m.group(1))

        # Player pairs are slash-separated in one cell
        # Row 0 cell 2: home pair. Row 1 cell 1: away pair.
        home_pair_str = home_cells[2] if len(home_cells) > 2 else ""
        away_pair_str = away_cells[1] if len(away_cells) > 1 else ""

        home_players = _clean_players(home_pair_str)
        away_players = _clean_players(away_pair_str)

        # Score cells: home_cells[3], home_cells[4] = set1_home, set2_home
        #              away_cells[2], away_cells[3] = set1_away, set2_away
        # Optional: home_cells[5], away_cells[4] = tiebreak scores
        try:
            s1h = int(home_cells[3]) if len(home_cells) > 3 and home_cells[3].isdigit() else 0
            s2h = int(home_cells[4]) if len(home_cells) > 4 and home_cells[4].isdigit() else 0
            s1a = int(away_cells[2]) if len(away_cells) > 2 and away_cells[2].isdigit() else 0
            s2a = int(away_cells[3]) if len(away_cells) > 3 and away_cells[3].isdigit() else 0
        except (IndexError, ValueError):
            continue

        home_games_won = s1h + s2h
        home_games_lost = s1a + s2a

        # Tiebreak
        tiebreak: Optional[str] = None
        tb_h_str = home_cells[5] if len(home_cells) > 5 else ""
        tb_a_str = away_cells[4] if len(away_cells) > 4 else ""
        if tb_h_str.isdigit() and tb_a_str.isdigit():
            tb_h, tb_a = int(tb_h_str), int(tb_a_str)
            tiebreak = f"{tb_h} vs. {tb_a}"
            if tb_h > tb_a:
                home_games_won += 1
            else:
                home_games_lost += 1

        score_string = f"{s1h}-{s1a}, {s2h}-{s2a}"
        if tiebreak:
            score_string += f" (Tiebreak: {tiebreak})"

        hp1 = home_players[0] if len(home_players) > 0 else ""
        hp2 = home_players[1] if len(home_players) > 1 else ""
        ap1 = away_players[0] if len(away_players) > 0 else ""
        ap2 = away_players[1] if len(away_players) > 1 else ""

        # Skip if no meaningful player data
        if not any([hp1, hp2, ap1, ap2]):
            continue

        lines.append(MatchLine(
            line_number=line_number,
            home_player1=hp1,
            home_player2=hp2,
            away_player1=ap1,
            away_player2=ap2,
            home_games_won=home_games_won,
            home_games_lost=home_games_lost,
            score_string=score_string,
            tiebreak=tiebreak,
        ))

    return lines


def _clean_players(pair_str: str) -> list:
    """
    Split 'Player1/Player2' into a clean list, stripping '(S)' substitute markers.
    """
    players = []
    for name in pair_str.split("/"):
        name = re.sub(r'\s*\(S\)\s*', '', name, flags=re.I).strip()
        if name:
            players.append(name)
    return players


def _split_players(text: str) -> tuple:
    """
    Split "Player1 / Player2 vs. Player3 / Player4" into
    ([home_player1, home_player2], [away_player1, away_player2]).
    Returns ([], []) if the pattern doesn't match.
    """
    vs_split = re.split(r'\s+vs\.?\s+', text, maxsplit=1, flags=re.I)
    if len(vs_split) != 2:
        return [], []

    home_players = [p.strip() for p in vs_split[0].split("/") if p.strip()]
    away_players = [p.strip() for p in vs_split[1].split("/") if p.strip()]
    return home_players, away_players


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

def scrape_all(session: requests.Session) -> tuple:
    """
    Entry point: discover all teams, scrape all unique match detail pages.
    Returns (all_matches, all_teams).
    """
    team_urls = get_all_team_urls(session)
    if not team_urls:
        raise RuntimeError("No team URLs discovered — check site availability")

    seen_match_urls: set = set()
    all_matches = []
    teams_dict = {}

    for i, team_url in enumerate(team_urls):
        logging.info(f"Team {i+1}/{len(team_urls)}: {team_url}")
        team_name, match_urls = get_match_urls_for_team(team_url, session)
        
        if team_url not in teams_dict:
            teams_dict[team_url] = {
                "Name": team_name,
                "URL": team_url,
                "Level": "",
                "Gender": ""
            }

        for match_url in match_urls:
            if match_url in seen_match_urls:
                continue
            seen_match_urls.add(match_url)

            match = parse_match_detail(match_url, session)
            if match:
                all_matches.append(match)
                
                # Infer level and gender based on match.level
                if not teams_dict[team_url]["Level"] and match.level:
                    teams_dict[team_url]["Level"] = match.level
                    level_lower = match.level.lower()
                    if "women" in level_lower or "ladies" in level_lower:
                        teams_dict[team_url]["Gender"] = "Women"
                    elif "men" in level_lower:
                        teams_dict[team_url]["Gender"] = "Men"
                    elif "mixed" in level_lower:
                        teams_dict[team_url]["Gender"] = "Mixed"
                    else:
                        teams_dict[team_url]["Gender"] = "Unknown"

    logging.info(f"Scraped {len(all_matches)} unique matches total")
    return all_matches, list(teams_dict.values())
