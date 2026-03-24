# APP_BLUEPRINT.md — Adhoc Local
> **Vibe document for full-stack rebuild (Next.js / Firebase)**
> Describes *what* the product does and *how* its data interacts — no framework-specific code.

---

## 1. CORE IDENTITY

**Adhoc Local** is a tennis coordination tool for local recreational communities. It solves two distinct problems:

1. **Ad-hoc matches** — A player wants to get a group together this Saturday. They open the app, see who is likely free, pick a court, tap a few names, and everyone gets an email invite with a one-click accept link.
2. **Seasonal court contracts** — An organizer books a court every Sunday morning for a full season and needs to manage 12–20 players across 30+ weekly sessions: collecting availability, publishing lineups fairly, chasing payments, and sending automated emails without turning it into a part-time job.

The app is intentionally **community-scoped** — it's not a marketplace or ladder app. Everyone on the platform knows each other (or is two degrees away). Authentication is lightweight (passwordless email link). All coordination happens via email; there are no push notifications.

---

## 2. DATA MODELS

### 2.1 Users (Players)

**Firestore collection**: `users/{uid}`
Each document ID is a stable UUID (not phone number). Phone/email are stored as profile fields.

| Field | Type | Description |
|---|---|---|
| `uid` | string | Stable UUID; also the Firestore doc ID |
| `displayName` | string | Required. Public-facing name |
| `email` | string | Used for email notifications and login |
| `phoneNumber` | string | Optional; retained for SMS fallback |
| `primaryContact` | string | Catch-all contact field (phone or email) |
| `ntrpLevel` | number | 0.0 = Not Rated; valid range 2.5–5.0 |
| `gender` | string | `Male` / `Female` / `Non-Binary` / `Other` |
| `address` | string | Stored as a 5-digit US zip code |
| `notifActive` | boolean | If false, skip all new-match invite emails |
| `notifMode` | string | `SMS` / `Email` / `Both` |
| `accountStatus` | string | `provisional` / `fully_registered` |
| `weeklyAvailability` | map | `{ "Monday": ["morning", "afternoon"], ... }` |
| `blackouts` | array | List of `{ start, end, reason? }` date ranges |
| `circleRatings` | map | `{ [otherUid]: 1 | 2 | 3 }` — private groupings |
| `defaultDistanceFilter` | number | Miles radius for player directory filtering |
| `isAdmin` | boolean | Platform admin flag |
| `createdAt` | timestamp | Account creation time |
| `activatedAt` | timestamp | When profile was fully completed |
| `createdByUid` | string | UID of user who added this as a Custom Player |
| `lastLoginAt` | timestamp | Last login |

**Account States**:
- `provisional` — Created by invite ("Custom Player") or first login. Can accept invites, limited features until profile completed.
- `fully_registered` — Full profile filled in; all features unlocked.

**Availability Model**:
- `weeklyAvailability`: a recurring weekly grid. Keys are day names; values are arrays of time periods (`morning` = 5am–noon, `afternoon` = noon–5pm, `evening` = 5pm–11pm).
- `blackouts`: explicit date-range overrides. A player with a blackout covering a given date is treated as unavailable regardless of their weekly grid.

**Circles** (private grouping):
- `circleRatings` is a map where the key is another user's UID and the value is an integer (1, 2, or 3).
- Circles are purely private — they are never revealed to the player who was assigned.
- Organizers use circles to filter the player directory when building a match invite list. Typical use: Circle 1 = top skill tier, Circle 2 = friends, Circle 3 = newer players.

---

### 2.2 Matches (Ad-hoc Play)

**Firestore collection**: `matches/{id}`

| Field | Type | Description |
|---|---|---|
| `id` | string | Firestore doc ID |
| `organizerId` | string | UID of the organizer |
| `location` | string | Court address |
| `matchDate` | timestamp | Date and time of the match |
| `status` | string | `Draft` / `Filling` / `Completed` |
| `requiredCount` | number | Max players: 2, 3, 4, or 6 |
| `minNtrp` | number | Minimum NTRP filter |
| `maxNtrp` | number | Maximum NTRP filter |
| `roster` | array | Embedded list of `Roster` objects (see below) |
| `currentTier` | number | Division tracking (reserved for future use) |

**Roster** (embedded array within Match):

| Field | Type | Description |
|---|---|---|
| `uid` | string | Player UUID |
| `displayName` | string | Cached at invite time |
| `status` | string | `invited` / `accepted` / `declined` / `waitlisted` |
| `ntrpLevel` | number | Cached NTRP at invite time |
| `waitlistTimestamp` | timestamp | Set when player is added to waitlist |

**Match Status lifecycle**:
`Draft` → `Filling` (once published/shared) → `Completed` (after match date passes)

**Chat** (subcollection):
`matches/{id}/chats/{msgId}` — real-time in-match group chat. Visible only to confirmed players and the organizer.

---

### 2.3 Contracts (Seasonal Court Booking)

**Firestore collection**: `contracts/{id}`

| Field | Type | Description |
|---|---|---|
| `id` | string | Firestore doc ID |
| `organizerId` | string | UID of the organizer |
| `clubName` | string | Facility/court name |
| `clubAddress` | string | Full address |
| `courtNumbers` | array | e.g., `[1, 2]` |
| `courtsCount` | number | Total courts booked per session |
| `weekday` | number | 1=Mon … 7=Sun |
| `startMinutes` | number | Session start (minutes from midnight) |
| `endMinutes` | number | Session end (minutes from midnight) |
| `seasonStart` | timestamp | First session date |
| `seasonEnd` | timestamp | Last possible session date |
| `holidayDates` | array | Dates to skip (no session) |
| `status` | string | `draft` / `active` / `completed` |
| `roster` | array | List of `ContractPlayer` objects (see below) |
| `rosterUids` | array | Denormalized UID list for `array-contains` queries |
| `totalContractCost` | number | Organizer's total outlay for the season |
| `pricePerSlot` | number | Cost per player per session |
| `paymentInfo` | string | Free-text payment instructions shown to players |
| `organizerPin` | string | Optional 4-digit PIN protecting organizer actions |
| `notifAvailDaysBefore` | number | Days before session to send availability request (default: 7) |
| `notifLineupDaysBefore` | number | Days before session to publish lineup (default: 2) |
| `notifLineupTimeMinutes` | number | Time of day to publish lineup (minutes from midnight, default: 600 = 10am) |
| `notifAvailTimeMinutes` | number | Time of day to send availability request (default: 600) |
| `notifAvailReminderHoursBefore` | number | Hours before lineup publish to remind non-responders (default: 24) |
| `notifPaymentWeeksBefore` | number | Weeks before season start for first payment reminder (default: 4) |
| `notificationMode` | string | `auto` / `manual` |
| `emailTemplates` | map | Per-type subject/body overrides keyed by message type |

