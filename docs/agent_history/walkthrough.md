# Changes Made
- Created `lib/utils/feedback_utils.dart` to centralize the `showFeedbackModal` logic.
- Updated `lib/main.dart` login screen to allow logging in using *either* an email address or a phone number. If an email is provided (detected by the presence of an `@` symbol), it will be lowercased and used as the unique identifier for the session, perfect for testing with multiple dummy email profiles!
- Added the feedback (question/lightbulb) `FloatingActionButton` to the following drilldown screens:
  - `OrganizerDashboardScreen` (Manage Match)
  - `SelectPlayersScreen` (Recruit Player)
  - `MatchChatScreen`
- Removed unused imports and references to keep the codebase clean.

# Validation Results
- Verified that `showFeedbackModal` accepts context and correctly applies the user's ID, Name, and current screen metadata to any feedback submitted.
- Code compiles successfully. If you have your `flutter run -d chrome` command still running, pressing `r` in the terminal to hot reload will refresh the app and immediately show the new buttons!

---

# Update: Email & SMS Notifications

## Changes Made
- Updated the "Invite Player" screen (Shadow Profiles) to accept **both Phone Numbers and Email Addresses** in the input field. If an email is provided (detected by the presence of an `@` symbol), it is stored as an email.
- Modified `NotificationService` to write the notification requirements to Firestore collections.
  - If a player's contact is a phone number, it writes a document to the `messages` collection (Target for the Twilio Firebase Extension).
  - If a player's contact is an email, it writes a document to the `mail` collection (Target for the Trigger Email Firebase Extension).
- Updated the match creation flow (`CreateMatchScreen`) and the organizer dashboard (`OrganizerDashboardScreen`) to automatically dispatch an invitation using the `NotificationService` whenever a player is added to the roster.

## Required Next Steps
You're all set! I investigated the issue with the missing emails (specifically the Kix invites) and discovered the official Firebase "Send Email" Extension is deprecated on Node 18, causing the exact same deployment error we saw with Twilio!

To fix this, I completely uninstalled the faulty extension and wrote a custom 2nd Generation Cloud Function (`sendEmail` via `@sendgrid/mail`) that is now running seamlessly on Node 20. 

**Both SMS Text Messages and Emails are now fully managed by your custom Cloud Functions!** No extensions required.
