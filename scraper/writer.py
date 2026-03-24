"""
writer.py — Firestore write operations for the scraper.

Collections written:
  league_stats/{uid}        — matched player PR and match history
  scraper_unmatched/{auto}  — players that couldn't be matched (for manual review)
  scraper_runs/{run_id}     — run-level audit log
"""

import logging
import re
from datetime import datetime, timezone
from typing import Optional


def write_league_stats(
    db,
    uid: str,
    source_name: str,
    power_rating: float,
    records: list,           # list[PlayerMatchRecord]
    total_scraped: int,
):
    """
    Write (or overwrite) a league_stats document for a successfully matched player.

    The app reads power_rating from this collection when displaying lineup screens.
    We intentionally do NOT denormalize PR into the Contract's embedded ContractPlayer
    array here — that would require querying every contract. Instead the app does a
    single read from league_stats at display time.
    """
    matches_data = []
    for r in sorted(records, key=lambda x: x.match_date, reverse=True):
        matches_data.append({
            "match_date": r.match_date,
            "games_won": r.games_won,
            "games_lost": r.games_lost,
            "score_string": r.score_string,
            "partner_name": r.partner_name,
            "opponent_names": r.opponent_names,
            "line_number": r.line_number,
            "opponent_team_rank": r.opponent_team_rank,
            "home_or_away": r.home_or_away,
        })

    db.collection("league_stats").document(uid).set({
        "uid": uid,
        "source_name": source_name,
        "last_scraped": datetime.now(timezone.utc),
        "power_rating": power_rating,
        "matches": matches_data,
        "total_matches_scraped": total_scraped,
    })

    logging.debug(f"Wrote league_stats/{uid[:8]}... PR={power_rating}")


def write_unmatched(
    db,
    scraped_name: str,
    status: str,             # "unmatched" | "ambiguous"
    records: list,
    run_id: str,
):
    """
    Write an unmatched/ambiguous player to the staging collection.

    Fields:
      scraped_name   — name as it appeared on tenniscores.com
      status         — "unmatched" or "ambiguous"
      match_count    — number of matches found for this player
      run_id         — links back to the scraper_runs document
      resolved       — False until a human manually matches and resolves
    """
    db.collection("scraper_unmatched").add({
        "scraped_name": scraped_name,
        "status": status,
        "match_count": len(records),
        "run_id": run_id,
        "created_at": datetime.now(timezone.utc),
        "resolved": False,
    })


def write_run_log(
    db,
    run_id: str,
    stats: dict,
):
    """
    Write a scraper_runs audit document.

    stats dict expected keys:
      started_at, matches_scraped, players_found,
      players_matched, players_unmatched, players_ambiguous,
      success, error
    """
    db.collection("scraper_runs").document(run_id).set({
        "run_id": run_id,
        "started_at": stats.get("started_at"),
        "completed_at": datetime.now(timezone.utc),
        "matches_scraped": stats.get("matches_scraped", 0),
        "players_found": stats.get("players_found", 0),
        "players_matched": stats.get("players_matched", 0),
        "players_unmatched": stats.get("players_unmatched", 0),
        "players_ambiguous": stats.get("players_ambiguous", 0),
        "success": stats.get("success", False),
        "error": stats.get("error"),
    })


def _slugify(s: str) -> str:
    """
    Lowercase and strip ALL non-alphanumeric characters.
    e.g. "Woburn Racquet Club - Blue" → "woburnracquetclubblue"

    Used as both the Firestore document ID for league_teams and as a stored
    field on league_matches so the Dart app can query by slug instead of
    relying on an exact string match that is fragile to dashes/spaces/casing.
    """
    return re.sub(r'[^a-z0-9]', '', s.lower().strip())


def _team_doc_id(name: str) -> str:
    """Stable Firestore doc ID for a team: slug of its name."""
    return _slugify(name) or 'unknown_team'


def _match_doc_id(match_date: str, home_team: str, away_team: str) -> str:
    """
    Stable doc ID for a league match: {date}__{home_slug}_vs_{away_slug}.
    Deterministic — the same fixture scraped from two team pages lands on the
    same document and is merged rather than duplicated.
    """
    return f"{match_date}__{_slugify(home_team)}_vs_{_slugify(away_team)}"


def _team_url_doc_id(team_url: str) -> str:
    """
    Derive a stable Firestore doc ID from a team URL.
    Extracts the `team=` query-string value, URL-decodes it, and strips
    trailing `=` so the result is a clean alphanumeric+dash identifier.

    e.g. "...&team=nndz-WkNTL3lMcjk%3D" → "nndz-WkNTL3lMcjk"
    """
    from urllib.parse import urlparse, parse_qs, unquote
    try:
        parsed = urlparse(team_url)
        params = parse_qs(parsed.query)
        raw = params.get("team", [""])[0]
        return unquote(raw).rstrip("=")
    except Exception:
        return ""