**Computed from contract fields**:
- `sessionDates` — all dates that fall on `weekday` between `seasonStart` and `seasonEnd`, minus `holidayDates`
- `spotsPerSession` = `courtsCount × 4`
- `totalCourtSlots` = `spotsPerSession × totalSessions`

**ContractPlayer** (embedded in `roster` array):

| Field | Type | Description |
|---|---|---|
| `uid` | string | Player UUID |
| `displayName` | string | Player name |
| `email` | string | Email address |
| `phone` | string | Phone number |
| `paidSlots` | number | Committed slots per session (e.g., 1 = full, 0.5 = half) |
| `shareLabel` | string | `full` / `half` / `quarter` / `custom` |
| `paymentStatus` | string | `pending` / `confirmed` |
| `playedSlots` | number | Cumulative sessions played (feeds fairness algorithm) |
| `referredByUid` | string | Who introduced this player (optional) |
| `notes` | string | Organizer-only notes |

---

### 2.4 Contract Sessions

**Firestore collection**: `contracts/{contractId}/sessions/{YYYY-MM-DD}`
One document per weekly session date. Doc ID is the ISO date string.

| Field | Type | Description |
|---|---|---|
| `id` | string | Doc ID = `YYYY-MM-DD` |
| `date` | timestamp | Session date (UTC) |
| `availability` | map | `{ [uid]: "available" | "backup" | "unavailable" }` — player responses |
| `assignment` | map | `{ [uid]: "confirmed" | "reserve" | "out" }` — lineup decision |
| `assignmentState` | string | `none` / `draft` / `published` |
| `attendance` | map | `{ [uid]: "played" | "reserve" | "out" | "charged" }` — post-session actuals |
| `requestSentAt` | timestamp | When the last availability request email was sent |

**Assignment lifecycle**:
`none` → `draft` (organizer runs Auto-Assign or edits manually) → `published` (locked, lineup email sent)

---

### 2.5 Scheduled Messages

**Firestore collection**: `scheduled_messages/{id}`
Each document represents one email blast to be sent at a specific time. The Cloud Function polls this every 60 minutes.

| Field | Type | Description |
|---|---|---|
| `id` | string | Doc ID |
| `contractId` | string | Associated contract |
| `organizerId` | string | Organizer UID |
| `type` | string | Message type (see enum below) |
| `sessionDate` | timestamp | Nil for payment reminders |
| `scheduledFor` | timestamp | When to send; null = hold indefinitely |
| `status` | string | `pending` / `pending_approval` / `sent` / `cancelled` |
| `subject` | string | Email subject (may contain early-bound tokens) |
| `body` | string | Email body template (may contain late-bound tokens) |
| `recipients` | array | `[{ uid, displayName }]` |
| `recipientsFilter` | string | `all` / `unpaid` / `no_response` |
| `autoSendEnabled` | boolean | If false, CF generates draft but never auto-sends |
| `renderedEmails` | array | Fully resolved per-player emails (set in `pending_approval`) |
| `generatedAt` | timestamp | When rendered content was last generated |

**Message Types**:
| Type | Description |
|---|---|
| `availability_request` | "Are you available for Sunday's session?" |
| `availability_reminder` | Follow-up to non-responders, fires ~24h before lineup |
| `lineup_publish` | Announces confirmed / reserve / out for the session |
| `payment_reminder` | Weekly reminder to players with `paymentStatus = 'pending'` |
| `contract_invite` | Enrollment invite when added to a contract roster |
| `match_invite` | Invite to an ad-hoc match |
| `sub_request` | "We need a sub — can you fill in?" |
| `last_ditch` | Final sub recruitment, fires 2h after initial sub request |
| `custom` | Organizer-composed one-off message |

**Status workflow**:
```
pending  →  (CF fires at scheduled_for)  →  sent
pending  →  (auto_send_enabled = false)  →  pending_approval  →  (organizer sends)  →  sent
```

---

### 2.6 Message Log

**Firestore collection**: `message_log/{id}` (auto-deleted after 90 days)

Audit trail of all messages sent. Stores recipient list, delivery count, subject/body sample, and context (which match or contract triggered it).

---

### 2.7 Feedback / Support Submissions

**Firestore collection**: `feedbacks/{id}`

Written by the in-app Feedback modal. All types land here — questions, ideas, and bug reports alike.

| Field | Type | Description |
|---|---|---|
| `userId` | string | UID of the submitting user |
| `displayName` | string | Display name at time of submission |
| `type` | string | `Help/Question` / `Feature Request` / `Bug Report` |
| `description` | string | The user's free-text input |
| `aiResponse` | string | AI-generated answer (only populated for `Help/Question`) |
| `screenContext` | string | Which tab was active when feedback was submitted |
| `createdAt` | timestamp | Server timestamp of submission |

No `status` or `resolved` field exists on these documents — lifecycle management is handled externally (see Section 6, Support Operations).

---

### 2.8 Email / SMS Queues

**`mail/{id}`** — Outbound email queue. Cloud Function `sendEmail` picks up new documents and sends via Resend API.
```json
{
  "to": "player@example.com",
  "message": { "subject": "...", "text": "...", "html": "..." },
  "reply_to": "organizer@example.com"
}
```

**`messages/{id}`** — Outbound SMS queue. Cloud Function `sendTwilioMessage` sends via Twilio.
```json
{ "to": "+15551234567", "body": "..." }
```

Both queues are fire-and-forget writes from the application. The CF updates the doc with delivery state and timestamps after sending.

---

## 3. BUSINESS LOGIC

### 3.1 Waitlist Promotion (Ad-hoc Matches)

When an ad-hoc match hits `requiredCount`, any subsequent join attempts set the player's roster status to `waitlisted` with a timestamp.

