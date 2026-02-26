const admin = require('firebase-admin');
var serviceAccount = require("./functions/functions-service-key.json");

try {
    admin.initializeApp({
        credential: admin.credential.cert(serviceAccount)
    });
} catch (e) { }

const db = admin.firestore();

async function getFeedback() {
    try {
        const feedbackSnapshot = await db.collection('feedbacks').orderBy('timestamp', 'asc').get();
        if (feedbackSnapshot.empty) {
            console.log("No feedback found.");
            return;
        }
        feedbackSnapshot.forEach((doc) => {
            const data = doc.data();
            const date = data.timestamp ? data.timestamp.toDate().toLocaleString() : 'No Date';
            console.log(`\n--- [${data.type || 'N/A'}] - ${date} ---`);
            console.log(data.text);
        });
    } catch (e) {
        console.error(e);
    }
}
getFeedback();