def write_league_teams(db, teams_list: list):
    """
    Save teams to league_teams.

    New schema (from hierarchical scraper):
      doc ID   = team= URL param (unique across all leagues/divisions)
      fields   = team_name, team_url, team_slug, league_name, division_name

    Legacy schema (old flat scraper) docs are left untouched; they simply
    won't have league_name/division_name and won't appear in the new
    cascading UI queries that filter by those fields.
    """
    batch = db.batch()
    count = 0
    for team in teams_list:
        team_url = (team.get("team_url") or team.get("URL") or "").strip()
        team_name = (team.get("team_name") or team.get("Name") or "").strip()
        if not team_name:
            continue

        doc_id = _team_url_doc_id(team_url) if team_url else _slugify(team_name)
        if not doc_id:
            continue

        data = {
            "team_name": team_name,
            "team_url": team_url,
            "team_slug": _slugify(team_name),
            "league_name": team.get("league_name", ""),
            "division_name": team.get("division_name", ""),
        }
        # Preserve legacy fields if present
        if team.get("Level"):
            data["Level"] = team["Level"]
        if team.get("Gender"):
            data["Gender"] = team["Gender"]

        doc_ref = db.collection("league_teams").document(doc_id)
        batch.set(doc_ref, data, merge=True)
        count += 1
        if count % 400 == 0:
            batch.commit()
            batch = db.batch()

    batch.commit()
    logging.info(f"Wrote {count} teams to league_teams")


def write_league_matches(db, matches_list: list):
    """
    Save scraped matches to league_matches using a stable, deterministic doc ID
    of the form  {match_date}__{home_team}_vs_{away_team}.

    Because the ID is derived solely from the fixture (not the URL), the same
    match scraped from both the home and the away team pages writes to the same
    document and is merged rather than duplicated.
    """
    batch = db.batch()
    count = 0
    for match in matches_list:
        doc_id = _match_doc_id(match.match_date, match.home_team, match.away_team)
        doc_ref = db.collection("league_matches").document(doc_id)
        
        lines_data = []
        for line in match.lines:
            lines_data.append({
                "line_number": line.line_number,
                "home_player1": line.home_player1,
                "home_player2": line.home_player2,
                "away_player1": line.away_player1,
                "away_player2": line.away_player2,
                "home_games_won": line.home_games_won,
                "home_games_lost": line.home_games_lost,
                "score_string": line.score_string,
                "tiebreak": line.tiebreak,
            })
            
        data = {
            "match_date": match.match_date,
            "home_team": match.home_team,
            "home_team_slug": _slugify(match.home_team),
            "away_team": match.away_team,
            "away_team_slug": _slugify(match.away_team),
            "level": match.level,
            "match_url": match.match_url,
            "lines": lines_data,
            "scraped_at": datetime.now(timezone.utc),
        }
        if getattr(match, 'location', ''):
            data["location"] = match.location
        if getattr(match, 'start_time', ''):
            data["start_time"] = match.start_time
        
        batch.set(doc_ref, data, merge=True)
        count += 1
        if count % 400 == 0:
            batch.commit()
            batch = db.batch()

    batch.commit()  # flush remaining
    logging.info(f"Wrote {count} matches to league_matches")


def write_league_schedule(db, team_name: str, schedule: list, team_url: str = ""):
    """
    Write team schedule entries to league_matches.

    Uses merge=True so that score/line data written by write_league_matches
    (from match detail pages) is preserved when the schedule is re-synced.

    Each entry dict must have: match_date, is_home, opponent, start_time.
    When is_home=True: home_team=team_name, away_team=opponent.
    When is_home=False: home_team=opponent, away_team=team_name.
    """
    batch = db.batch()
    count = 0
    for entry in schedule:
        if entry["is_home"]:
            home_team = team_name
            away_team = entry["opponent"]
        else:
            home_team = entry["opponent"]
            away_team = team_name

        doc_id = _match_doc_id(entry["match_date"], home_team, away_team)
        doc_ref = db.collection("league_matches").document(doc_id)

        data = {
            "match_date": entry["match_date"],
            "home_team": home_team,
            "home_team_slug": _slugify(home_team),
            "away_team": away_team,
            "away_team_slug": _slugify(away_team),
            "scraped_at": datetime.now(timezone.utc),
        }
        if entry.get("start_time"):
            data["start_time"] = entry["start_time"]
        if entry.get("location"):
            data["location"] = entry["location"]
        if team_url:
            data["team_url"] = team_url

        batch.set(doc_ref, data, merge=True)
        count += 1
        if count % 400 == 0:
            batch.commit()
            batch = db.batch()

    batch.commit()
    logging.info(f"Wrote {count} schedule entries to league_matches")