**Promotion trigger**: A confirmed player removes themselves from the match.

**Promotion algorithm**:
1. Query roster for entries with `status = 'waitlisted'`
2. Sort ascending by `waitlistTimestamp` (FIFO)
3. Promote the first entry: set `status = 'accepted'`
4. Send the promoted player a notification email immediately

**Constraints**: Max 1 player on the waitlist per match (the app returns a "full" result if the waitlist slot is already taken).

---

### 3.2 Rematch (from History)

On the History tab, the organizer can tap "Rematch" on any past match. This action:
1. Pre-fills a new match form with the same `location`
2. Pre-selects all players from the original roster who had `status = 'accepted'`
3. The organizer can add/remove players before confirming
4. On confirm, all selected players receive new invitations

No data is cloned — a brand-new `matches` document is created.

---

### 3.3 Availability-Tracking & Player Suggestion

When an organizer selects a time slot on the calendar to create a match, the app cross-references every registered player against that specific date/time:

**Sorting logic**:
1. **Available** — `weeklyAvailability` includes that day + time period AND no `blackout` covers that date
2. **Away** — A `blackout` period covers that date (overrides weekly availability)
3. **Unknown** — No weekly availability set for that day/time (not the same as unavailable)

The player suggestion panel shows these three groups with NTRP and Circle filters. Players can still be invited regardless of their availability status.

---

### 3.4 Contract Fairness Algorithm (Lineup Assignment)

Used both by the organizer's manual "Auto-Assign" and by the `lineup_publish` Cloud Function.

**Input**: A `ContractSession` document with `availability` responses + the `roster` from the parent `Contract` (specifically `paidSlots` and `playedSlots` per player).

**Algorithm**:
1. Compute each player's **play ratio** = `playedSlots / paidSlots`
2. Sort roster ascending by play ratio (lowest ratio = played least relative to what they paid for), with alphabetical tiebreaker
3. Iterate sorted list:
   - If `confirmedCount < spotsPerSession` AND player's `availability` is `available` or `backup` → assign `confirmed`
   - Else if player's `availability` is `available` or `backup` → assign `reserve`
   - Else → assign `out`
4. Write `assignment` map to the session document
5. After lineup published: increment `playedSlots` for each confirmed player

**Goal**: Over the season, every player plays approximately the number of sessions proportional to the slots they paid for.

---

### 3.5 Dropout Cascade (Contract Sessions)

**Trigger**: The session document's `assignment` map changes (Firestore `onDocumentUpdated`).

**Case A — Confirmed player drops out** (`confirmed` → `out`):
1. If the session is < 24 hours away: mark that player as `charged` in `attendance` (payment is forfeited)
2. If there are players with `assignment = 'reserve'`:
   - Promote the first reserve to `confirmed` (data write only, no email in this step)
3. If no reserves and `notificationMode = 'auto'`:
   - Send "sub needed" emails to all non-confirmed roster players with a personal deep link
   - Schedule a `last_ditch` message for 2 hours later as a final fallback

**Case B — Sub fills in** (`reserve`/`out` → `confirmed`):
1. Cancel any pending `last_ditch` scheduled messages for that session
2. If `notificationMode = 'auto'`: send updated lineup email to all confirmed players

---

### 3.6 Payment Reminder Filtering

Payment reminder `ScheduledMessage` documents carry `recipientsFilter = 'unpaid'`. At send time, the Cloud Function re-checks the contract roster and only sends to players whose `paymentStatus` is still `'pending'`. Once an organizer marks a player as `'confirmed'` (paid), that player stops receiving reminders — no manual cancellation of their scheduled message required.

---

### 3.7 No-Response Reminder Filtering

Availability reminder `ScheduledMessage` documents carry `recipientsFilter = 'no_response'`. At send time, the CF checks `ContractSession.availability` and only sends to players who have not yet submitted any response (not `available`, `backup`, or `unavailable`). Players who already responded receive nothing.

---

### 3.8 Token Substitution (Two-Phase)

Email templates use placeholder tokens. They are resolved in two phases:

**Phase 1 — Early-bound** (resolved when the `ScheduledMessage` document is created):
- `{organizerName}` → organizer's display name
- `{clubName}` → contract club name
- `{sessionDate}` → formatted session date
- `{sessionTime}` → formatted session time
- `{lineupDate}` → date lineup will be published
- `{lineupTime}` → time lineup will be published

**Phase 2 — Late-bound** (resolved per-recipient at actual send time):
- `{playerName}` → recipient's display name
- `{link}` → unique deep link for that player and that action (e.g., availability response URL)

This allows a single `ScheduledMessage` document to serve the whole roster while each email is still personalized.

---

### 3.9 Manual vs Auto Notification Mode

**Auto mode** (`notificationMode = 'auto'`):
- All `ScheduledMessage` docs have `autoSendEnabled = true`
- Cloud Function `fireScheduledMessages` sends them at the scheduled time without any organizer action
- Organizer can still use the Email Queue to preview what was sent

**Manual mode** (`notificationMode = 'manual'`):
- All docs have `autoSendEnabled = false`
- CF generates the per-player email content (renders tokens, applies filters) but stores the result as `renderedEmails` and sets `status = 'pending_approval'`
- The organizer must open the Email Queue, review the content, and tap "Send" to actually dispatch

---

### 3.10 Account Deletion

Accessible from the Players tab — a user finds their own entry (marked "(You)") and taps the red "Delete Account" button. A confirmation dialog fires, then:

1. Query all `matches` documents
2. For each match where the user is `organizerId`: delete the entire match document (and its chat subcollection)
3. For each match where the user appears in `roster`: remove just that roster entry, update the doc
4. Delete the `users/{uid}` document
5. Clear local session storage (UID, login contact, display name)
6. Redirect to login screen

This is a hard delete — no soft delete, no recovery. The user is fully scrubbed from all current match rosters and all matches they organized are gone.

---

### 3.11 Stale Account Cleanup

A Cloud Function runs every 24 hours and deletes `provisional` accounts that:
- Were created more than 30 days ago
- Have never logged in (`lastLoginAt` is null)

This prevents the player directory from accumulating ghost accounts from old "Add Custom Player" entries that were never claimed.

---

## 4. UI/UX MAP

