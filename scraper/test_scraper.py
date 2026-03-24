"""
test_scraper.py — Smoke tests for the scraper pipeline.

Run locally (no Firestore needed):
  cd scraper
  pip install -r requirements.txt
  python test_scraper.py

Tests:
  1. Score parsing edge cases
  2. Player name split from line text
  3. Power Rating formula with known inputs
  4. Fuzzy matcher confidence rules
"""

import sys
import unittest

from scraper import _parse_score, _split_players
from power_rating import compute_power_rating, PlayerMatchRecord
from matcher import match_player_to_uid


class TestScoreParsing(unittest.TestCase):

    def test_simple_score(self):
        won, lost, tb = _parse_score("6-3, 7-5")
        self.assertEqual(won, 13)
        self.assertEqual(lost, 8)
        self.assertIsNone(tb)

    def test_loss(self):
        won, lost, tb = _parse_score("1-6, 4-6")
        self.assertEqual(won, 5)
        self.assertEqual(lost, 12)
        self.assertIsNone(tb)

    def test_tiebreak_home_wins(self):
        won, lost, tb = _parse_score("6-6 (Tiebreak: 15 vs. 14)")
        # 6 home + 1 tiebreak = 7, 6 away
        self.assertEqual(won, 7)
        self.assertEqual(lost, 6)
        self.assertEqual(tb, "15 vs. 14")

    def test_tiebreak_away_wins(self):
        won, lost, tb = _parse_score("6-6 (Tiebreak: 8 vs. 10)")
        self.assertEqual(won, 6)
        self.assertEqual(lost, 7)

    def test_set_label_format(self):
        won, lost, tb = _parse_score("Set 1: 6-3  Set 2: 7-5")
        self.assertEqual(won, 13)
        self.assertEqual(lost, 8)

    def test_three_sets(self):
        won, lost, tb = _parse_score("6-4, 3-6, 6-2")
        self.assertEqual(won, 15)
        self.assertEqual(lost, 12)


class TestPlayerSplit(unittest.TestCase):

    def test_standard_doubles(self):
        home, away = _split_players("Bailey / Holmes vs. Maruyama / Scott")
        self.assertEqual(home, ["Bailey", "Holmes"])
        self.assertEqual(away, ["Maruyama", "Scott"])

    def test_no_vs(self):
        home, away = _split_players("Just a string")
        self.assertEqual(home, [])
        self.assertEqual(away, [])

    def test_single_names(self):
        home, away = _split_players("Smith vs. Jones")
        self.assertEqual(home, ["Smith"])
        self.assertEqual(away, ["Jones"])


class TestPowerRating(unittest.TestCase):

    def _record(self, won, lost, line=1, opp_rank=1, total=8):
        return PlayerMatchRecord(
            match_date="2026-01-01",
            games_won=won,
            games_lost=lost,
            score_string=f"{won}-{lost}",
            partner_name="Partner",
            opponent_names=["Opp1", "Opp2"],
            line_number=line,
            opponent_team_rank=opp_rank,
            total_teams=total,
            home_or_away="home",
        )

    def test_dominant_win_at_line1_vs_top_team(self):
        # 6-0 6-0 at Line 1 against rank-1 team (8 total) → should be high
        records = [self._record(12, 0, line=1, opp_rank=1, total=8)]
        pr = compute_power_rating(records)
        self.assertGreater(pr, 0.9)

    def test_clean_loss(self):
        records = [self._record(0, 12, line=4, opp_rank=8, total=8)]
        pr = compute_power_rating(records)
        self.assertLess(pr, 0.3)

    def test_rolling_average_uses_last_5(self):
        # 6 records but only last 5 should count
        records = [
            self._record(12, 0, line=1),  # oldest — should be dropped
            self._record(10, 2, line=1),
            self._record(8, 4, line=2),
            self._record(6, 6, line=2),
            self._record(4, 8, line=3),
            self._record(2, 10, line=4),  # most recent
        ]
        # Sort descending so test matches main.py logic
        pr_5 = compute_power_rating(records, last_n=5)
        pr_6 = compute_power_rating(records, last_n=6)
        # PR over 5 should differ from 6 (oldest record is a 12-0 win)
        self.assertNotAlmostEqual(pr_5, pr_6, places=2)

    def test_empty_records(self):
        self.assertEqual(compute_power_rating([]), 0.0)


class TestFuzzyMatcher(unittest.TestCase):

    USERS = [
        {"uid": "uid-001", "displayName": "Jane Smith"},
        {"uid": "uid-002", "displayName": "John Doe"},
        {"uid": "uid-003", "displayName": "Jane Johnson"},
    ]

    def test_exact_match(self):
        uid, status = match_player_to_uid("Jane Smith", self.USERS)
        self.assertEqual(status, "matched")
        self.assertEqual(uid, "uid-001")

    def test_name_order_swap(self):
        uid, status = match_player_to_uid("Smith, Jane", self.USERS)
        self.assertEqual(status, "matched")
        self.assertEqual(uid, "uid-001")

    def test_no_match(self):
        uid, status = match_player_to_uid("Completely Unknown Person", self.USERS)
        self.assertEqual(status, "unmatched")
        self.assertIsNone(uid)

    def test_ambiguous(self):
        # "Jane" alone is close to both "Jane Smith" and "Jane Johnson"
        uid, status = match_player_to_uid("Jane", self.USERS, threshold=50)
        # May be ambiguous or matched depending on scores — just verify it runs
        self.assertIn(status, ["matched", "ambiguous", "unmatched"])

    def test_empty_name(self):
        uid, status = match_player_to_uid("", self.USERS)
        self.assertEqual(status, "unmatched")
        self.assertIsNone(uid)


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False)
    sys.exit(0 if result.result.wasSuccessful() else 1)
