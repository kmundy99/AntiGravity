const admin = require('firebase-admin');
var serviceAccount = require("./functions/serviceAccountKey.json");

if (!serviceAccount) {
    console.log("No service account json found, relying on default credentials");
    admin.initializeApp();
} else {
    admin.initializeApp({
        credential: admin.credential.cert(serviceAccount)
    });
}

const db = admin.firestore();

async function checkCollections() {
    console.log("Checking mail collection for 'Player Dropped Out' subject...");
    const mailSnapshot = await db.collection('mail')
        .orderBy('delivery.startTime', 'desc')
        .limit(5)
        .get();

    mailSnapshot.forEach(doc => {
        console.log(doc.id, '=>', doc.data());
    });

    console.log("Checking messages collection...");
    const msgSnapshot = await db.collection('messages')
        .limit(5)
        .get();

    msgSnapshot.forEach(doc => {
        console.log(doc.id, '=>', doc.data());
    });
}

checkCollections().catch(console.error);
