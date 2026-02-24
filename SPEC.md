# Lexington Tennis App: Master Spec

## 1. User Profile (8 Essential Fields)
* uid: Normalized Phone Number.
* name: Full display name.
* address: Physical address (linked to Google Maps).
* email: Contact email.
* gender: [Male, Female, Non-Binary, Other].
* ntrp: [3.0, 3.5, 4.0, 4.5, 5.0].
* notif_active: Boolean.
* notif_mode: [SMS, Email, Both].

## 2. Key Workflows
* Login: Phone-based. Uses Fuzzy Matching to find users.
* Onboarding: Forced profile setup if fields are missing.
* Dashboard: Real-time Firestore stream of matches.
* Participation: "Join" button adds Name/NTRP to roster.