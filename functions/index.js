const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onRequest } = require("firebase-functions/v2/https");
const { onMessagePublished } = require("firebase-functions/v2/pubsub");
const { onSchedule } = require("firebase-functions/v2/scheduler");
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
            from: 'bookings@finapps.com',
            subject: message.subject,
            text: message.text,
            html: message.html,
            ...(data.reply_to ? { replyTo: data.reply_to } : {}),
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
// AUTO-SCHEDULER — fires pending scheduled_messages when their time arrives
// =============================================================================

/**
 * Looks up a user's notification preferences and routes the message to
 * the appropriate Firestore queue (messages/ for SMS, mail/ for email).
 */
async function sendToUser(db, uid, subject, textBody, replyToEmail = null) {
    let phone = null;
    let email = null;
    let notifMode = "SMS";

    try {
        const userDoc = await db.collection("users").doc(uid).get();
        if (userDoc.exists) {
            const data = userDoc.data();
            if (data.notif_active === false) return; // user opted out
            notifMode = data.notif_mode || "SMS";
            const primaryContact = data.primary_contact || "";
            const storedEmail = data.email || "";

            if (primaryContact && !primaryContact.includes("@")) {
                phone = primaryContact;
            }
            if (storedEmail) {
                email = storedEmail;
            } else if (primaryContact.includes("@")) {
                email = primaryContact;
            }
        }
    } catch (e) {
        logger.warn(`sendToUser: could not look up user ${uid}`, e);
    }

    if (!phone && !email) return;

    const htmlBody = `<p>${textBody.replace(/\n/g, "<br/>")}</p>`;
    const mailDoc = (to, msg) => ({
        to, message: msg,
        ...(replyToEmail ? { reply_to: replyToEmail } : {}),
    });

    const sends = [];

    if (notifMode === "SMS") {
        if (phone) sends.push(db.collection("messages").add({ to: phone, body: textBody }));
        else if (email) sends.push(db.collection("mail").add(mailDoc(email, { subject, text: textBody, html: htmlBody })));
    } else if (notifMode === "Email") {
        if (email) sends.push(db.collection("mail").add(mailDoc(email, { subject, text: textBody, html: htmlBody })));
        else if (phone) sends.push(db.collection("messages").add({ to: phone, body: textBody }));
    } else if (notifMode === "Both") {
        if (phone) sends.push(db.collection("messages").add({ to: phone, body: textBody }));
        if (email) sends.push(db.collection("mail").add(mailDoc(email, { subject, text: textBody, html: htmlBody })));
    } else {
        if (phone) sends.push(db.collection("messages").add({ to: phone, body: textBody }));
        else if (email) sends.push(db.collection("mail").add(mailDoc(email, { subject, text: textBody, html: htmlBody })));
    }

    await Promise.all(sends);
}

