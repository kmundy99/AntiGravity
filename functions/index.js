const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onRequest } = require("firebase-functions/v2/https");
const { onMessagePublished } = require("firebase-functions/v2/pubsub");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { CloudBillingClient } = require("@google-cloud/billing");
const logger = require("firebase-functions/logger");
const { Resend } = require("resend");

const firestore = require("firebase-admin/firestore");

initializeApp();

const resendApiKey = defineSecret("RESEND_API_KEY");

// =============================================================================
// EMAIL (RESEND)
// =============================================================================

exports.sendEmail = onDocumentCreated(
    {
        document: "mail/{docId}",
        secrets: [resendApiKey],
    },
    async (event) => {
        // Initialize Resend lazily inside the function execution
        const resend = new Resend(resendApiKey.value());

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
                to: typeof to === 'string' ? [to] : to,
                from: `${data.from_name || 'Adhoc Local'} <tennis@mail.adhoc-local.com>`,
                subject: message.subject,
                ...(message.text ? { text: message.text } : {}),
                ...(message.html ? { html: message.html } : {}),
                ...(data.reply_to ? { reply_to: data.reply_to } : {}),
            };

            const response = await resend.emails.send(msg);

            if (response.error) {
                logger.error("Resend API returned an error object:", JSON.stringify(response.error));
                throw new Error(`Resend API Error: ${response.error.message} (${response.error.name}) - ${response.error.statusCode}`);
            }

            const resendData = response.data;

            // Update document with success state
            await docRef.update({
                'delivery.state': 'SUCCESS',
                'delivery.info': `Email sent with ID: ${resendData?.id}`,
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
            "https://adhoc-local.com",
            "https://www.adhoc-local.com",
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
 * Formats a Date as YYYY-MM-DD.
 */
function formatDateKey(date) {
    return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
}

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

/**
 * Computes fully-rendered per-player emails for a scheduled message.
 * Returns { renderedEmails, assignment?, confirmedPlayers?, spotsNeeded?, dateKey?, sessionRef? }
 * or { skip: true } if the message should be cancelled.
 */
async function generateMessageContent(db, msg, roster, contractData) {
    // Apply recipients_filter
    let recipients = msg.recipients || [];
    if (msg.recipients_filter === "unpaid") {
        const unpaidUids = new Set(
            roster.filter(p => p.payment_status === "pending").map(p => p.uid)
        );
        recipients = recipients.filter(r => unpaidUids.has(r.uid));
    } else if (msg.recipients_filter === "no_response" && msg.session_date) {
        const dateKey = formatDateKey(msg.session_date.toDate());
        const sessionDoc = await db.collection("contracts").doc(msg.contract_id)
            .collection("sessions").doc(dateKey).get();
        const availability = sessionDoc.exists ? (sessionDoc.data().availability || {}) : {};
        const attendance = sessionDoc.exists ? (sessionDoc.data().attendance || {}) : {};
        // Both "available" and "played" count as a response in availability, or any valid manual attendance status
        recipients = recipients.filter(r => {
            const hasAvail = availability[r.uid] && ["available", "played", "backup", "unavailable"].includes(availability[r.uid]);
            const hasAtten = attendance[r.uid] && ["available", "played", "backup", "unavailable", "reserve", "out", "charged"].includes(attendance[r.uid]);
            return !hasAvail && !hasAtten;
        });
    }

    // lineup_publish: run slot assignment algorithm and build per-player emails
    if (msg.type === "lineup_publish" && msg.session_date) {
        const sd = msg.session_date.toDate();
        const dateKey = formatDateKey(sd);
        const sessionRef = db.collection("contracts").doc(msg.contract_id)
            .collection("sessions").doc(dateKey);
        const sessionSnap = await sessionRef.get();

        if (sessionSnap.exists && sessionSnap.data().assignment_state === "published") {
            return { skip: true };
        }

        const availability = sessionSnap.exists ? (sessionSnap.data().availability ?? {}) : {};
        const attendance = sessionSnap.exists ? (sessionSnap.data().attendance ?? {}) : {};
        const spotsPerSession = (contractData.courts_count ?? 1) * 4;

        // Mirror of SlotAssignmentScreen._autoAssign
        const sorted = [...roster].sort((a, b) => {
            const aOld = attendance[a.uid];
            const aPlayedBefore = (aOld === "played" || aOld === "charged") ? Math.max(0, (a.played_slots || 0) - 1) : (a.played_slots || 0);
            const pctA = (a.paid_slots || 0) > 0 ? aPlayedBefore / a.paid_slots : 0;

            const bOld = attendance[b.uid];
            const bPlayedBefore = (bOld === "played" || bOld === "charged") ? Math.max(0, (b.played_slots || 0) - 1) : (b.played_slots || 0);
            const pctB = (b.paid_slots || 0) > 0 ? bPlayedBefore / b.paid_slots : 0;

            const cmp = pctA - pctB;
            return cmp !== 0 ? cmp : (a.display_name || "").localeCompare(b.display_name || "");
        });

        const assignment = {};
        let confirmedCount = 0;
        for (const player of sorted) {
            const avail = availability[player.uid];
            const atten = attendance[player.uid];
            const isAvail = avail === "available" || avail === "played" || atten === "available" || atten === "played" || atten === "reserve";
            const isBackup = avail === "backup" || atten === "backup";

            if (isAvail && confirmedCount < spotsPerSession) {
                assignment[player.uid] = "confirmed";
                confirmedCount++;
            } else if (isAvail || isBackup) {
                assignment[player.uid] = "reserve";
            } else {
                assignment[player.uid] = "out";
            }
        }

        const confirmedPlayers = roster.filter(p => assignment[p.uid] === "confirmed");
        const reservePlayers = roster.filter(p => assignment[p.uid] === "reserve");

        const formatPlayer = (p, isConfirmed) => {
            const paid = p.paid_slots || 0;
            const name = p.display_name || p.uid;
            if (paid === 0) return `- ${name}`;

            const oldAtten = attendance[p.uid];
            const truePlayedBefore = (oldAtten === 'played' || oldAtten === 'charged') ? Math.max(0, (p.played_slots || 0) - 1) : (p.played_slots || 0);

            const pctBefore = Math.round((truePlayedBefore / paid) * 100);
            const pctAfter = Math.round(((truePlayedBefore + (isConfirmed ? 1 : 0)) / paid) * 100);
            return `- ${name} (Played: ${pctBefore}% -> ${pctAfter}%)`;
        };

        const confirmedNames = confirmedPlayers.map(p => formatPlayer(p, true)).join("\n") || "(none yet)";
        const reserveSection = reservePlayers.length > 0
            ? `\n\nReserves:\n${reservePlayers.map(p => formatPlayer(p, false)).join("\n")}`
            : "";

        const subjectLineup = "Lineup published for your tennis session";
        const baseUrl = msg.base_url || "https://www.adhoc-local.com";
        const gridLink = `${baseUrl}/#/session/${msg.contract_id}/${dateKey}/grid`;
        const groupBody = `Hi all,\n\nThe lineup for ${dateKey} has been set.\n\nConfirmed: ${confirmedNames}${reserveSection}\n\nView the full grid here: ${gridLink}`;
        const renderedEmails = [{
            uid: "_group_",
            display_name: `All ${roster.length} players`,
            subject: subjectLineup,
            body: groupBody,
        }];

        return {
            renderedEmails,
            assignment,
            confirmedPlayers,
            reservePlayers,
            confirmedCount,
            spotsPerSession,
            dateKey,
            spotsNeeded: Math.max(0, spotsPerSession - confirmedCount),
            sessionRef,
        };
    }

    // last_ditch: cancel if spot already filled
    let linkTemplate = null;
    if (msg.type === "last_ditch" && msg.session_date) {
        const sd = msg.session_date.toDate();
        const dateKey = formatDateKey(sd);
        const sessionSnap = await db.collection("contracts").doc(msg.contract_id)
            .collection("sessions").doc(dateKey).get();
        if (sessionSnap.exists) {
            const assignment = sessionSnap.data().assignment ?? {};
            const confirmedCount = Object.values(assignment).filter(s => s === "confirmed").length;
            const spotsPerSession = (contractData.courts_count ?? 1) * 4;
            if (confirmedCount >= spotsPerSession) return { skip: true };
        }
        const baseUrl = msg.base_url || "https://www.adhoc-local.com";
        linkTemplate = (uid) =>
            `${baseUrl}/#/session/${msg.contract_id}/${dateKey}/subin?uid=${encodeURIComponent(uid)}`;
    } else if ((msg.type === "availability_request" || msg.type === "availability_reminder") && msg.session_date) {
        const dateKey = formatDateKey(msg.session_date.toDate());
        const baseUrl = msg.base_url || "https://www.adhoc-local.com";
        linkTemplate = (uid) =>
            `${baseUrl}/#/availability/${msg.contract_id}/${dateKey}?uid=${encodeURIComponent(uid)}`;
    }

    const renderedEmails = recipients.map(r => {
        let body = (msg.body || "").replace("{playerName}", r.display_name || r.uid);
        if (linkTemplate) body = body.replace("{link}", linkTemplate(r.uid));
        return { uid: r.uid, display_name: r.display_name || r.uid, subject: msg.subject, body };
    });

    return { renderedEmails };
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
            let organizerEmail = null;
            try {
                const orgDoc = await db.collection("users").doc(msg.organizer_id).get();
                if (orgDoc.exists) organizerEmail = orgDoc.data().email || null;
            } catch (_) { }

            const contractDoc = await db.collection("contracts").doc(msg.contract_id).get();
            const contractData = contractDoc.exists ? contractDoc.data() : {};
            const roster = contractData.roster || [];

            // Rollover logic: when generating new availability requests/reminders, clear past reserves
            if ((msg.type === "availability_request" || msg.type === "availability_reminder") && msg.session_date) {
                try {
                    const pastSessions = await db.collection("contracts").doc(msg.contract_id)
                        .collection("sessions")
                        .where("date", "<", msg.session_date)
                        .orderBy("date", "desc")
                        .limit(3)
                        .get();
                    for (const sDoc of pastSessions.docs) {
                        const sData = sDoc.data();
                        const att = { ...(sData.attendance || {}) };
                        const assign = { ...(sData.assignment || {}) };
                        let updated = false;
                        for (const uid of Object.keys(att)) {
                            if (att[uid] === "reserve") {
                                att[uid] = "out";
                                assign[uid] = "out";
                                updated = true;
                            }
                        }
                        if (updated) {
                            await sDoc.ref.update({ attendance: att, assignment: assign });
                        }
                    }
                } catch (e) {
                    logger.warn("Failed to clear past reserves: ", e);
                }
            }

            // If pending_approval drafts already exist for this session date, skip or adopt
            if (msg.session_date) {
                const dateKey = formatDateKey(msg.session_date.toDate());
                const existingDrafts = await db.collection("scheduled_messages")
                    .where("contract_id", "==", msg.contract_id)
                    .where("status", "==", "pending_approval")
                    .get();
                const hasDraft = existingDrafts.docs.some(d => {
                    const sd = d.data().session_date?.toDate();
                    return sd && formatDateKey(sd) === dateKey && d.id !== doc.id;
                });
                if (hasDraft) {
                    // Auto mode: absorb this pending doc into the approval queue
                    if (msg.auto_send_enabled !== false) {
                        await doc.ref.update({ status: "pending_approval", generated_at: now });
                    }
                    // Approval mode: skip — organizer already generated a draft for this date
                    continue;
                }
            }

            const result = await generateMessageContent(db, msg, roster, contractData);
            if (!result || result.skip) {
                await doc.ref.update({ status: "cancelled" });
                continue;
            }

            // Approval mode: store draft, do not send
            if (msg.auto_send_enabled === false) {
                if (msg.type === "lineup_publish" && result.sessionRef && result.assignment) {
                    await result.sessionRef.set({
                        id: formatDateKey(msg.session_date.toDate()),
                        date: msg.session_date,
                        assignment: result.assignment,
                        assignment_state: "draft",
                    }, { merge: true });
                }
                await doc.ref.update({
                    status: "pending_approval",
                    rendered_emails: result.renderedEmails,
                    generated_at: now,
                });
                continue;
            }

            // Auto mode: send immediately
            const { renderedEmails } = result;

            if (msg.type === "lineup_publish" && result.sessionRef && result.assignment) {
                const { assignment, confirmedPlayers, spotsNeeded, dateKey, sessionRef } = result;

                const sessionSnap = await sessionRef.get();
                const attendance = sessionSnap.exists ? (sessionSnap.data().attendance || {}) : {};
                const updatedAttendance = { ...attendance };
                const newRoster = [...roster];
                let rosterChanged = false;

                for (const [uid, status] of Object.entries(assignment)) {
                    const oldAtten = attendance[uid];
                    if (status === "confirmed") {
                        updatedAttendance[uid] = "played";
                        if (oldAtten !== "played" && oldAtten !== "charged") {
                            const pIdx = newRoster.findIndex(p => p.uid === uid);
                            if (pIdx !== -1) {
                                newRoster[pIdx] = { ...newRoster[pIdx], played_slots: (newRoster[pIdx].played_slots || 0) + 1 };
                                rosterChanged = true;
                            }
                        }
                    } else if (status === "reserve") {
                        updatedAttendance[uid] = "reserve";
                        if (oldAtten === "played" || oldAtten === "charged") {
                            const pIdx = newRoster.findIndex(p => p.uid === uid);
                            if (pIdx !== -1) {
                                newRoster[pIdx] = { ...newRoster[pIdx], played_slots: Math.max(0, (newRoster[pIdx].played_slots || 0) - 1) };
                                rosterChanged = true;
                            }
                        }
                    } else {
                        updatedAttendance[uid] = "out";
                        if (oldAtten === "played" || oldAtten === "charged") {
                            const pIdx = newRoster.findIndex(p => p.uid === uid);
                            if (pIdx !== -1) {
                                newRoster[pIdx] = { ...newRoster[pIdx], played_slots: Math.max(0, (newRoster[pIdx].played_slots || 0) - 1) };
                                rosterChanged = true;
                            }
                        }
                    }
                }

                await sessionRef.set({
                    id: dateKey,
                    date: msg.session_date,
                    assignment,
                    assignment_state: "published",
                    attendance: updatedAttendance,
                }, { merge: true });

                if (rosterChanged) {
                    await db.collection("contracts").doc(msg.contract_id).update({ roster: newRoster });
                }

                await Promise.all(renderedEmails.map(r =>
                    sendToUser(db, r.uid, r.subject, r.body, organizerEmail)
                ));

                if (spotsNeeded > 0) {
                    const outPlayers = roster.filter(p => assignment[p.uid] !== "confirmed");
                    if (outPlayers.length > 0) {
                        const subjectSub = `Sub needed — ${spotsNeeded} spot${spotsNeeded > 1 ? "s" : ""} open for ${dateKey}`;
                        await Promise.all(outPlayers.map(r => {
                            const baseUrl = msg.base_url || "https://www.adhoc-local.com";
                            const subLink = `${baseUrl}/#/session/${msg.contract_id}/${dateKey}/subin?uid=${encodeURIComponent(r.uid)}`;
                            const body = `Hi ${r.display_name || r.uid}, the lineup for ${dateKey} has ${spotsNeeded} open spot${spotsNeeded > 1 ? "s" : ""}. Claim it here: ${subLink}`;
                            return sendToUser(db, r.uid, subjectSub, body, organizerEmail);
                        }));
                        await db.collection("message_log").add({
                            sent_by: msg.organizer_id, sent_at: now, type: "sub_request",
                            subject: subjectSub, body: "Sub request for underfilled lineup",
                            recipients: outPlayers.map(p => ({ uid: p.uid, display_name: p.display_name })),
                            context_type: "contract", context_id: msg.contract_id,
                            delivery_count: outPlayers.length,
                            expire_at: firestore.Timestamp.fromMillis(now.toMillis() + 90 * 24 * 3600 * 1000),
                        });
                        await db.collection("scheduled_messages").add({
                            organizer_id: msg.organizer_id, contract_id: msg.contract_id,
                            type: "last_ditch", session_date: msg.session_date,
                            scheduled_for: firestore.Timestamp.fromMillis(now.toMillis() + 2 * 3600 * 1000),
                            status: "pending",
                            subject: "Still looking for players — can you help?",
                            body: `Hi {playerName}, we still need ${spotsNeeded} more player${spotsNeeded > 1 ? "s" : ""} for the ${dateKey} session. Claim the spot: {link}`,
                            recipients: roster.map(p => ({ uid: p.uid, display_name: p.display_name })),
                            recipients_filter: "all", auto_send_enabled: true,
                            base_url: msg.base_url || "https://www.adhoc-local.com",
                        });
                    }
                }

                await db.collection("message_log").add({
                    sent_by: msg.organizer_id, sent_at: now, type: "session_lineup",
                    subject: "Lineup published for your tennis session",
                    body: renderedEmails.length > 0 ? renderedEmails[0].body : "Lineup notification",
                    recipients: confirmedPlayers.map(p => ({ uid: p.uid, display_name: p.display_name })),
                    context_type: "contract", context_id: msg.contract_id,
                    delivery_count: confirmedPlayers.length,
                    expire_at: firestore.Timestamp.fromMillis(now.toMillis() + 90 * 24 * 3600 * 1000),
                });

            } else if (renderedEmails.length > 0) {
                await Promise.all(renderedEmails.map(r =>
                    sendToUser(db, r.uid, r.subject, r.body, organizerEmail)
                ));
                await db.collection("message_log").add({
                    sent_by: msg.organizer_id, sent_at: now, type: msg.type,
                    subject: msg.subject,
                    body: renderedEmails[0].body,
                    recipients: renderedEmails.map(r => ({ uid: r.uid, display_name: r.display_name })),
                    context_type: "contract", context_id: msg.contract_id,
                    delivery_count: renderedEmails.length,
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
// GENERATE SESSION MESSAGES — on-demand generation (trial run / pre-deadline)
// =============================================================================

exports.generateSessionMessages = onRequest({ cors: true }, async (req, res) => {
    res.set("Access-Control-Allow-Origin", req.headers.origin || "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }
    if (req.method !== "POST") { res.status(405).json({ error: "Method not allowed" }); return; }

    const { contractId, sessionDate, messageType } = req.body;
    if (!contractId || !sessionDate) {
        res.status(400).json({ error: "contractId and sessionDate are required" }); return;
    }

    const db = getFirestore();
    const now = firestore.Timestamp.now();

    const contractDoc = await db.collection("contracts").doc(contractId).get();
    if (!contractDoc.exists) { res.status(404).json({ error: "Contract not found" }); return; }
    const contractData = contractDoc.data();
    const roster = contractData.roster || [];

    // Fetch all scheduled_messages for this contract
    const allSnap = await db.collection("scheduled_messages")
        .where("contract_id", "==", contractId).get();

    // Collect pending and pending_approval docs for this date (both are valid source docs)
    const sourceDocs = [];
    const allKeys = [];
    for (const doc of allSnap.docs) {
        const d = doc.data();
        if (!d.session_date) continue;
        const key = formatDateKey(d.session_date.toDate());
        allKeys.push(`${key}(${d.status})`);
        if (key !== sessionDate) continue;
        if (d.status === "pending" || d.status === "pending_approval") {
            if (!messageType || d.type === messageType) sourceDocs.push(doc);
        }
    }
    logger.info(`generateSessionMessages: contract=${contractId} requested=${sessionDate} allDocs=[${allKeys.join(",")}] found=${sourceDocs.length}`);
    const pendingDocs = sourceDocs; // alias kept for code below

    // Reset session assignment_state from 'draft' back to 'none' (will be recomputed below)
    const sessionRef = db.collection("contracts").doc(contractId)
        .collection("sessions").doc(sessionDate);
    const sessionSnap = await sessionRef.get();
    if (sessionSnap.exists && sessionSnap.data().assignment_state === "draft") {
        await sessionRef.update({ assignment_state: "none" });
    }

    if (pendingDocs.length === 0) {
        res.status(404).json({ error: `No scheduled messages found for ${sessionDate}. Keys found: ${allKeys.join(", ")}` }); return;
    }

    const updateBatch = db.batch();
    let generatedCount = 0;
    for (const doc of pendingDocs) {
        const msg = doc.data();
        const result = await generateMessageContent(db, msg, roster, contractData);
        // On-demand generation: skip silently (don't cancel) so the doc stays for future runs
        if (!result || result.skip) continue;
        if (msg.type === "lineup_publish" && result.assignment) {
            await sessionRef.set({
                id: sessionDate, date: msg.session_date,
                assignment: result.assignment, assignment_state: "draft",
            }, { merge: true });
        }
        updateBatch.update(doc.ref, {
            status: "pending_approval",
            rendered_emails: result.renderedEmails,
            generated_at: now,
        });
        generatedCount++;
    }
    await updateBatch.commit();

    res.status(200).json({ success: true, count: generatedCount });
});

// =============================================================================
// SEND APPROVED MESSAGES — sends stored rendered_emails for a session date
// =============================================================================

exports.sendApprovedMessages = onRequest({ cors: true }, async (req, res) => {
    res.set("Access-Control-Allow-Origin", req.headers.origin || "*");
    res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    res.set("Access-Control-Allow-Headers", "Content-Type");
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }
    if (req.method !== "POST") { res.status(405).json({ error: "Method not allowed" }); return; }

    const { contractId, sessionDate, messageType } = req.body;
    if (!contractId || !sessionDate) {
        res.status(400).json({ error: "contractId and sessionDate are required" }); return;
    }

    const db = getFirestore();
    const now = firestore.Timestamp.now();

    const contractDoc = await db.collection("contracts").doc(contractId).get();
    if (!contractDoc.exists) { res.status(404).json({ error: "Contract not found" }); return; }
    const contractData = contractDoc.data();
    const roster = contractData.roster || [];

    let organizerEmail = null;
    try {
        const orgDoc = await db.collection("users").doc(contractData.organizer_id).get();
        if (orgDoc.exists) organizerEmail = orgDoc.data().email || null;
    } catch (_) { }

    const approvalSnap = await db.collection("scheduled_messages")
        .where("contract_id", "==", contractId)
        .where("status", "==", "pending_approval").get();

    const sessionDocs = approvalSnap.docs.filter(d => {
        const sd = d.data().session_date?.toDate();
        return sd && formatDateKey(sd) === sessionDate
            && (!messageType || d.data().type === messageType);
    });

    if (sessionDocs.length === 0) {
        res.status(404).json({ error: "No pending_approval messages found for this session date" }); return;
    }

    let sentCount = 0;
    for (const doc of sessionDocs) {
        const msg = doc.data();
        const renderedEmails = msg.rendered_emails || [];
        try {
            if (msg.type === "lineup_publish") {
                const sessionRef = db.collection("contracts").doc(contractId)
                    .collection("sessions").doc(sessionDate);
                const snap = await sessionRef.get();
                const assignment = snap.exists ? (snap.data().assignment ?? {}) : {};
                const attendance = snap.exists ? (snap.data().attendance ?? {}) : {};
                const spotsPerSession = (contractData.courts_count ?? 1) * 4;
                const confirmedPlayers = roster.filter(p => assignment[p.uid] === "confirmed");
                const confirmedCount = confirmedPlayers.length;

                const updatedAttendance = { ...attendance };
                const newRoster = [...roster];
                let rosterChanged = false;

                for (const [uid, status] of Object.entries(assignment)) {
                    const oldAtten = attendance[uid];
                    if (status === "confirmed") {
                        updatedAttendance[uid] = "played";
                        if (oldAtten !== "played" && oldAtten !== "charged") {
                            const pIdx = newRoster.findIndex(p => p.uid === uid);
                            if (pIdx !== -1) {
                                newRoster[pIdx] = { ...newRoster[pIdx], played_slots: (newRoster[pIdx].played_slots || 0) + 1 };
                                rosterChanged = true;
                            }
                        }
                    } else if (status === "reserve") {
                        updatedAttendance[uid] = "reserve";
                        if (oldAtten === "played" || oldAtten === "charged") {
                            const pIdx = newRoster.findIndex(p => p.uid === uid);
                            if (pIdx !== -1) {
                                newRoster[pIdx] = { ...newRoster[pIdx], played_slots: Math.max(0, (newRoster[pIdx].played_slots || 0) - 1) };
                                rosterChanged = true;
                            }
                        }
                    } else {
                        updatedAttendance[uid] = "out";
                        if (oldAtten === "played" || oldAtten === "charged") {
                            const pIdx = newRoster.findIndex(p => p.uid === uid);
                            if (pIdx !== -1) {
                                newRoster[pIdx] = { ...newRoster[pIdx], played_slots: Math.max(0, (newRoster[pIdx].played_slots || 0) - 1) };
                                rosterChanged = true;
                            }
                        }
                    }
                }

                await sessionRef.update({
                    assignment_state: "published",
                    attendance: updatedAttendance,
                });

                if (rosterChanged) {
                    await db.collection("contracts").doc(contractId).update({ roster: newRoster });
                }
                const r = renderedEmails[0];
                if (r) {
                    const recipientUids = new Set((msg.recipients || []).map(rec => rec.uid));
                    const emailLookups = await Promise.all(roster.map(async p => {
                        if (!recipientUids.has(p.uid)) return null;

                        try {
                            const userDoc = await db.collection("users").doc(p.uid).get();
                            if (!userDoc.exists) return null;
                            const data = userDoc.data();
                            if (data.notif_active === false) return null;
                            const email = data.email ||
                                (data.primary_contact?.includes?.("@") ? data.primary_contact : null);
                            return email || null;
                        } catch (_) { return null; }
                    }));
                    const toAddresses = emailLookups.filter(Boolean);
                    if (toAddresses.length > 0) {
                        const htmlBody = `<p>${r.body.replace(/\n/g, "<br/>")}</p>`;
                        await db.collection("mail").add({
                            to: toAddresses,
                            message: { subject: r.subject, text: r.body, html: htmlBody },
                            ...(organizerEmail ? { reply_to: organizerEmail } : {}),
                        });
                        sentCount += toAddresses.length;
                    }
                }

                if (confirmedCount < spotsPerSession) {
                    const spotsNeeded = spotsPerSession - confirmedCount;
                    const outPlayers = roster.filter(p => assignment[p.uid] !== "confirmed");
                    if (outPlayers.length > 0) {
                        const subjectSub = `Sub needed — ${spotsNeeded} spot${spotsNeeded > 1 ? "s" : ""} open for ${sessionDate}`;
                        await Promise.all(outPlayers.map(r => {
                            const baseUrl = msg.base_url || "https://www.adhoc-local.com";
                            const subLink = `${baseUrl}/#/session/${contractId}/${sessionDate}/subin?uid=${encodeURIComponent(r.uid)}`;
                            const body = `Hi ${r.display_name || r.uid}, the lineup for ${sessionDate} has ${spotsNeeded} open spot${spotsNeeded > 1 ? "s" : ""}. Claim it here: ${subLink}`;
                            return sendToUser(db, r.uid, subjectSub, body, organizerEmail);
                        }));
                        await db.collection("message_log").add({
                            sent_by: contractData.organizer_id, sent_at: now, type: "sub_request",
                            subject: subjectSub, body: "Sub request for underfilled lineup",
                            recipients: outPlayers.map(p => ({ uid: p.uid, display_name: p.display_name })),
                            context_type: "contract", context_id: contractId,
                            delivery_count: outPlayers.length,
                            expire_at: firestore.Timestamp.fromMillis(now.toMillis() + 90 * 24 * 3600 * 1000),
                        });
                        await db.collection("scheduled_messages").add({
                            organizer_id: contractData.organizer_id, contract_id: contractId,
                            type: "last_ditch", session_date: msg.session_date,
                            scheduled_for: firestore.Timestamp.fromMillis(now.toMillis() + 2 * 3600 * 1000),
                            status: "pending",
                            subject: "Still looking for players — can you help?",
                            body: `Hi {playerName}, we still need ${spotsNeeded} more player${spotsNeeded > 1 ? "s" : ""} for the ${sessionDate} session. Claim the spot: {link}`,
                            recipients: roster.map(p => ({ uid: p.uid, display_name: p.display_name })),
                            recipients_filter: "all",
                            auto_send_enabled: contractData.notification_mode !== "manual",
                            base_url: msg.base_url || "https://www.adhoc-local.com",
                        });
                    }
                }
                await db.collection("message_log").add({
                    sent_by: contractData.organizer_id, sent_at: now, type: "session_lineup",
                    subject: "Lineup published for your tennis session",
                    body: renderedEmails.length > 0 ? renderedEmails[0].body : "Lineup notification",
                    recipients: confirmedPlayers.map(p => ({ uid: p.uid, display_name: p.display_name })),
                    context_type: "contract", context_id: contractId,
                    delivery_count: confirmedPlayers.length,
                    expire_at: firestore.Timestamp.fromMillis(now.toMillis() + 90 * 24 * 3600 * 1000),
                });

            } else if (renderedEmails.length > 0) {
                await Promise.all(renderedEmails.map(r =>
                    sendToUser(db, r.uid, r.subject, r.body, organizerEmail)
                ));
                sentCount += renderedEmails.length;
                await db.collection("message_log").add({
                    sent_by: contractData.organizer_id, sent_at: now, type: msg.type,
                    subject: msg.subject, body: renderedEmails[0].body,
                    recipients: renderedEmails.map(r => ({ uid: r.uid, display_name: r.display_name })),
                    context_type: "contract", context_id: contractId,
                    delivery_count: renderedEmails.length,
                    expire_at: firestore.Timestamp.fromMillis(now.toMillis() + 90 * 24 * 3600 * 1000),
                });
            }

            await doc.ref.update({ status: "sent", sent_at: now });
        } catch (e) {
            logger.error(`sendApprovedMessages: failed to send doc ${doc.id}`, e);
        }
    }
    res.status(200).json({ success: true, count: sentCount });
});

// =============================================================================
// DROPOUT CASCADE — fires when a session's assignment map changes
// =============================================================================

exports.onSessionAssignmentChange = onDocumentUpdated(
    "contracts/{contractId}/sessions/{sessionDate}",
    async (event) => {
        const before = event.data.before.data() ?? {};
        const after = event.data.after.data() ?? {};
        const { contractId, sessionDate } = event.params;

        const beforeAssign = before.assignment ?? {};
        const afterAssign = after.assignment ?? {};

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
                                const subLink = `https://www.adhoc-local.com/#/session/${contractId}/${sessionDate}/subin?uid=${encodeURIComponent(r.uid)}`;
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
                        const manageLink = `https://www.adhoc-local.com/#/session/${contractId}/${sessionDate}/manage?uid=${encodeURIComponent(r.uid)}`;
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