The app is organized around a **4-tab bottom navigation**. The fourth tab (Contracts) is only visible to users who have an active organizer role.

---

### Tab 1 — Upcoming (Calendar)

The primary view of the app. Shows all matches on a shared community calendar.

**Calendar modes**: Agenda · Day · Week · Month (toggled by buttons at the top)

**Color coding** (match event colors):
| Color | Meaning |
|---|---|
| Dark blue | You're organizing; match is full |
| Light blue | You're organizing; still needs players |
| Green | You accepted; confirmed to play |
| Amber/yellow | You're invited; spots still open |
| Red | You're invited; match is full |
| Grey | Public match; you're not involved |
| 💬 prefix | Unread messages in match chat |

**Player Availability Sidebar** (opens when tapping an empty time slot):
- Shows all players grouped into Available / Away / Unknown for that exact time
- Filters: NTRP minimum, Circle assignment
- Multi-select checkboxes → "Create Match Here" button pre-fills the invite list
- This sidebar is the primary match-creation entry point

**Advanced Filters** (funnel icon):
- Filter calendar to a specific player's matches
- Minimum open spots remaining
- Minimum NTRP level
- Number of Circle-N players confirmed

**Match Detail** (tapping a match event):
- Roster list with each player's status
- Join / Accept Invite / Decline / Remove Me actions
- Open Match Chat

**Match Chat**:
- Group chat subcollection on the match document
- Real-time updates; visible to confirmed players + organizer
- Does NOT send email notifications

**Organizer Dashboard** (accessible from a match the user organized):
- Full roster management (remove players with optional reason, view invite status)
- Recruit additional players from directory with NTRP/circle/distance filters
- Send Urgent Recruit or Cancel Match (all players notified by email)

---

### Tab 2 — Players (Directory)

Community player directory.

**Player Card** shows: name, NTRP level, gender, contact info, Circle chips

**Filters**:
- Text search (name)
- Minimum NTRP level
- Maximum distance from home zip (requires zip on both profiles)
- Circle assignment (1, 2, or 3)

**Circle Assignment**: Tap a Circle chip (1 / 2 / 3) on any player card to assign/unassign your private grouping. Assignments are visible only to you.

**Add Custom Player**: Creates a `provisional` user with just a name + email. That user can claim the account by logging in with the same email. Until then, they can receive match invites.

**Your own entry** is marked "(You)" with an Edit Profile button.

---

### Tab 3 — History

Read-only list of past matches (where `matchDate` has passed).

- Shows location, date, confirmed player count
- **Rematch button**: Pre-fills a new match with the same court and accepted player list

---

### Tab 4 — Contracts (Organizer Only)

The seasonal court booking management hub.

**Contract List**: All contracts the user has organized. "New Contract" button.

**Single Contract View**:
- Header: club name, court numbers, weekday, time, season dates
- Status toggle: Draft / Active
- PIN entry (if `organizerPin` is set)
- Roster table: player name, paid slots, payment status, played slots, actions
- Session grid: all dates × all players; each cell shows that player's availability response
- "Session Emails" → navigates to Email Queue screen
- "Transfer Ownership" → search and reassign the organizer role to another roster member

**Contract Setup Screen** (New / Edit contract):
Sections: Court Details → Season Dates → Pricing → Notification Timing → Notification Mode → PIN → Email Templates → Roster

**Session Detail** (tap a date in the session grid):
- Availability responses per player
- Auto-Assign button (runs fairness algorithm)
- Manual override per player (tap to cycle: Confirmed → Reserve → Out)
- Publish Lineup button (locks assignment, triggers lineup email)

**Email Queue Screen** (`Session Emails`):
Grouped by session date. For each session, three message rows:

| Row | When it fires | Recipients |
|---|---|---|
| Availability Request | ~7 days before session | All roster players |
| Availability Reminder | ~24h before lineup publish | Non-responders only |
| Lineup | ~2 days before session at 10am | All roster players |

Each row shows current state and available actions:
- **pending** → "Generate Preview" button
- **pending_approval** → "Review" · "Send" · "Regenerate" · "Delete Draft" buttons
- **sent** → timestamp of when it was sent

"Review" opens a dialog with the rendered subject/body for each recipient. The organizer can edit the body (changes saved to Firestore in real time) or remove individual recipients before sending.

---

### Profile & Settings (Overlay / Modal)

Accessible via gear icon from the main screen.

- Display Name (required)
- Email and Phone
- NTRP Level (0.0 = Not Rated, then 2.5–5.0 in 0.5 steps)
- Gender
- Zip Code (enables distance features)
- Weekly Availability grid (days × morning/afternoon/evening checkboxes)
- Away Blocks (date range + optional reason; add/remove)
- Notification preferences (on/off, SMS/Email/Both)

---

## 5. INFRASTRUCTURE

### 5.1 Authentication Flow

**Current approach**: Passwordless **Firebase Email Link** sign-in.
1. User enters email address
2. App sends a sign-in link to that email
3. User clicks the link → app completes authentication
4. UID from Firebase Auth is used to look up or create the Firestore user document
5. Deep links are handled by the app so the user lands back in the right context (e.g., a match they were invited to)

**Provisional accounts**: Created when an organizer adds a "Custom Player" by name + email before that person has ever logged in. When the person logs in with that email for the first time, their Firebase Auth UID is merged with the provisional document.

**No password, no OAuth** — the only credential is the email link.

---

### 5.2 Notification Triggers (Email via Resend)

All emails are sent by writing a document to the `mail` Firestore collection. A Cloud Function picks it up and calls the Resend API.

**Routing logic** (per-user preferences):
1. Look up user by UID
2. Check `notifActive` — if false, drop (unless `ignoreNotifActive` override)
3. Check `notifMode` — route to email, SMS, or both
4. Fall back to available channel if preferred channel has no contact info

**Email formats**: Every email has both a `text` (plain) and `html` version. HTML uses styled buttons for links rather than raw URLs.

**Reply-To**: Contract emails set `reply_to` to the organizer's email so players can reply directly to the organizer, not to a no-reply address.

**Notification events and their triggers**:

