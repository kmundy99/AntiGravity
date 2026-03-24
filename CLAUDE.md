# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run the app locally (web)
flutter run -d chrome

# Run on a specific device
flutter run -d <device-id>   # use `flutter devices` to list

# Build for production web
flutter build web --release

# Run all tests
flutter test

# Run a single test file
flutter test test/calendar_widget_test.dart

# Analyze code (lint)
flutter analyze

# Update dependencies
flutter pub get
flutter pub upgrade

# Deploy Cloud Functions
cd functions && firebase deploy --only functions

# Deploy to Firebase Hosting manually
firebase deploy --only hosting
```

## Architecture

### Overview
Multi-platform Flutter app (web, Android, iOS, desktop) for organizing local tennis matches. Firebase is the sole backend — Firestore for data, Cloud Functions (Node.js) for SMS/email notifications. There is no traditional auth; users are identified by phone number.

### Key Data Flow
1. Users are stored in Firestore `users` collection, keyed by phone number (normalized).
2. Matches are stored in `matches` collection with an embedded `roster` array of `Roster` objects.
3. To send SMS, the app writes a document to the `messages` collection; a Cloud Function picks it up via Twilio. Email works the same way via the `mail` collection and Resend.
4. In-match chat is stored as subcollection documents under each match.
5. The frontend subscribes to Firestore streams for real-time updates (no polling).

### Firestore Collections
| Collection | Purpose |
|---|---|
| `users` | Player profiles (doc ID = phone number) |
| `matches` | Match records with embedded `roster` array |
| `messages` | Queue for outbound SMS (Twilio trigger) |
| `mail` | Queue for outbound email (Resend trigger) |
| `<matchId>/chats` | Per-match chat subcollection |

### Core Models (`lib/models.dart`)
- **`User`** — Profile with `uid`, `displayName`, `primaryContact`, `ntrpLevel`, `gender`, `address`, `email`, `phoneNumber`, `notifActive`, `notifMode`, `accountStatus` (`provisional` | `fully_registered`), `circleRatings`.
- **`Match`** — `organizerId`, `location`, `matchDate`, `status` (`Draft` | `Filling` | `Completed`), `roster`, `requiredCount`, `minNtrp`, `maxNtrp`, `currentTier`.
- **`Roster`** — Embedded in Match; `uid`, `displayName`, `status` (`invited` | `accepted` | `declined` | `waitlisted`), optional `ntrpLevel`, `waitlistTimestamp`.

### App Structure
- **`lib/main.dart`** — Entry point; `HomeScreen` owns the bottom navigation and the logged-in user state. Deep links to `/match/<id>?uid=<uid>` are routed here.
- **`lib/models.dart`** — All Firestore-mapped data classes and enums.
- **`lib/services/firebase_service.dart`** — Low-level Firestore CRUD and streams.
- **`lib/services/match_service.dart`** — Match business logic (join, invite, tier progression).
- **`lib/services/notification_service.dart`** — Writes to `messages`/`mail` collections to trigger Cloud Functions.
- **`lib/screens/`** — Full-page screens (chat, organizer dashboard, players directory, history).
- **`lib/utils/`** — Stateless helpers: AI prompts, calendar export (ICS), email validation, feedback.
- **`functions/index.js`** — Cloud Functions: `sendTwilioMessage` and `sendEmail`, both triggered by Firestore `onDocumentCreated`.

### State Management
Plain `StatefulWidget` — no Provider, Riverpod, or Bloc. User state is held in `HomeScreen` and passed down via constructor arguments or callbacks.

### Notification Pipeline
Notifications are fire-and-forget writes to Firestore queues:
- SMS: write `{ to, body }` to `messages` → `sendTwilioMessage` Cloud Function sends via Twilio and updates delivery status on the same document.
- Email: write `{ to, message: { subject, text, html } }` to `mail` → `sendEmail` Cloud Function sends via Resend.

### Deployment
Merges to `main` automatically deploy the web build to Firebase Hosting (tennis-app-mp-2026 / www.finapps.com) via GitHub Actions. PRs get a preview URL via a separate workflow.

### Firestore Security Rules
Rules require Firebase Auth (`request.auth != null`) for all reads and writes. Users collection additionally checks `auth.uid in auth_uids`. All other collections (contracts, matches, scheduled_messages) allow any authenticated user to write — sufficient for beta. Tighten to owner-only writes before public launch.

### Firebase Project
Project ID: `tennis-app-mp-2026`. Configuration is in `lib/firebase_options.dart` and `lib/secrets.dart`.