exports.fireScheduledMessages = onSchedule("every 60 minutes", async () => {
    const db = getFirestore();
    const now = firestore.Timestamp.now();

    const pending = await db.collection("scheduled_messages")
        .where("status", "==", "pending")
        .where("scheduled_for", "<=", now)
        .get();

    if (pending.empty) return;

    for (const doc of pending.docs) {
        const msg = doc.data();

        try {
            // Skip if organizer disabled auto-send (message stays pending for manual dispatch)
            if (msg.auto_send_enabled === false) continue;

            // Look up organizer email for reply-to on all outbound emails
            let organizerEmail = null;
            try {
                const orgDoc = await db.collection("users").doc(msg.organizer_id).get();
                if (orgDoc.exists) organizerEmail = orgDoc.data().email || null;
            } catch (_) {}

            // Fetch current contract roster for filter evaluation
            const contractDoc = await db.collection("contracts").doc(msg.contract_id).get();
            const roster = contractDoc.exists ? (contractDoc.data().roster || []) : [];

            let recipients = msg.recipients || [];

            // Apply recipients_filter at send time
            if (msg.recipients_filter === "unpaid") {
                const unpaidUids = new Set(
                    roster.filter(p => p.payment_status === "pending").map(p => p.uid)
                );
                recipients = recipients.filter(r => unpaidUids.has(r.uid));
            } else if (msg.recipients_filter === "no_response" && msg.session_date) {
                const sessionDate = msg.session_date.toDate();
                const dateKey = `${sessionDate.getFullYear()}-` +
                    `${String(sessionDate.getMonth() + 1).padStart(2, "0")}-` +
                    `${String(sessionDate.getDate()).padStart(2, "0")}`;
                const sessionDoc = await db.collection("contracts").doc(msg.contract_id)
                    .collection("sessions").doc(dateKey).get();
                const availability = sessionDoc.exists ? (sessionDoc.data().availability || {}) : {};
                recipients = recipients.filter(r => !availability[r.uid]);
            }

            // If lineup_publish: run slot assignment algorithm and publish
            if (msg.type === "lineup_publish" && msg.session_date) {
                const sd = msg.session_date.toDate();
                const dateKey = `${sd.getFullYear()}-${String(sd.getMonth()+1).padStart(2,"0")}-${String(sd.getDate()).padStart(2,"0")}`;
                const sessionRef = db.collection("contracts").doc(msg.contract_id)
                    .collection("sessions").doc(dateKey);
                const sessionSnap = await sessionRef.get();

                // If already published, skip
                if (sessionSnap.exists && sessionSnap.data().assignment_state === "published") {
                    await doc.ref.update({ status: "cancelled" });
                    continue;
                }

                const availability = sessionSnap.exists ? (sessionSnap.data().availability ?? {}) : {};
                const spotsPerSession = ((contractDoc.data() ?? {}).courts_count ?? 1) * 4;

                // Run slot assignment algorithm (mirror of SlotAssignmentScreen._autoAssign)
                const sorted = [...roster].sort((a, b) => {
                    const pctA = (a.paid_slots ?? 0) > 0 ? (a.played_slots ?? 0) / a.paid_slots : 0;
                    const pctB = (b.paid_slots ?? 0) > 0 ? (b.played_slots ?? 0) / b.paid_slots : 0;
                    const cmp = pctA - pctB;
                    return cmp !== 0 ? cmp : (a.display_name || "").localeCompare(b.display_name || "");
                });

                const assignment = {};
                let confirmedCount = 0;
                for (const player of sorted) {
                    const avail = availability[player.uid];
                    if (avail === "available" && confirmedCount < spotsPerSession) {
                        assignment[player.uid] = "confirmed";
                        confirmedCount++;
                    } else if (avail === "available" || avail === "backup") {
                        assignment[player.uid] = "reserve";
                    } else {
                        assignment[player.uid] = "out";
                    }
                }

                // Write assignment to session doc
                await sessionRef.set({
                    id: dateKey,
                    date: msg.session_date,
                    assignment: assignment,
                    assignment_state: "published",
                }, { merge: true });

                // Send lineup emails to confirmed players
                const confirmedPlayers = roster.filter(p => assignment[p.uid] === "confirmed");
                const subjectLineup = "Lineup published for your tennis session";
                const sendPromises = confirmedPlayers.map(r => {
                    const manageLink = `https://www.finapps.com/#/session/${msg.contract_id}/${dateKey}/manage?uid=${encodeURIComponent(r.uid)}`;
                    const body = `Hi ${r.display_name || r.uid}, the lineup for ${dateKey} has been set. To manage your spot: ${manageLink}`;
                    return sendToUser(db, r.uid, subjectLineup, body, organizerEmail);
                });
                await Promise.all(sendPromises);

                // If lineup is underfilled, notify non-confirmed players and schedule a last-ditch
                if (confirmedCount < spotsPerSession) {
                    const spotsNeeded = spotsPerSession - confirmedCount;
                    const outPlayers = roster.filter(p => assignment[p.uid] !== "confirmed");
                    if (outPlayers.length > 0) {
                        const subjectSub = `Sub needed — ${spotsNeeded} spot${spotsNeeded > 1 ? "s" : ""} open for ${dateKey}`;
                        const subSendPromises = outPlayers.map(r => {
                            const subLink = `https://www.finapps.com/#/session/${msg.contract_id}/${dateKey}/subin?uid=${encodeURIComponent(r.uid)}`;
                            const body = `Hi ${r.display_name || r.uid}, the lineup for ${dateKey} has ${spotsNeeded} open spot${spotsNeeded > 1 ? "s" : ""}. Claim it here: ${subLink}`;
                            return sendToUser(db, r.uid, subjectSub, body, organizerEmail);
                        });
                        await Promise.all(subSendPromises);
                        await db.collection("message_log").add({
                            sent_by: msg.organizer_id,
                            sent_at: firestore.Timestamp.now(),
                            type: "sub_request",
                            subject: subjectSub,
                            body: "Sub request for underfilled lineup",
                            recipients: outPlayers.map(p => ({ uid: p.uid, display_name: p.display_name })),
                            context_type: "contract",
                            context_id: msg.contract_id,
                            delivery_count: outPlayers.length,
                            expire_at: firestore.Timestamp.fromMillis(firestore.Timestamp.now().toMillis() + 90 * 24 * 3600 * 1000),
                        });
                        // Schedule last-ditch 2 hours later
                        await db.collection("scheduled_messages").add({
                            organizer_id: msg.organizer_id,
                            contract_id: msg.contract_id,
                            type: "last_ditch",
                            session_date: msg.session_date,
                            scheduled_for: firestore.Timestamp.fromMillis(firestore.Timestamp.now().toMillis() + 2 * 3600 * 1000),
                            status: "pending",
                            subject: "Still looking for players — can you help?",
                            body: `Hi {playerName}, we still need ${spotsNeeded} more player${spotsNeeded > 1 ? "s" : ""} for the ${dateKey} session. Claim the spot: {link}`,
                            recipients: roster.map(p => ({ uid: p.uid, display_name: p.display_name })),
                            recipients_filter: "all",
                            auto_send_enabled: true,
                        });
                    }
                }

                const now2 = firestore.Timestamp.now();
                await db.collection("message_log").add({
                    sent_by: msg.organizer_id,
                    sent_at: now2,
                    type: "session_lineup",
                    subject: subjectLineup,
                    body: "Auto-publish lineup notification",
                    recipients: confirmedPlayers.map(p => ({ uid: p.uid, display_name: p.display_name })),
                    context_type: "contract",
                    context_id: msg.contract_id,
                    delivery_count: confirmedPlayers.length,
                    expire_at: firestore.Timestamp.fromMillis(now2.toMillis() + 90 * 24 * 3600 * 1000),
                });

                await doc.ref.update({ status: "sent", sent_at: now2 });
                continue; // skip generic send below
            }

            // If last_ditch: cancel if spot already filled; otherwise set subin link
            let linkTemplate = null;
            if (msg.type === "last_ditch" && msg.session_date) {
                const sd = msg.session_date.toDate();
                const dateKey = `${sd.getFullYear()}-` +
                    `${String(sd.getMonth() + 1).padStart(2, "0")}-` +
                    `${String(sd.getDate()).padStart(2, "0")}`;
                const sessionSnap = await db.collection("contracts").doc(msg.contract_id)
                    .collection("sessions").doc(dateKey).get();
                if (sessionSnap.exists) {
                    const assignment = sessionSnap.data().assignment ?? {};
                    const confirmedCount = Object.values(assignment).filter(s => s === "confirmed").length;
                    const spotsPerSession = ((contractDoc.data() ?? {}).courts_count ?? 1) * 4;
                    if (confirmedCount >= spotsPerSession) {
                        await doc.ref.update({ status: "cancelled" });
                        continue;
                    }
                }
                linkTemplate = (uid) =>
                    `https://www.finapps.com/#/session/${msg.contract_id}/${dateKey}/subin?uid=${encodeURIComponent(uid)}`;
            }

            if (recipients.length > 0) {
                // Build link template for availability_request
                if (msg.type === "availability_request" && msg.session_date) {
                    const sd = msg.session_date.toDate();
                    const dateKey = `${sd.getFullYear()}-` +
                        `${String(sd.getMonth() + 1).padStart(2, "0")}-` +
                        `${String(sd.getDate()).padStart(2, "0")}`;
                    linkTemplate = (uid) =>
                        `https://www.finapps.com/#/availability/${msg.contract_id}/${dateKey}?uid=${encodeURIComponent(uid)}`;
                }

                const sendPromises = recipients.map(r => {
                    let body = (msg.body || "")
                        .replace("{playerName}", r.display_name || r.uid);
                    if (linkTemplate) {
                        body = body.replace("{link}", linkTemplate(r.uid));
                    }
                    return sendToUser(db, r.uid, msg.subject, body, organizerEmail);
                });
                await Promise.all(sendPromises);

                // Log to message_log
                await db.collection("message_log").add({
                    sent_by: msg.organizer_id,
                    sent_at: now,
                    type: msg.type,
                    subject: msg.subject,
                    body: msg.body,
                    recipients: recipients,
                    context_type: "contract",
                    context_id: msg.contract_id,
                    delivery_count: recipients.length,
                    expire_at: firestore.Timestamp.fromMillis(now.toMillis() + 90 * 24 * 3600 * 1000),
                });
            }

            await doc.ref.update({ status: "sent", sent_at: now });
        } catch (e) {
            logger.error(`fireScheduledMessages: failed to process doc ${doc.id}`, e);
        }
    }
});

