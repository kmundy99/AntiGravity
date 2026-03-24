# APP_BLUEPRINT.md

## 1. CORE IDENTITY
**Adhoc Local** is a tennis coordination tool designed specifically for local recreational communities. It streamlines the organization of casual tennis matches and seasonal contract court formats by combining intelligent availability tracking, a shared player directory, and automated roster management.

## 2. DATA MODELS
The primary data points revolve around Users, Matches, and recurring Contracts.

### Users (Players)
- **Profile Info**: Document ID (UID), Display Name, Primary Contact, Phone/Email.
- **Tennis Data**: NTRP Level, Gender, Default distance filter, Location/Zip tracking.
- **Availability**: `weeklyAvailability` grid (Morn/Aft/Eve per day), `blackouts` (away periods).
- **Settings**: Notifications (active vs paused), Account Status (provisional or fully registered).
- **Circles**: Private groupings (`circleRatings`) that users apply to other players (e.g., Circle 1, 2, 3) to silently organize their contacts by skill tier, friend group, or geography.

### Matches (Adhoc Play)
- **Details**: Location, Match Date/Time, Status (Draft, Filling, Completed).
- **Requirements**: Required Player Count (2, 3, 4, or 6), Min/Max NTRP.
- **Roster**: A list of `Roster` objects, containing the player's UID, waitlist timestamp, and status (Invited, Accepted, Declined, Waitlisted).

### Contracts & Sessions (Seasonal Booking)
- **Contract**: Organizer ID, Club info, Court counts, Pricing details, Season dates, Auto-notification schedules.
- **Contract Player**: Roster for the season, detailing paid slots vs played slots and payment status.
- **Contract Session**: Represents a single weekly event. Contains maps for `availability` (available, backup, unavailable), `assignment` (confirmed, reserve, out), and actual `attendance`.

### Scheduled Messages / Logging
- **ScheduledMessage**: Queue records for triggering automated emails (Availability Requests, Lineups, Reminders).
- **MessageLogEntry**: Historical records of sent emails.

## 3. BUSINESS LOGIC

### Waitlist Promotion
When an open match hits its required player count, additional users trying to join are marked as `waitlisted` and timestamped. If a confirmed player leaves the match (removing themselves), the app queries the waitlist, sorts by the oldest timestamp, and auto-promotes the first user in line to `accepted`. The promoted user immediately receives an email notification.

### Rematch Functionality
From the History tab, an organizer can hit "Rematch" on a past event. This clones the location and previously accepted roster into a new draft match, saving time so coordinators don't have to rebuild the same group.

### Availability-Tracking & Matchmaking
Players maintain a weekly availability grid and explicit "Away Dates" (Blackouts). When an organizer selects a time slot to create a match, the app cross-references the roster against that exact timestamp, sorting the directory into three distinct buckets: **Available**, **Away**, and **Unknown**. 

For **Contracts**, this goes deeper: a fairness algorithm auto-assigns the weekly lineup by prioritizing players with the lowest "played vs paid slots" ratio who have responded "Available".

## 4. UI/UX MAP
The frontend is primarily driven by a 4-tab bottom navigation structure:

1. **UPCOMING (Calendar Tab)**
   - The central schedule view (Agenda, Day, Week, Month).
   - Tap empty spots to host; tap populated spots to see details or join.
   - Shows colored status indicators (Dark Blue = Hosting & Full, Yellow = Invited & Spots Open, etc.) and unread match chat blobs.
   - Waitlist UI and Advanced Match Filters.

2. **PLAYERS (Directory Tab)**
   - Master list of community users.
   - Filter by Distance (zip code derived), NTRP, or private Circles.
   - "Add Custom Player" mechanism to invite newcomers via email, creating a provisional account.

3. **HISTORY (Past Matches Tab)**
   - Read-only list of completed events.
   - Key interaction: "Rematch" button to quickly reconstitute a group.

4. **CONTRACTS (Seasonal Booking Tab)**
   - Organizer dashboard for running weekly paid courts.
   - Setup wizard for scheduling, pricing, and notification timing.
   - Weekly Session Grid: Visual matrix of player availability responses vs assignments.
   - Email Queue interface: To manually review and send or to monitor automated blasts.

## 5. INFRASTRUCTURE & FLOWS

### Authentication Flow (Firebase Auth)
Migrating to a seamless Firebase Authentication pipeline utilizing **passwordless email link sign-in**. 
- Users enter their email/phone to receive a secure link or OTP.
- New users land as provisional accounts, while returning users merge securely with their Firebase UID. 
- Deep-links are routed to complete the authentication loop and Firestore Security Rules enforce document access via authenticated UIDs.

### Notification Triggers (Resend / Email)
The application relies heavily on curated Email notifications over standard push notifications to ensure delivery across platforms.
- **Provider**: Resend API handled via Firebase Cloud Functions or backend worker.
- **Triggers**: Match invitations, waitlist promotions, organizer cancellations, player drop-outs.
- **Contract Automation**: Timed blasts for weekly Availability Requests (with personal deep-links for instant response), Follow-up Reminders, Published Lineups, and Payment Collection reminders.
