---
name: Scraper — League Stats Cloud Run Job
description: Status and key facts about the tenniscores.com scraper deployed as a Cloud Run job
type: project
---

Scraper is deployed and working as of 2026-03-22. First successful run scraped 877 matches, found 1,257 unique player names, matched 11 to Firestore users.

**Why:** Teams feature (Phase 2) needs Power Ratings derived from North Shore league match data to drive the competitive lineup algorithm.

**How to apply:** When working on Teams feature UI or algorithm, league_stats/{uid} is the source of truth for PR. Don't denormalize PR into Contract documents — read from league_stats at display time.

## Location
`scraper/` directory at project root (separate from Flutter app and Firebase functions).

## Files
- `main.py` — orchestrator (5 steps: scrape → rank → build records → load users → match+write)
- `scraper.py` — BeautifulSoup scraper for northshore.tenniscores.com
- `power_rating.py` — PR formula + per-player record builder
- `matcher.py` — fuzzy name matching (thefuzz token_sort_ratio, threshold=75)
- `writer.py` — Firestore writes: league_stats, scraper_unmatched, scraper_runs
- `test_scraper.py` — 18 unit tests (all passing)
- `Dockerfile` — multi-stage python:3.11-slim, no local Docker needed
- `deploy.sh` — uses `gcloud builds submit` (Cloud Build, no local Docker)

## Deployed Infrastructure
- Cloud Run Job: `league-scraper` (us-central1)
- Cloud Scheduler: every Monday 06:00 UTC (`0 6 * * 1`)
- Image: `gcr.io/tennis-app-mp-2026/league-scraper:latest`
- Service account: `scraper-job@tennis-app-mp-2026.iam.gserviceaccount.com`

## Firestore Collections Written
- `league_stats/{uid}` — matched player PR + match history
- `scraper_unmatched/{auto}` — unmatched/ambiguous players for manual review (`resolved: false`)
- `scraper_runs/{run_id}` — audit log per execution

## Key Bugs Fixed During Deploy
1. Match URLs are in `table.standings-table2.division_standings`, NOT `table.team_schedule` — fixed by scanning whole page for print_match.php links
2. Each line is a SEPARATE `standings-table2` table (4 tables per match, 2 rows each), NOT rows in one big table — rewrote `_parse_lines` completely
3. Cloud Run IP blocked by site — fixed by using full Chrome browser headers (User-Agent + Accept + Sec-Fetch-* headers)
4. Team name in `table.team_roster_table` first row, not h1/h2 (which are empty)

## Known Limitations
- Team rankings proxy (derived from win counts across scraped matches) only found 1 "team" because team names differ slightly between team pages and match detail pages. Low priority — affects opponent quality multiplier in PR calculation but not correctness. Fix: scrape standings page directly for official rankings.
- 1,246 of 1,257 scraped players are unmatched (expected — most league players are not Adhoc Local users). As more users join and add their `source_name`, match rate will improve.

## Redeploy Command
```bash
cd ~/projects/AntiGravity/scraper
gcloud builds submit . --tag=gcr.io/tennis-app-mp-2026/league-scraper:latest --project=tennis-app-mp-2026 --quiet
gcloud run jobs update league-scraper --image=gcr.io/tennis-app-mp-2026/league-scraper:latest --region=us-central1 --project=tennis-app-mp-2026 --quiet
gcloud run jobs execute league-scraper --region=us-central1 --project=tennis-app-mp-2026
```