| Event | Who Gets It | Trigger |
|---|---|---|
| Match invitation | Invited player | Organizer adds player to match |
| Match acceptance (organizer) | Organizer | Player accepts invite |
| Player dropped out (organizer) | Organizer | Player removes themselves |
| Waitlist promotion | Promoted player | A confirmed player removes themselves |
| Urgent recruit | All non-accepted players in match | Organizer sends from dashboard |
| Match cancellation | All roster players | Organizer cancels |
| Contract invite | New roster player | Organizer adds player to contract |
| Availability request | All contract roster | Scheduled (7 days before session) |
| Availability reminder | Non-responders only | Scheduled (24h before lineup) |
| Lineup published | All contract roster | Scheduled (2 days before session) |
| Sub needed | Non-confirmed roster | Player drops out of a contract session |
| Last-ditch sub request | Non-confirmed roster | 2h after sub-needed if spot still open |
| Payment reminder | Unpaid players only | Scheduled (weekly, starting ~4 weeks before season) |
| Organizer PIN | Organizer | PIN set for first time on contract |

---

### 5.3 Cloud Functions

All backend logic runs in Firebase Cloud Functions (Node.js). Two generations:
- v1 (`cloudfunctions.net`): `askGemini` (AI feedback assistant via Gemini 2.5 Flash)
- v2 (`cloud run` URLs): all other functions below

| Function | Trigger | Purpose |
|---|---|---|
| `sendEmail` | `mail/{id}` created | Send via Resend API; update doc with delivery state |
| `sendTwilioMessage` | `messages/{id}` created | Send SMS via Twilio |
| `fireScheduledMessages` | Cron (every 60 min) | Fire `pending` messages at or past `scheduledFor`; run content generation; update status |
| `generateSessionMessages` | HTTP POST | On-demand render of per-player email content; sets docs to `pending_approval` |
| `sendApprovedMessages` | HTTP POST | Send all `pending_approval` docs for a session/type; marks sent |
| `onSessionAssignmentChange` | `sessions/{dateKey}` updated | Dropout cascade: promote reserve, send sub-needed, cancel last_ditch |
| `askGemini` | HTTP POST | AI help assistant (Gemini 2.5 Flash) |
| `disableBillingOnBudgetExceeded` | Pub/Sub | Kill billing if GCP budget alert fires |
| `deleteStaleProvisionalPlayers` | Cron (every 24h) | Delete `provisional` accounts older than 30 days with no login |

---

### 5.4 Deep Links

All player-facing action links follow the pattern `https://www.adhoc-local.com/#/<route>?uid=<playerUid>`. The `uid` query parameter auto-authenticates the player so they never need to enter credentials to respond to an email.

| Action | URL pattern |
|---|---|
| View / join a match | `/#/match/{matchId}?uid={uid}` |
| Enroll in a contract | `/#/contract/{contractId}?uid={uid}` |
| Respond to availability | `/#/availability/{contractId}/{YYYY-MM-DD}?uid={uid}` |
| View / manage session | `/#/session/{contractId}/{YYYY-MM-DD}/manage?uid={uid}` |
| Fill in as sub | `/#/session/{contractId}/{YYYY-MM-DD}/subin?uid={uid}` |

---

### 5.5 Firestore Collections Summary

| Collection | Purpose | TTL |
|---|---|---|
| `users/{uid}` | Player profiles | None |
| `matches/{id}` | Ad-hoc match records with embedded roster | None |
| `matches/{id}/chats/{msgId}` | Per-match group chat | None |
| `contracts/{id}` | Seasonal court contracts with embedded roster | None |
| `contracts/{id}/sessions/{YYYY-MM-DD}` | Per-session availability, assignment, attendance | None |
| `scheduled_messages/{id}` | Auto-scheduled email queue | None |
| `message_log/{id}` | Audit trail of sent messages | 90 days |
| `feedbacks/{id}` | User-submitted ideas, bug reports, and questions | None |
| `mail/{id}` | Outbound email queue (Resend) | Deleted post-send |
| `messages/{id}` | Outbound SMS queue (Twilio) | Deleted post-send |

---

### 5.6 Deployment

- **Web app**: Deployed to Firebase Hosting (`www.adhoc-local.com`) via GitHub Actions on merge to `main`.
- **Preview environments**: PRs automatically get a Firebase Hosting preview URL.
- **Cloud Functions**: Deployed via Firebase CLI (`firebase deploy --only functions`). v2 functions deploy to Cloud Run; GCP enforces a rate limit — wait ~60s between rapid re-deploys.
- **Firebase project ID**: `tennis-app-mp-2026`

---

## 6. USER LIFECYCLE

### 6.1 First Login (New User)

1. User enters their email address on the login screen
2. Firebase sends a passwordless sign-in link to that email
3. User clicks the link — the app intercepts it and calls `signInWithEmailLink()`
4. Firebase Auth creates (or returns) a UID for that email
5. App looks up whether a Firestore `users` document already exists for that email:
   - **Lookup order**: check `primary_contact` field → check `email` field → check legacy doc ID
6. **If no document found**: create a new `users/{uid}` document with `accountStatus = 'provisional'`, `displayName = ''`, and the email stored in both `email` and `primary_contact`. The `auth_uids` array is seeded with the Firebase Auth UID.
7. **If a document found** (e.g., a Custom Player entry created by an organizer): merge by appending the new Auth UID to the existing document's `auth_uids` array. The provisional account is now claimed.

After login, if `displayName` is empty, the app prompts the user to set up their profile before proceeding.

---

### 6.2 Quick Setup (Provisional — Limited Features)

Available only to users with `accountStatus = 'provisional'`. A toggle labelled "Quick Setup (Limited Features)" is shown on the profile screen with the subtitle "Only provide name to accept invites. You won't be able to organize matches."

**Fields collected**: Display Name only (required)

**What is saved**:
- `displayName` set
- `accountStatus` remains `provisional`
- All other fields stay at defaults (NTRP 0.0, notifications off, no zip, etc.)

**Feature restrictions while provisional**:
- Can receive and accept match invitations
- Can respond to contract availability requests
- Cannot create matches or contracts (UI buttons hidden)
- Distance filtering and player suggestion features unavailable (no zip)

This path is designed for players who received an email invite and just want to accept it quickly without filling out a full profile.

---

### 6.3 Complete Profile (Fully Registered)

Triggered by:
- Tapping the orange "Complete Profile" button in the AppBar (shown for provisional accounts)
- Toggling off Quick Setup on the profile screen
- Tapping the gear icon (full profile editor)

