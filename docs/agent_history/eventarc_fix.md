# Fixing the Eventarc Permission Error

The error `Permission denied while using the Eventarc Service Agent` happens frequently when installing Firebase Extensions for the first time on a new project. Google Cloud needs to automatically assign a specific role (`roles/eventarc.serviceAgent`) behind the scenes, but sometimes it fails or gets delayed.

Here are the exact steps to fix this manually in your Google Cloud Console:

1. **Go to the Google Cloud Console IAM page:**
   Click this direct link: [Google Cloud IAM - Select your project](https://console.cloud.google.com/iam-admin/iam)
   *(Make sure you are logged in with the same account and select your project `tennis-app-mp-2026` at the top).*

2. **Check the box for "Include Google-provided role grants"**
   In the top right corner of the IAM table, check the box that says "Include Google-provided role grants" so you can see the hidden service accounts.

3. **Find the Pub/Sub Service Account**
   Look in the list of principals for an email address that looks like this:
   `service-[YOUR_PROJECT_NUMBER]@gcp-sa-pubsub.iam.gserviceaccount.com`
   *(Instead of [YOUR_PROJECT_NUMBER], it will be a string of numbers).*

4. **Edit the Permissions**
   - Click the pencil icon (**Edit principal**) next to that specific `gcp-sa-pubsub` service account.
   - Click **Add Another Role**.
   - In the search box, search for **Eventarc Service Agent**.
   - Select it, and click **Save**.

5. **Retry the Installation**
   Go back to the Firebase Console and retry installing the "Trigger Email from Firestore" extension. It should now possess the necessary permissions to deploy the background function!
