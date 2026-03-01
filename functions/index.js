const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onRequest } = require("firebase-functions/v2/https");
const { onMessagePublished } = require("firebase-functions/v2/pubsub");
const { defineSecret } = require("firebase-functions/params");
const { CloudBillingClient } = require("@google-cloud/billing");
const logger = require("firebase-functions/logger");
const twilio = require("twilio");

const firestore = require("firebase-admin/firestore");

initializeApp();

// =============================================================================
// TWILIO SMS
// =============================================================================

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

// =============================================================================
// SENDGRID EMAIL
// =============================================================================

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

// =============================================================================
// GEMINI AI — called by the feedback assistant in the app
// The API key is stored in Google Cloud Secret Manager, NOT in client code.
// =============================================================================

const geminiApiKey = defineSecret("GEMINI_API_KEY");

exports.askGemini = onRequest(
    {
        secrets: [geminiApiKey],
        cors: [
            "https://finapps.com",
            "https://www.finapps.com",
            "http://localhost:5000",
            "http://localhost:8080",
        ],
    },
    async (req, res) => {
        if (req.method !== "POST") {
            res.status(405).json({ error: "Method not allowed" });
            return;
        }

        const { description, systemPrompt } = req.body;

        if (!description || description.trim() === "") {
            res.status(400).json({ error: "Missing description" });
            return;
        }

        try {
            const response = await fetch(
                `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${geminiApiKey.value()}`,
                {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                        system_instruction: {
                            parts: [{ text: systemPrompt || "" }],
                        },
                        contents: [
                            {
                                parts: [{ text: description }],
                            },
                        ],
                    }),
                }
            );

            if (response.ok) {
                const data = await response.json();
                const aiText =
                    data.candidates?.[0]?.content?.parts?.[0]?.text ||
                    "I'm sorry, I couldn't process that.";
                res.status(200).json({ response: aiText });
            } else {
                logger.error("Gemini API error:", response.status);
                res.status(500).json({ error: "AI service error" });
            }
        } catch (error) {
            logger.error("Cloud Function error:", error);
            res.status(500).json({ error: "Internal error" });
        }
    }
);

// =============================================================================
// BUDGET ALERTS
// =============================================================================

// Initialize the Billing Client
const billing = new CloudBillingClient();

exports.disableBillingOnBudgetExceeded = onMessagePublished("budget-alerts", async (event) => {
    try {
        const pubsubData = event.data.message.data;
        const msgStr = Buffer.from(pubsubData, 'base64').toString('utf8');
        const pubsubMessage = JSON.parse(msgStr);

        const costAmount = parseFloat(pubsubMessage.costAmount);
        const budgetAmount = parseFloat(pubsubMessage.budgetAmount);

        if (costAmount <= budgetAmount) {
            logger.log(`Cost ${costAmount} is within budget ${budgetAmount}.`);
            return;
        }

        const projectId = "finapps";
        const projectName = `projects/${projectId}`;

        logger.warn(`Cost ${costAmount} exceeded budget ${budgetAmount}! Disabling billing for ${projectName}...`);

        const [billingInfo] = await billing.getProjectBillingInfo({ name: projectName });

        if (!billingInfo.billingEnabled) {
            logger.log("Billing is already disabled.");
            return;
        }

        // To disable billing for a project, update the project billing info with an empty string for the billing account name.
        const [res] = await billing.updateProjectBillingInfo({
            name: projectName,
            projectBillingInfo: {
                billingAccountName: ''
            }
        });

        logger.log("Billing successfully disabled: ", res);
    } catch (error) {
        logger.error("Failed to process budget alert and disable billing:", error);
    }
});