**Fields collected**:
| Field | Validation |
|---|---|
| Display Name | Required |
| Zip Code | Must be a valid 5-digit US zip; validated via location service |
| Email | Free text |
| Phone Number | Free text |
| Gender | Dropdown: Male / Female / Non-Binary / Other |
| NTRP Level | Dropdown: Not Rated (0.0), 2.5–5.0 in 0.5 steps |
| New Match Notifications | Toggle (on = `notifActive: true`) |
| Weekly Availability | Day × time-period grid (morning / afternoon / evening) |
| Away Blocks | Date ranges with optional reason label |

**What is saved on completion**:
- `accountStatus` set to `fully_registered`
- `activatedAt` set to server timestamp
- All profile fields written
- All features unlocked

---

### 6.4 Custom Player (Organizer-Created Provisional Account)

An organizer can add a person to their player directory before that person has ever used the app:

1. Organizer taps "Add Custom Player" in the Players tab
2. Enters the person's name + email
3. A new `users` document is created with:
   - `displayName` = entered name
   - `email` and `primary_contact` = entered email
   - `accountStatus = 'provisional'`
   - `createdByUid` = organizer's UID
4. The new player can immediately be added to match rosters and receive email invitations
5. When the new player clicks any invite link and logs in with that email, the merge flow in §6.1 fires: their Auth UID is added to `auth_uids` on the existing document — they inherit the Custom Player entry rather than getting a new account

---

### 6.5 Profile Editing (Ongoing)

Both provisional and fully-registered users can edit their profile at any time via the gear icon. The same form used for Complete Profile is shown, pre-populated with current values. Saving calls a merge-update (only changed fields are written). If a previously provisional user fills out all fields and saves, `accountStatus` transitions to `fully_registered`.

A lighter-weight "Complete Profile" modal (fewer fields — email, phone, zip, gender, NTRP only) also appears contextually after a player responds to an availability request or match invite, as a gentle nudge.

---

### 6.6 Stale Provisional Account Cleanup

A Cloud Function runs every 24 hours. It deletes `provisional` accounts where `createdAt` is more than 30 days ago and `lastLoginAt` is null (the person never logged in). This prevents the directory from accumulating unclaimed Custom Player entries.

---

## 7. SUPPORT STACK

### 7.1 Lightbulb FAB (Entry Point)

A draggable yellow circular button with a lightbulb icon sits in the bottom-right corner of the main screen at all times. It is:
- **Draggable** — the user can reposition it anywhere on screen; position is stored in local UI state (not persisted across sessions)
- **Always visible** — shown regardless of which tab is active
- **Tap to open** — tapping it opens the Feedback & Support modal

---

### 7.2 Feedback & Support Modal

A bottom-sheet modal with the title "Feedback & Support". The user selects a type via a segmented button:

| Segment label | Internal type value | Placeholder text |
|---|---|---|
| Question | `Help/Question` | "How can I help you?" |
| Idea | `Feature Request` | "Describe your feature idea..." |
| Bug | `Bug Report` | "Describe what went wrong..." |

**For "Question" type** — an AI assist flow runs before storing:
1. The user's description is POSTed to the `askGemini` Cloud Function along with the full help guide as a system prompt
2. The AI response appears inline in the modal in a blue container
3. The submission is still stored in Firestore (with the AI response captured in `aiResponse`)
4. The modal stays open after answering so the user can refine or submit

**For "Idea" and "Bug Report" types**:
1. User taps Submit
2. Document written to `feedbacks` collection immediately
3. Modal closes; snackbar: "Feedback Logged! Thank you."
4. No AI call is made

**Context tagging**: The `screenContext` field is set automatically based on which tab was active when the lightbulb was tapped (e.g., "Create Match", "Players", "History", "Contract"). This tells the developer where in the app the feedback originated.

---

### 7.3 AI Help Assistant (askGemini)

**Cloud Function**: `askGemini` (Firebase v1, `cloudfunctions.net` URL)

**Trigger**: HTTP POST

**Request body**:
```json
{
  "description": "user's question text",
  "systemPrompt": "full help guide text"
}
```

**Response**:
```json
{ "response": "AI-generated answer" }
```

**Model**: Gemini 2.5 Flash

**API key**: Stored in Google Cloud Secret Manager as `GEMINI_API_KEY` — never exposed to the client.

**System prompt source**: `AiPrompts.feedbackAssistantGuide` — a comprehensive in-code help guide covering every feature: login, profile setup, calendar, match creation, players directory, circles, history, rematch, contracts, sessions, availability, lineups, email queue, notifications, and common FAQs. The guide is the AI's entire knowledge base; it is instructed to say "I'm not sure — please submit it as an Idea or Bug" for anything not covered.

**CORS**: Configured for `adhoc-local.com`, `www.adhoc-local.com`, `localhost:5000`, `localhost:8080`.

---

### 7.4 Feedback Triage (Admin Workflow)

There is no in-app admin panel for feedback. Triage is done via Node.js scripts run locally by the developer with Firebase Admin SDK credentials:

**`functions/get_all_feedback.js`**
- Reads all documents from `feedbacks` ordered by `createdAt` ascending
- Prints: type, date, text/description, Firestore document ID
- Used to review all submissions in chronological order

**`functions/read_feedback_temp.js`**
- Reads the 2 most recent documents from `feedbacks` ordered by `createdAt` descending
- Used for a quick look at latest submissions

**"Mark as Fixed" / Tracking Resolved Items**:
The `feedbacks` collection has no `status`, `resolved`, or `fixed` field. The current workflow for tracking what has been addressed uses the Firestore document ID as a cursor: the developer shares the script output with an AI assistant (Claude), the AI cross-references the doc IDs to determine which items are new since the last review, and fixes are implemented. Items "marked as fixed" are tracked externally (in conversation context or a note), not written back to Firestore.

> **For the rebuild**: add a `status` field to the `feedbacks` schema (`open` / `in_progress` / `resolved` / `wont_fix`) and build a simple internal admin page that lists submissions filterable by status, with a one-click status toggle. This removes the dependency on scripts and makes the feedback loop visible.

---

## 8. ADDITIONAL SCREENS (Complete Inventory)

These screens were not detailed in Section 4 but exist in the current codebase:

