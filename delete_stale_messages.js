const admin = require('firebase-admin');
var serviceAccount = require("./ServiceAccountKey.json");

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount)
});

const db = admin.firestore();

async function deleteMessages() {
  console.log('Retrieving scheduled requests...');
  const snapshot = await db.collection('scheduled_messages').where('type', '==', 'general_availability_request').get();
  console.log(`Found ${snapshot.docs.length} messages.`);
  
  const batch = db.batch();
  snapshot.docs.forEach(doc => {
    batch.delete(doc.ref);
  });
  
  await batch.commit();
  console.log('Deleted old availability requests.');
  process.exit(0);
}

deleteMessages().catch(console.error);
