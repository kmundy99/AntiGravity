const admin = require('firebase-admin');

try {
    const serviceAccount = require("./functions-service-key.json");
    admin.initializeApp({
        credential: admin.credential.cert(serviceAccount)
    });
} catch (e) {
    try {
        admin.initializeApp();
    } catch (e2) { }
}

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
            let typeString = data.type || (data.isBug ? 'Bug' : 'Idea');
            console.log(`\n--- [${typeString}] - ${date} ---`);
            console.log(data.text);
            console.log(`Document ID: ${doc.id}`);
        });
    } catch (e) {
        console.error(e);
    }
}
getFeedback();