### Contract Sub-In Screen
Route: `/#/session/{contractId}/{YYYY-MM-DD}/subin?uid={uid}`
- Player lands here from a "sub needed" email
- Shows session details (date, time, club, who is currently confirmed)
- Single "I'll Sub In" button
- On tap: sets player's `assignment` to `confirmed` in the session doc
- Triggers the dropout cascade Cloud Function (Case B), which cancels any pending `last_ditch` messages and notifies confirmed players of the updated lineup

### Contract Session Player View
- A player-facing (non-organizer) view of a single session
- Shows their own assignment status (Confirmed / Reserve / Out)
- Shows the confirmed lineup (who they'll be playing with)
- No editing capability

### General Email Queue Screen
- A non-contract email queue view
- Lists scheduled messages that are not tied to a specific contract session
- Supports the same Generate Preview → Review → Send workflow as the contract Email Queue

### Scheduled Messages List Screen
- Organizer view of all `scheduled_messages` for a contract
- Shows raw list (not grouped by session date like the Email Queue)
- Useful for bulk status checking

### Sent Messages Screen
- View of `message_log` entries for the logged-in organizer
- Shows what was sent, to whom, and when
- Filterable by context (match or contract)

### Availability Setup Screen
- A focused screen for setting weekly availability
- Shown contextually (e.g., after accepting a match invite) as a nudge to fill in the availability grid
- Same grid widget as the full profile editor, but presented standalone

### Chat List Screen
- A list of all matches that have unread chat messages
- Each entry shows match name, date, and unread count
- Tapping opens Match Chat for that match

### Organizer Dashboard Screen
- Full match management for the organizing player
- Roster table with each player's invite status
- Actions: Remove player (with reason), Recruit more players, Send Urgent Recruit, Cancel Match
- "Recruit" opens a filtered player picker (NTRP, circle, distance from match court)

### Select Players Screen
- Reusable player picker used by match creation and organizer dashboard
- Supports all filters: name search, NTRP, circle, distance from a reference location
- Checkbox multi-select

### Compose Message Screen
- Generic message composer for organizers
- Select message type from dropdown
- Editable subject + body fields (pre-populated from `MessageTemplates.defaultSubject/defaultBody`)
- Recipient selection
- Send confirmation → writes to `mail` collection via `sendComposed()`

---

## 9. TEAMS FEATURE (Phase 2 — Post-Rebuild)

> **Build order**: The scraper (§9.1) can be built now as a standalone Cloud Run job independent of the Flutter→Next.js migration. The schema extensions (§9.2) should be included in the initial Next.js data model. The algorithm (§9.3) and UI (§9.4) are built after the base app is validated.

---

### 9.1 The Scraper (Standalone Cloud Run Job)

**Source**: `https://northshore.tenniscores.com/` — publicly accessible league site with Scores and Standings pages.

**Runtime**: Python (BeautifulSoup + requests) or Node.js (cheerio). Deployed as a Cloud Run job triggered by Cloud Scheduler (e.g., weekly on Monday morning after weekend matches are posted).

**Output**: Writes to the `league_stats/{uid}` Firestore collection (see §9.2). Matching a scraped name to a `users` UID is done by fuzzy-matching `source_name` against `users.displayName`.

**Scraped fields per match record**:
| Field | Description |
|---|---|
| `match_date` | Date of the match |
| `games_won` | Games won by this player in that match |
| `games_lost` | Games lost |
| `score_string` | Raw score (e.g., `"6-3, 7-5"`) — preserves margin of victory |
| `opponent_name` | Name of opponent (for context) |
| `partner_name` | Name of doubles partner |
| `line_number` | Which line (1, 2, 3, 4) — higher lines = weaker competition |
| `opponent_team_rank` | Standings rank of the opposing team at time of match |

**Power Rating (PR) calculation**:

The PR is a rolling metric computed from the last 5 matches. It goes beyond raw win/loss to capture *how convincingly* a player wins or loses:

```
Match Score = (games_won / (games_won + games_lost))

Margin Bonus = clamp((games_won - games_lost) / 12, -0.1, +0.1)
  → +10% max bonus for a 6-0, 6-0 type win
  → -10% max penalty for a 0-6, 0-6 type loss

Opponent Quality Multiplier = 1 + ((total_teams - opponent_rank) / total_teams) * 0.2
  → Beating the #1 team is worth 20% more than beating the last-place team

Line Weight = 1 + ((max_lines - line_number) / max_lines) * 0.15
  → Winning at Line 1 is weighted 15% higher than Line 4

Weighted Match Score = (Match Score + Margin Bonus) * Opponent Quality Multiplier * Line Weight

PR = simple moving average of Weighted Match Score over last 5 matches
   = sum(Weighted Match Scores) / min(matches_played, 5)
```

PR range is approximately 0.0–1.3. A player who consistently wins Line 1 6-0 against top teams will approach 1.2+. A player losing at Line 4 against weak opponents will be near 0.4.

---

### 9.2 Schema Extensions for Teams

These fields should be included in the **initial Next.js data model** even if Teams UI is not yet built. Adding them later requires a migration.

**`ContractPlayer`** (additional fields):
| Field | Type | Description |
|---|---|---|
| `hand_preference` | string | `forehand` / `backhand` / `neutral` |
| `blacklisted_partners` | array of uid | Players this person refuses to be paired with. Private — visible only to the captain/organizer. Never shown to other players. |
| `power_rating` | number \| null | Populated by scraper. Null if player has no league data. |
| `last_rating_date` | timestamp \| null | When PR was last computed |
| `source_name` | string \| null | Name as it appears on tenniscores.com (for scraper matching) |

**`Contract`** (additional field):
| Field | Type | Description |
|---|---|---|
| `lineup_mode` | string | `percent_played` (default) / `competitive` |

**`ContractSession.assignment` map** — extend value from a plain string to an object:
```
// Before
assignment: { [uid]: "confirmed" | "reserve" | "out" }

// After
assignment: {
  [uid]: {
    status: "confirmed" | "reserve" | "out",
    line:   1 | 2 | 3 | 4 | null
  }
}
```

**New Firestore collection: `league_stats/{uid}`**
| Field | Type | Description |
|---|---|---|
| `uid` | string | Matches `users` collection doc ID |
| `source_name` | string | Name as scraped (for audit/debugging) |
| `last_scraped` | timestamp | When this doc was last updated by the scraper |
| `power_rating` | number | Current computed PR |
| `matches` | array | Last N match records (see §9.1 for fields) |
| `total_matches_scraped` | number | Total matches found in source data |

---

### 9.3 The Competitive Lineup Algorithm

Activated when `contract.lineup_mode = 'competitive'`. Replaces the percent-played fairness sort with a pairing-strength maximization.

**Step 1 — Availability filter**
Include only players whose `availability` response for the session is `available` or `backup`. Players who responded `unavailable` or did not respond are excluded from pairing consideration.

**Step 2 — Generate all valid pairs**
From the available player pool, enumerate every possible 2-player combination. For each pair, check the hard constraint:

```
Hard Constraint (Blacklist):
  If uid_A appears in uid_B.blacklisted_partners
  OR uid_B appears in uid_A.blacklisted_partners
  → Discard pair. It will never be assigned, regardless of PR.
```

**Step 3 — Score each valid pair**
```
Base Score = (Player1.PR + Player2.PR) / 2
  (If either player has PR = null, use league average as a fallback)

Hand Bonus:
  If one player is "forehand" and the other is "backhand" → Base Score × 1.10
  If both players prefer the same side                   → Base Score × 0.80
  If either player is "neutral"                          → no adjustment

Pairing Strength = Base Score × Hand Multiplier
```

**Step 4 — Greedy line assignment**
```
Sort all valid pairs descending by Pairing Strength.

For each pair (highest score first):
  If neither player has been assigned yet:
    Assign this pair to the next available line (Line 1, then 2, then 3, then 4)
    Mark both players as assigned

Continue until all lines are filled or no valid unassigned pairs remain.
```

Result: the strongest available pair gets Line 1, second-strongest gets Line 2, etc.

**Step 5 — Handle unfilled lines (dropout scenario)**
If a line cannot be filled from the confirmed pool (e.g., a player dropped out):
- Re-run the algorithm including `backup` players
- If still unfilled: trigger the sub-needed email flow (same as percent-played mode — a personal deep link goes to non-confirmed roster players)
- The sub-needed link routes to a screen that shows the open line number and what PR is expected, so the sub can self-select

---

### 9.4 Teams UI (in Next.js build)

**Contract Setup Screen addition**:
- New toggle in the Notification Mode section: **Lineup Mode** — `Fairness (% Played)` / `Competitive (Team)`
- When Competitive is selected: show additional per-player fields on the roster table:
  - Hand Preference (dropdown: Forehand / Backhand / Neutral)
  - "Do Not Pair With" multi-select (shows other roster members; stored as `blacklisted_partners`; labelled "Private — not shown to players")
  - Power Rating (read-only, pulled from `league_stats`; shows "No data" if null)

**Session / Lineup View addition** (when `lineup_mode = 'competitive'`):
- Each confirmed pair is grouped visually (e.g., "Line 1: Player A & Player B")
- Shows PR for each player next to their name
- Shows Hand Preference icon (→ for forehand, ← for backhand, ↔ for neutral)
- Shows Pairing Strength score for the pair
- Reserve players shown with their PR so the organizer can make informed manual overrides

**Player Directory addition**:
- PR badge on player cards (shown only to organizers)
- Hand Preference label on player cards

**Everything else stays the same in Competitive mode**:
- Auto vs Manual notification mode works identically
- Availability request / reminder / lineup email flow is unchanged
- Deep links for availability response are unchanged
- Email Queue (Generate Preview → Review → Send) works identically

---

### 9.5 Scraper Deployment (Stack-Agnostic, Build Now)

The scraper is entirely independent of the Flutter→Next.js migration. It can be built and deployed immediately.

**Recommended deployment**:
```
Cloud Scheduler (weekly cron)
  → triggers Cloud Run job (Python container)
     → scrapes northshore.tenniscores.com (Scores + Standings pages)
     → computes PR for each found player
     → writes/updates league_stats/{uid} in Firestore
     → logs run summary to a scraper_runs/{id} collection
```

**Matching scraped names to UIDs**:
1. Query all `users` documents
2. For each scraped player name: fuzzy-match against `users.displayName` (e.g., Levenshtein distance ≤ 2, or first+last name token match)
3. If confident match found: write to `league_stats/{uid}` and update `ContractPlayer.power_rating` on any active contracts that player is part of
4. If ambiguous: write to a `scraper_unmatched/{id}` staging collection for manual review; do not auto-assign

**Error handling**:
- If the source site changes structure: scraper fails gracefully, logs error to `scraper_runs`, does not overwrite existing PR data
- All existing PR values are preserved until a successful scrape overwrites them
- Cloud Scheduler retries on failure (configurable: 3 attempts, 10-minute backoff)

---

## 10. PRODUCT NORTH STAR (for rebuild reference)

When rebuilding this product in Next.js + Firebase, the following principles should guide every decision:

1. **Email is the notification layer** — no push notifications, no in-app notification center. Every important event generates an email. Design the UI so the emails are the call-to-action, and the web app is where the action is completed.

2. **Zero-friction for players** — a non-organizer player should be able to accept a match invite, respond to availability, or view a lineup by clicking one link in an email. No account creation flow, no password, no app download.

3. **Organizer is the power user** — organizers run recurring weekly groups for months. They care deeply about fairness (who plays when), payment tracking, and not spending hours on logistics. Automate everything that can be automated and surface approvals only when needed.

4. **Circles are private** — the player rating/grouping system is intentionally invisible to the grouped player. Never expose a user's circle assignment to anyone except the assigning user.

5. **Fairness is measurable** — the lineup algorithm is not random. It tracks `playedSlots` vs `paidSlots` per player over the season and uses that ratio to prioritize who plays next. This ratio should be visible to the organizer so they can trust the system.

6. **Sessions are idempotent** — re-generating an email preview or re-publishing a lineup should never send duplicate emails. The `status` field on `ScheduledMessage` is the single source of truth.

7. **Feedback is a first-class feature** — the support channel (lightbulb → AI answer or logged submission) is always accessible. In the rebuild, add a `status` field to the `feedbacks` schema and build a simple internal admin view so the developer can triage, track, and close issues without relying on scripts or external tools.
