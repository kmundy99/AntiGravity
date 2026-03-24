"""
power_rating.py — Player match record building and Power Rating computation.

Power Rating (PR) is a rolling metric over the last 5 matches that rewards:
  - Winning by a large margin (margin bonus)
  - Beating highly-ranked teams (opponent quality multiplier)
  - Playing at a higher line (line weight)

PR range is approximately 0.0–1.3.
"""

from dataclasses import dataclass, field
from typing import Optional


# ---------------------------------------------------------------------------
# Data class
# ---------------------------------------------------------------------------

@dataclass
class PlayerMatchRecord:
    match_date: str           # YYYY-MM-DD — used for sorting (most recent N)
    games_won: int
    games_lost: int
    score_string: str
    partner_name: str
    opponent_names: list      # list[str]
    line_number: int          # 1 = top line (toughest), 4 = bottom
    opponent_team_rank: Optional[int]  # 1 = best team in division
    total_teams: int
    home_or_away: str         # "home" | "away"


# ---------------------------------------------------------------------------
# PR formula
# ---------------------------------------------------------------------------

def compute_power_rating(records: list, last_n: int = 5) -> float:
    """
    Compute a Power Rating from the `last_n` most recent match records.

    Formula per match:
        match_score  = games_won / (games_won + games_lost)
        margin_bonus = clamp((games_won - games_lost) / 12, -0.10, +0.10)
        opp_quality  = 1 + ((total_teams - opp_rank) / total_teams) * 0.20
        line_weight  = 1 + ((max_lines - line_number) / max_lines) * 0.15
        weighted     = (match_score + margin_bonus) * opp_quality * line_weight

    PR = mean(weighted scores over last_n matches)
    """
    if not records:
        return 0.0

    MAX_LINES = 4

    # Sort descending by date, take last_n
    recent = sorted(records, key=lambda r: r.match_date, reverse=True)[:last_n]

    weighted_scores = []
    for r in recent:
        total = r.games_won + r.games_lost
        if total == 0:
            continue

        match_score = r.games_won / total

        raw_margin = (r.games_won - r.games_lost) / 12
        margin_bonus = max(-0.10, min(0.10, raw_margin))

        if r.opponent_team_rank and r.total_teams > 1:
            opp_quality = 1 + (
                (r.total_teams - r.opponent_team_rank) / r.total_teams
            ) * 0.20
        else:
            opp_quality = 1.0   # unknown rank → neutral

        line_weight = 1 + (
            (MAX_LINES - min(r.line_number, MAX_LINES)) / MAX_LINES
        ) * 0.15

        weighted_scores.append((match_score + margin_bonus) * opp_quality * line_weight)

    if not weighted_scores:
        return 0.0

    return round(sum(weighted_scores) / len(weighted_scores), 4)


# ---------------------------------------------------------------------------
# Player record builder
# ---------------------------------------------------------------------------

def build_player_records(
    all_matches: list,
    team_rankings: dict,   # { team_name_lower: rank_int }
    total_teams: int,
) -> dict:
    """
    Walk all scraped Match objects and produce a per-player match record list.

    Returns:
        { player_name_lower: [PlayerMatchRecord, ...] }

    Each player appears on both sides of every line they played, with
    games_won/games_lost flipped appropriately for away players.
    """
    player_records: dict = {}

    for match in all_matches:
        home_rank = team_rankings.get(match.home_team.lower())
        away_rank = team_rankings.get(match.away_team.lower())

        for line in match.lines:
            # Home pair
            _add(player_records, line.home_player1, line.home_player2,
                 [line.away_player1, line.away_player2],
                 line.home_games_won, line.home_games_lost,
                 line.score_string, line.line_number,
                 match.match_date, away_rank, total_teams, "home")

            _add(player_records, line.home_player2, line.home_player1,
                 [line.away_player1, line.away_player2],
                 line.home_games_won, line.home_games_lost,
                 line.score_string, line.line_number,
                 match.match_date, away_rank, total_teams, "home")

            # Away pair (games flipped)
            _add(player_records, line.away_player1, line.away_player2,
                 [line.home_player1, line.home_player2],
                 line.home_games_lost, line.home_games_won,
                 line.score_string, line.line_number,
                 match.match_date, home_rank, total_teams, "away")

            _add(player_records, line.away_player2, line.away_player1,
                 [line.home_player1, line.home_player2],
                 line.home_games_lost, line.home_games_won,
                 line.score_string, line.line_number,
                 match.match_date, home_rank, total_teams, "away")

    return player_records


def _add(
    records_dict: dict,
    player_name: str,
    partner_name: str,
    opponent_names: list,
    games_won: int,
    games_lost: int,
    score_string: str,
    line_number: int,
    match_date: str,
    opponent_team_rank: Optional[int],
    total_teams: int,
    home_or_away: str,
):
    """Append a single match record to a player's list."""
    name = (player_name or "").strip()
    if not name:
        return

    key = name.lower()
    if key not in records_dict:
        records_dict[key] = []

    records_dict[key].append(PlayerMatchRecord(
        match_date=match_date,
        games_won=games_won,
        games_lost=games_lost,
        score_string=score_string,
        partner_name=(partner_name or "").strip(),
        opponent_names=[n for n in opponent_names if n and n.strip()],
        line_number=line_number,
        opponent_team_rank=opponent_team_rank,
        total_teams=total_teams,
        home_or_away=home_or_away,
    ))
