const admin = require('firebase-admin');
const serviceAccount = require("./ServiceAccountKey.json");

try {
    if (!admin.apps.length) {
        admin.initializeApp({
            credential: admin.credential.cert(serviceAccount)
        });
    }
} catch (e) { console.error("init error", e); }

const db = admin.firestore();

async function getFeedback() {
    try {
        const feedbackSnapshot = await db.collection('feedbacks').orderBy('createdAt', 'desc').limit(5).get();
        if (feedbackSnapshot.empty) {
            console.log("No feedback found.");
            return;
        }
        feedbackSnapshot.forEach((doc) => {
            const data = doc.data();
            const date = data.createdAt ? data.createdAt.toDate().toLocaleString() : 'No Date';
            console.log(`\n--- [${data.type || 'N/A'}] - ${data.displayName || 'Unknown User'} - ${date} ---`);
            console.log(`${data.description}`);
            if (data.aiResponse) {
                console.log(`AI: ${data.aiResponse}`);
            }
            if (data.screenContext) {
                console.log(`Screen: ${data.screenContext}`);
            }
        });
    } catch (e) {
        console.error(e);
    }
}
getFeedback();
