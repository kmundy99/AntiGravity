const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const twilio = require("twilio");

const firestore = require("firebase-admin/firestore");

initializeApp();

exports.sendTwilioMessage = onDocumentCreated("messages/{messageId}", async (event) => {
    const snap = event.data;
    if (!snap) return;

    const accountSid = process.env.TWILIO_ACCOUNT_SID;
    const authToken = process.env.TWILIO_AUTH_TOKEN;
    const twilioNumber = process.env.TWILIO_PHONE_NUMBER;

    let client;
    if (accountSid && authToken) {
        client = twilio(accountSid, authToken);
    }

    const metadata = snap.data();
    const docRef = snap.ref;
    const { to, body } = metadata;

    if (!to || !body) {
        console.error("Missing 'to' or 'body' in message doc.");
        return;
    }

    if (!client) {
        console.error("Twilio client not initialized. Check TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN from your .env file.");
        await snap.ref.update({
            "delivery.state": "ERROR",
            "delivery.error": "Twilio client not configured"
        });
        return;
    }

    try {
        const message = await client.messages.create({
            body: body,
            from: twilioNumber,
            to: to,
        });

        await docRef.update({
            'delivery.state': 'SUCCESS',
            'delivery.info': `SMS sent with SID: ${message.sid}`,
            'delivery.startTime': firestore.FieldValue.serverTimestamp(),
            'delivery.endTime': firestore.FieldValue.serverTimestamp(),
        });

        logger.log(`SMS successfully sent to ${to}. SID: ${message.sid}`);
    } catch (error) {
        logger.error(`Error sending SMS to ${to}:`, error);

        // Update document with error state
        await docRef.update({
            'delivery.state': 'ERROR',
            'delivery.error': error.message,
            'delivery.startTime': firestore.FieldValue.serverTimestamp(),
            'delivery.endTime': firestore.FieldValue.serverTimestamp(),
        });
    }
});

exports.sendEmail = onDocumentCreated("mail/{docId}", async (event) => {
    // Initialize SendGrid lazily inside the function execution
    const sgMail = require('@sendgrid/mail');
    const sgApiKey = process.env.SENDGRID_API_KEY;
    if (sgApiKey) {
        sgMail.setApiKey(sgApiKey);
    } else {
        logger.error('SENDGRID_API_KEY environment variable is not set!');
    }

    const snapshot = event.data;
    if (!snapshot) {
        logger.error("No data associated with the event.");
        return;
    }

    const data = snapshot.data();
    const docRef = snapshot.ref;

    // Check if it's already been processed
    if (data.delivery && (data.delivery.state === 'SUCCESS' || data.delivery.state === 'ERROR')) {
        logger.log("Email document already processed. Skipping.");
        return;
    }

    const to = data.to;
    const message = data.message;

    if (!to || !message || !message.subject || (!message.html && !message.text)) {
        logger.error("Document is missing required properties ('to' and 'message' containing 'subject' and at least one of 'text' or 'html').");
        await docRef.update({
            'delivery.state': 'ERROR',
            'delivery.error': "Missing required properties.",
            'delivery.startTime': firestore.FieldValue.serverTimestamp(),
            'delivery.endTime': firestore.FieldValue.serverTimestamp(),
        });
        return;
    }

    try {
        const msg = {
            to: to,
            from: 'bookings@finapps.com', // Update with your verified SendGrid sender
            subject: message.subject,
            text: message.text,
            html: message.html,
        };

        await sgMail.send(msg);

        // Update document with success state
        await docRef.update({
            'delivery.state': 'SUCCESS',
            'delivery.startTime': firestore.FieldValue.serverTimestamp(),
            'delivery.endTime': firestore.FieldValue.serverTimestamp(),
        });

        logger.log(`Email successfully sent to ${to}.`);
    } catch (error) {
        logger.error(`Error sending Email to ${to}:`, error);

        // Update document with error state
        await docRef.update({
            'delivery.state': 'ERROR',
            'delivery.error': error.message,
            'delivery.startTime': firestore.FieldValue.serverTimestamp(),
            'delivery.endTime': firestore.FieldValue.serverTimestamp(),
        });
    }
});
