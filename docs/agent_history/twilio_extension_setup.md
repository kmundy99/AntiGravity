# Installing Twilio Firebase Extension with Node 20

To get around Google Cloud's recent Node 18 deprecation issue, we need to install the extension via the command line so we can inject a Node 20 override. 

I've just finished installing the Firebase CLI on your machine. Here are the exact 3 steps you need to take:

## Step 1: Login to Firebase
In your terminal where the app is running, press `Ctrl+C` to stop the app temporarily. Then, run this command to log in to your Firebase account:
```bash
firebase login --no-localhost
```
*It will give you a link to click, ask you to log in with Google, and then give you a code to paste back into the terminal.*

## Step 2: Configure the Extension
Once you are logged in, run this command:
```bash
firebase ext:install twilio/send-messages --project=tennis-app-mp-2026
```
The terminal will guide you through the exact same questions as the website did:
- **Cloud Functions location:** `us-central1`
- **Twilio Account Sid:** Your `AC...` string
- **Twilio Auth Token:** Your 32-character token
- **Twilio phone number:** Your `+1888...` number
- **Twilio Messaging Service Sid:** Leave blank
- **Message documents collection:** `messages`

## Step 3: Add the Override and Deploy
When the setup finishes, it will generate a new folder called `extensions`.

1. Open the file `extensions/send-messages.env` in your code editor.
2. Add this exact line to the very bottom of the file:
   `EXT_NODE_VERSION=20`
3. Save the file.
4. Run this command to deploy it to the cloud!
   ```bash
   firebase deploy --only extensions
   ```

*(Once that command finishes, your text message integration is complete and you can run `flutter run -d chrome` again!)*
