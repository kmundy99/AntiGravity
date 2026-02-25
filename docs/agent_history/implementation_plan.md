# Goal Description

Address the 5-6 bugs and feature requests logged by the user in the new Feedback tool.

## User Feedback Reviewed
Based on the Firestore `feedbacks` collection from today, here are the issues logged:
1. **Feedback Modal Enhancements**: Add a "Bug" tab. Also address the state issue where switching tabs keeps the previous text (or at least clarify the behavior).
2. **Email Notifications**: Organizer did not receive an email when inviting a player ("Kix"). (Note: Currently, only the invited player receives the email, not the host. I need to clarify if the host should receive a confirmation).
3. **Chat Notifications**: Add push/email notifications when someone posts in the Match Chat.
4. **Recruit Flow Redesign**: 
   - Rename "Direct Recruit" to "Recruit Players".
   - Remove the "Invite Circle" option (it's too opaque).
   - "Recruit Players" should open the Players Directory with a selection capability.
   - Add the ability to create a shadow profile directly from this screen.

### 1. Feedback Modal Update (`lib/utils/feedback_utils.dart`)
- Add a "Bug Report" option to the segmented control.
- Clear the text input when switching tabs.
- Wait, where does the AI get its instructions? Currently, I hardcoded a `userGuide` string directly into this file! I'll extract it so we can easily edit it later.

### 2. Match Chat Notifications (`lib/screens/match_chat_screen.dart` & `lib/services/notification_service.dart`)
- Update the `sendMessage` function in the chat screen to trigger a backend notification to all *other* players in the match roster.
- Create a new `sendChatNotification` function in `notification_service.dart` that writes to the `messages` or `mail` collection for each participant in the match.

### 3. Recruitment Flow Redesign (`lib/screens/organizer_dashboard_screen.dart` & `lib/screens/players_directory_screen.dart`)
- Remove the "Invite Circle" button.
- Rename the "Direct Recruit" button to "Recruit Players".
- "Recruit Players" will open `SelectPlayersScreen`.
- Add an "Invite New Player (Shadow Profile)" button to `SelectPlayersScreen`.
- **NEW**: Add that same "Invite New Player" button to the main `PlayersDirectoryScreen` so users can create shadow profiles outside of a specific match flow.

### 4. Debugging Email Delivery
- Since the invited player (Kix) didn't receive the email, I will check the `mail` collection in Firestore to see if the Firebase Extension successfully processed the document or if it threw an error (e.g., bad SendGrid API key or unverified sender address).

### 5. Email Content Enhancements
- Update `NotificationService.sendInvite` to accept the full `Match` object.
- Format the match date, time, and location into a readable string.
- Create an HTML string that embeds these details visually, as well as a list of confirmed players.
- Update callers in `create_match.dart` and `organizer_dashboard_screen.dart` to pass these new parameters.

### 6. Match Deep Link Routing
- Update `main.dart`'s `TennisApp` router: route `/match/:id` to `HomeScreen(initialMatchId: matchId)` instead of `OrganizerDashboardScreen`.
- Update `HomeScreen` to accept `initialMatchId`.
- In `_HomeScreenState`, automatically open `_showMatchDetailsDialog(widget.initialMatchId)` once matches are loaded.
- Update `_showMatchDetailsDialog` to distinguish between `invited` and `accepted` roster statuses. If a user is `invited`, show an "Accept Invite" button that updates their existing roster entry's status rather than appending a new one.

### 7. Match UI Enhancements & Performance
- Fix the calendar load speed: `main.dart`'s `_matchesSub` was querying the entire history of matches without limits. Added `.where('match_date', isGreaterThanOrEqualTo: ...)` to drastically shrink the query to only upcoming matches, removing the 5-6 second delay.
- Fix the player count logic: Ensure `_refreshCalendarData`, `_showMatchDetailsDialog`, and `HistoryScreen` only count players with an `accepted` status toward the room limits.

### 8. Streamlined Guest Acceptance Flow
- When an invited player logs in for the first time or logs in as a Shadow Profile and reaches `HomeScreen`, if an `initialMatchId` is present, the app currently halts them to complete their profile.
- I will intercept `_loadUser()` in `main.dart`. If an `initialMatchId` is present, even if their `accountStatus` is provisional or null, I will bypass `_isEditingProfile = true` and instead immediately display `_showMatchDetailsDialog` just like a fully registered user.
- If they interact with the dialogue (Accept/Decline/Close) they will be returned to the normal `HomeScreen` where they can view the app, but they will be bounded by the `Quick Setup` (provisional) rules until they complete their profile from the Directory tab.

### 9. Player Removal Emails & Actual Organizer Names
- The user noticed that invite emails say `Organizer: Organizer (You)`. This happens because `create_match.dart` uses a fallback of `'Organizer'` if it can't find the user's name, but also because their displayName might naturally contain ` (You)` from the UI.
- Update `NotificationService.sendInvite` to explicitly strip `" (You)"` from the `organizerName` parameter before rendering it in the HTML body. 
- Create a new `sendRemoval` function in `NotificationService` that dispatches an email explaining they have been removed from the match. This will be an HTML template similar to the invite email.
- Update `OrganizerDashboardScreen`'s `Remove Player` action to call `NotificationService.sendRemoval(...)` when a player with an `accepted` status is booted from the roster.

### 10. Auto-Login via Deep Links
- The user reported that entering the wrong email during the manual login flow caused issues when accepting a match.
- To prevent this, deep links should automatically authorize the user based on the email/phone they were invited with.
- Update `NotificationService.sendInvite` to append `?uid=${Uri.encodeComponent(contact)}` to the URL sent in the email/SMS.
- Update the `onGenerateRoute` parser in `main.dart`'s `TennisApp` widget to extract the `uid` query parameter and pass it to `HomeScreen` as `initialUid`.
- Update `_HomeScreenState._loadUser()` to check if `widget.initialUid` is present. If so, immediately save it to `SharedPreferences` as `user_phone` and proceed to load that user's profile and match dialog, completely bypassing the manual login screen.

### 11. Tap anywhere on calendar to create a match
- The user submitted a Feature Request: "instead of a + button at the bottom right, I should be able to click anywhere on the calendar at a specific time and enter the "create a match" flow, with the date and times already populated. The + sign at the bottom of the screen can be removed and the "invite players" flow there can also be removed".
- Update `_HomeScreenState` to remove the `FloatingActionButton`.
- Introduce `onTap` parameter inside the Syncfusion `SfCalendar` widget in `main.dart`.
- When a user taps on a specific time slot on the calendar (an empty cell), extract the `CalendarTapDetails.date`.
- If the tap is valid (e.g. not on a calendar header), immediately navigate to `CreateMatchScreen`, passing the tapped `DateTime` as an initial parameter.
- Update `CreateMatchScreen` in `create_match.dart` to accept an `initialDate` parameter and pre-fill the `_selectedDate` and `_selectedStartTime` state variables.

### 12. App Flow Unification & The "Missing Invite" Root Cause
- **The Bug**: When you recruited players during Match Creation, they did not receive an email. This is because `User.fromFirestore` was searching for a `primary_contact` data field instead of using the document ID. Because of this, the selected users had an empty contact string, and the app inadvertently treated them as "Shadow Profiles" (bypassing the email trigger).
- **The Duplication**: Currently, adding players to a match while creating it (`CreateMatchScreen`) has completely duplicated and diverging logic compared to adding players to an existing match (`OrganizerDashboardScreen`).
- **The Unification Plan**:
   1. **Fix `User.fromFirestore`**: Update `models.dart` to map `primaryContact` to `doc.id` if the data field is missing.
   2. **Extract a universal `MatchService.addPlayersToMatch` function** that serves as the single source of truth for all roster additions.

#### Detailed Logic Outline for `MatchService.addPlayersToMatch`
To ensure we cover all use-cases (Match Creation vs. Post-Creation Recruitment), here is the exact proposed logic for the new universal function:

**Inputs:**
- `Match match`: The current state of the match.
- `String matchId`: The Firestore document ID for the match.
- `List<User> newRecruits`: The list of players the organizer selected from the Directory.
- `String organizerName`: The clean display name of the host.

**Execution Steps / Checks:**
1. **Deduplication Check**: Iterate through `newRecruits`. If a recruit's `primaryContact` already exists inside `match.roster`, silently drop them. This guarantees a user is never added twice.
2. **Provisional & Shadow Check**: Any user selected from `SelectPlayersScreen` is guaranteed to have a valid `User` document in Firestore (even if they were created via the "Create Shadow Profile" button, because that button saves them to the database as a "provisional" account). Because of this, we will *never* need to dynamically generate fake `shadow_` IDs. Everyone gets added using their real `primaryContact` (which doubles as their explicit row ID).
3. **Roster Construction**: Create a list of `Roster` objects for these valid recruits, assigning them the `RosterStatus.invited` status.
4. **Firestore Transaction**: Connect to Firestore and execute an `update` on the `matches` collection document for `matchId`. This appends the `Roster` objects to the existing array.
5. **Notification Dispatch Rule**: Iterate through the newly constructed roster.
   - If they have a valid email/phone: Call `NotificationService.sendInvite()` passing the match details and their unique ID to generate the Auto-Login Deep Link.

#### Flow Integration
- **In `CreateMatchScreen`**: When "Confirm & Post Match" is clicked, the Match is saved to Firestore *with only the Organizer in the roster*. Then, it grabs the exact `List<User>` selected from `SelectPlayersScreen` and passes it to `MatchService.addPlayersToMatch`. No duplicate invitation loops on the UI side.
- **In `OrganizerDashboardScreen`**: When "Recruit Players" is clicked, it behaves exactly the same: it takes the `List<User>` from `SelectPlayersScreen` and passes it to `MatchService.addPlayersToMatch`.

## User Review Required

Good catch! I just reviewed `SelectPlayersScreen` and `InvitePlayerScreen` to confirm. 

You are completely correct: the "Create Shadow Profile" button explicitly pushes a real "provisional" `User` document to the database. That means *every* selectable user in `SelectPlayersScreen` is a real, database-backed entity. 
This makes things beautifully simple: `MatchService.addPlayersToMatch` doesn't need to spoof fake `shadow_` IDs at all. It will just take the exact Users the UI passes it, deduplicate them based on their real `primaryContact` IDs, lock them into the database roster, and dispatch notifications! 
I have updated **Section 12** to reflect this. Does this refined plan accurately reflect the solid architecture you had in mind?

---

### 13. Match Details Popup Redesign & Player Opt-Out
- **The Problem**: Currently, the match details popup (`main.dart`) displays accepted players as a simple comma-separated string (e.g. `Accepted: Organizer, ✅ Kix`). The organizer's initial name defaults to "Organizer (You)" inside `CreateMatchScreen` because it wasn't fetching their actual name from Firestore during creation. Finally, players have no way to remove themselves from a match directly from the details popup.
- **The Solution**:
    1. **Fix Organizer Name**: In `CreateMatchScreen._loadUser()`, fetch the user's document from Firestore using `_currentUserPhone` so that `_organizerName` is correctly set to their real `displayName` (instead of a hardcoded string) before the match is saved.
    2. **Redesign Roster List**: In `main.dart` `_showMatchDetailsDialog`, replace the comma-separated text widget with a `Column` of `Row` widgets for each accepted player.
    3. **Add "Remove Me" Action**: On the `Row` corresponding to the current user (`isMe`), display a "Remove Me" `TextButton`.
    4. **Handle Opt-Out**: When "Remove Me" is clicked:
        - Create a new `NotificationService.sendRemoval(...)` function to send an email to the match's `organizerId` informing them that the player has dropped out.
        - Close the details dialogue and refresh the home screen.

---

### 14. Match Cancellation Flow
- **The Problem**: Right now, if the match Organizer clicks "Remove Me" in the match details popup, their name gets stripped from the list but they conceptually remain the host (`organizerId`), creating an orphaned match. Organizers need a formal way to cancel a match rather than just withdrawing.
- **The Solution**:
    1. **Hide "Remove Me" from Host**: Inside `main.dart`, update the `_showMatchDetailsDialog` logic to hide the "Remove Me" text button if `_myPhone == match['organizerId']`.
    2. **Notification Service**: Develop a `NotificationService.sendMatchCancellation` function that takes a reason and emails/texts all currently "accepted" or "invited" players in the roster that the match is off.
    3. **Organizer Dashboard Action**: Add a "Cancel Match" button to the `OrganizerDashboardScreen` (e.g., in the bottom nav or a red button at the bottom of the list).
    4. **Execute Cancellation**: When clicked, prompt the host for a cancellation reason via an alert dialog. Then, fire `sendMatchCancellation` for all relevant players, run a Firestore `delete()` on the match document, and redirect the host back to the `HomeScreen`.

## User Review Required
Does the **Section 14** implementation approach satisfy your requirements for match cancellation? If so, hit Proceed and I will build it out!
