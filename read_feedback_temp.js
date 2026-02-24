const admin = require('firebase-admin');
var serviceAccount = require("./functions/functions-service-key.json"); 

try {
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount)
  });
} catch(e) {
  // Ignore if already initialized
}

const db = admin.firestore();

async function getFeedback() {
    try {
        const feedbackSnapshot = await db.collection('feedbacks').orderBy('timestamp', 'desc').limit(2).get();
        if (feedbackSnapshot.empty) {
            console.log("No feedback found.");
            return;
        }
        feedbackSnapshot.forEach((doc) => {
            const data = doc.data();
            console.log("BUG REPORT:", data.text);
        });
    } catch(e) {
        console.error(e);
    }
}
getFeedback();
