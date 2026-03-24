"""
matcher.py — Fuzzy name matching between scraped player names and Firestore users.

Uses token sort ratio (thefuzz) which handles name-order differences:
  "Smith, Jane" ↔ "Jane Smith" → 100
  "J. Smith"    ↔ "Jane Smith" → 72

Confidence rules:
  - Single candidate above threshold → "matched"
  - Top candidate ≥15 points ahead of second → "matched"
  - Multiple close candidates            → "ambiguous" (written to staging)
  - No candidate above threshold         → "unmatched"  (written to staging)
"""

import logging
from typing import Optional

from thefuzz import fuzz


def normalize(name: str) -> str:
    """Lowercase and strip punctuation for comparison."""
    import re
    name = name.strip().lower()
    name = re.sub(r"[.,'-]", " ", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name


def match_player_to_uid(
    scraped_name: str,
    users: list,           # list of { uid: str, displayName: str }
    threshold: int = 75,
) -> tuple:
    """
    Returns (uid | None, status_str).

    status_str is one of: "matched", "ambiguous", "unmatched"
    """
    if not scraped_name.strip():
        return None, "unmatched"

    norm_scraped = normalize(scraped_name)
    candidates = []

    for user in users:
        display = (user.get("displayName") or user.get("display_name") or "").strip()
        if not display:
            continue

        score = fuzz.token_sort_ratio(norm_scraped, normalize(display))
        if score >= threshold:
            candidates.append((score, user["uid"], display))

    if not candidates:
        return None, "unmatched"

    # Sort descending by score
    candidates.sort(key=lambda x: x[0], reverse=True)

    if len(candidates) == 1:
        logging.debug(
            f"Matched '{scraped_name}' → '{candidates[0][2]}' (score={candidates[0][0]})"
        )
        return candidates[0][1], "matched"

    # Top score ≥15 ahead of second → still confident
    if candidates[0][0] - candidates[1][0] >= 15:
        logging.debug(
            f"Matched '{scraped_name}' → '{candidates[0][2]}' "
            f"(score={candidates[0][0]}, gap={candidates[0][0]-candidates[1][0]})"
        )
        return candidates[0][1], "matched"

    # Multiple close matches → ambiguous
    top3 = ", ".join(f"{d} ({s})" for s, _, d in candidates[:3])
    logging.warning(f"Ambiguous match for '{scraped_name}': {top3}")
    return None, "ambiguous"