// =============================================================================
// DROPOUT CASCADE — fires when a session's assignment map changes
// =============================================================================

exports.onSessionAssignmentChange = onDocumentUpdated(
    "contracts/{contractId}/sessions/{sessionDate}",
    async (event) => {
        const before = event.data.before.data() ?? {};
        const after  = event.data.after.data()  ?? {};
        const { contractId, sessionDate } = event.params;

        const beforeAssign = before.assignment ?? {};
        const afterAssign  = after.assignment  ?? {};

        const allUids = new Set([...Object.keys(beforeAssign), ...Object.keys(afterAssign)]);
        const changed = [...allUids].filter(u => beforeAssign[u] !== afterAssign[u]);
        if (changed.length === 0) return;

        const db = getFirestore();
        const contractSnap = await db.collection("contracts").doc(contractId).get();
        if (!contractSnap.exists) return;
        const contract = contractSnap.data();
        const roster = contract.roster ?? [];

        // Option 3: slot changes always happen; emails only fire in auto mode.
        const isAutoMode = (contract.notification_mode ?? "auto") === "auto";

        const [y, m, d] = sessionDate.split("-").map(Number);
        const sm = contract.start_minutes ?? 0;
        const sessionStart = new Date(y, m - 1, d, Math.floor(sm / 60), sm % 60);
        const hoursUntil = (sessionStart - Date.now()) / 3600000;

        for (const uid of changed) {
            const prev = beforeAssign[uid];
            const curr = afterAssign[uid];

            // ── Case 1: Confirmed player dropped out ──────────────────────────────
            if (prev === "confirmed" && curr === "out") {
                const reserves = roster.filter(p => afterAssign[p.uid] === "reserve");
                const batchUpdates = {};

                // Mark as charged if within 24 h (always, regardless of mode)
                if (hoursUntil > 0 && hoursUntil < 24) {
                    batchUpdates[`assignment.${uid}`] = "charged";
                }

                if (reserves.length > 0) {
                    // Always promote first reserve (data integrity, not a notification)
                    batchUpdates[`assignment.${reserves[0].uid}`] = "confirmed";
                    await event.data.after.ref.update(batchUpdates);
                    // Lineup email fires via Case 2 on the next invocation (if auto mode)
                } else {
                    // No reserve — write charge (if any), then notify if auto mode
                    if (Object.keys(batchUpdates).length > 0) {
                        await event.data.after.ref.update(batchUpdates);
                    }

                    if (isAutoMode) {
                        const outPlayers = roster.filter(p =>
                            (afterAssign[p.uid] === "out" || batchUpdates[`assignment.${p.uid}`] === "charged")
                            && p.uid !== uid
                        );

                        if (outPlayers.length > 0) {
                            const subjectSub = "Sub needed — spot open for your tennis session";
                            const now = firestore.Timestamp.now();

                            const sendPromises = outPlayers.map(r => {
                                const subLink = `https://www.finapps.com/#/session/${contractId}/${sessionDate}/subin?uid=${encodeURIComponent(r.uid)}`;
                                const body = `Hi ${r.display_name || r.uid}, a spot has opened up for the ${sessionDate} session. Claim it here: ${subLink}`;
                                return sendToUser(db, r.uid, subjectSub, body);
                            });
                            await Promise.all(sendPromises);

                            await db.collection("message_log").add({
                                sent_by: contract.organizer_id,
                                sent_at: now,
                                type: "sub_request",
                                subject: subjectSub,
                                body: "Sub request with fill-in link",
                                recipients: outPlayers.map(p => ({ uid: p.uid, display_name: p.display_name })),
                                context_type: "contract",
                                context_id: contractId,
                                delivery_count: outPlayers.length,
                                expire_at: firestore.Timestamp.fromMillis(now.toMillis() + 90 * 24 * 3600 * 1000),
                            });

                            // Schedule last-ditch for 2 hours later
                            const lastDitchAt = firestore.Timestamp.fromMillis(now.toMillis() + 2 * 3600 * 1000);
                            await db.collection("scheduled_messages").add({
                                organizer_id: contract.organizer_id,
                                contract_id: contractId,
                                type: "last_ditch",
                                session_date: firestore.Timestamp.fromDate(new Date(y, m - 1, d)),
                                scheduled_for: lastDitchAt,
                                status: "pending",
                                subject: "Still looking for a player — can you help?",
                                body: `Hi {playerName}, we still need one more player for the ${sessionDate} session. Claim the spot: {link}`,
                                recipients: roster.map(p => ({ uid: p.uid, display_name: p.display_name })),
                                recipients_filter: "all",
                            });
                        }
                    }
                }
            }

            // ── Case 2: Player filled in (reserve or out → confirmed) ─────────────
            if ((prev === "reserve" || prev === "out") && curr === "confirmed") {
                // Always cancel any pending last_ditch (data cleanup, not a notification)
                const ldSnap = await db.collection("scheduled_messages")
                    .where("contract_id", "==", contractId)
                    .where("type", "==", "last_ditch")
                    .get();
                for (const ldDoc of ldSnap.docs) {
                    const ld = ldDoc.data();
                    if (ld.status === "pending" && ld.session_date) {
                        const sdt = ld.session_date.toDate();
                        const sdKey = `${sdt.getFullYear()}-${String(sdt.getMonth() + 1).padStart(2, "0")}-${String(sdt.getDate()).padStart(2, "0")}`;
                        if (sdKey === sessionDate) await ldDoc.ref.update({ status: "cancelled" });
                    }
                }

                // Send updated lineup only in auto mode
                if (isAutoMode) {
                    const confirmedPlayers = roster.filter(p => {
                        const st = p.uid === uid ? "confirmed" : afterAssign[p.uid];
                        return st === "confirmed";
                    });
                    const subjectLineup = "Updated lineup for your tennis session";
                    const sendPromises = confirmedPlayers.map(r => {
                        const manageLink = `https://www.finapps.com/#/session/${contractId}/${sessionDate}/manage?uid=${encodeURIComponent(r.uid)}`;
                        const body = `Hi ${r.display_name || r.uid}, the lineup for ${sessionDate} has been updated. To manage your spot: ${manageLink}`;
                        return sendToUser(db, r.uid, subjectLineup, body);
                    });
                    await Promise.all(sendPromises);

                    const now = firestore.Timestamp.now();
                    await db.collection("message_log").add({
                        sent_by: contract.organizer_id,
                        sent_at: now,
                        type: "session_lineup",
                        subject: subjectLineup,
                        body: "Updated lineup notification",
                        recipients: confirmedPlayers.map(p => ({ uid: p.uid, display_name: p.display_name })),
                        context_type: "contract",
                        context_id: contractId,
                        delivery_count: confirmedPlayers.length,
                        expire_at: firestore.Timestamp.fromMillis(now.toMillis() + 90 * 24 * 3600 * 1000),
                    });
                }
            }
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

// =============================================================================
// PROVISIONAL PLAYER CLEANUP — runs daily, deletes provisional accounts that
// have never logged in and were created more than 30 days ago.
// =============================================================================

exports.deleteStaleProvisionalPlayers = onSchedule("every 24 hours", async () => {
    const db = getFirestore();
    const cutoff = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    const cutoffTimestamp = firestore.Timestamp.fromDate(cutoff);

    const snap = await db.collection("users")
        .where("accountStatus", "==", "provisional")
        .where("created_at", "<=", cutoffTimestamp)
        .get();

    if (snap.empty) {
        logger.log("deleteStaleProvisionalPlayers: no stale provisional players found.");
        return;
    }

    const batch = db.batch();
    let count = 0;
    for (const doc of snap.docs) {
        const data = doc.data();
        // Only delete if they have never logged in
        if (!data.last_login_at) {
            batch.delete(doc.ref);
            count++;
        }
    }

    if (count > 0) {
        await batch.commit();
        logger.log(`deleteStaleProvisionalPlayers: deleted ${count} stale provisional player(s).`);
    } else {
        logger.log("deleteStaleProvisionalPlayers: all provisional players have logged in, none deleted.");
    }
});