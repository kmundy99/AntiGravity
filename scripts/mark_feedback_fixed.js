const https = require('https');

const databaseUrl = 'https://firestore.googleapis.com/v1/projects/tennis-app-mp-2026/databases/(default)/documents/feedbacks';

async function fetchFeedbacks() {
    return new Promise((resolve, reject) => {
        https.get(databaseUrl, (res) => {
            let data = '';
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    resolve(JSON.parse(data));
                } else {
                    reject(new Error(`Failed to fetch: ${res.statusCode} ${data}`));
                }
            });
        }).on('error', reject);
    });
}

async function updateFeedback(docName, fields) {
    const url = `https://firestore.googleapis.com/v1/${docName}?updateMask.fieldPaths=status`;

    const body = JSON.stringify({
        name: docName,
        fields: {
            ...fields,
            status: { stringValue: 'fixed' }
        }
    });

    const options = {
        method: 'PATCH',
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(body)
        }
    };

    return new Promise((resolve, reject) => {
        const req = https.request(url, options, (res) => {
            let data = '';
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    resolve(JSON.parse(data));
                } else {
                    reject(new Error(`Failed to update ${docName}: ${res.statusCode} ${data}`));
                }
            });
        });

        req.on('error', reject);
        req.write(body);
        req.end();
    });
}

async function markAllFixed() {
    try {
        console.log('Fetching feedbacks...');
        const data = await fetchFeedbacks();
        const docs = data.documents;

        if (!docs || docs.length === 0) {
            console.log('No feedbacks found.');
            return;
        }

        const toUpdate = docs.filter(doc => !doc.fields.status || doc.fields.status.stringValue !== 'fixed');

        if (toUpdate.length === 0) {
            console.log('All feedbacks are already marked as fixed.');
            return;
        }

        console.log(`Found ${toUpdate.length} feedbacks to mark as fixed. Updating...`);

        let successCount = 0;
        let failCount = 0;

        for (const doc of toUpdate) {
            try {
                await updateFeedback(doc.name, doc.fields);
                successCount++;
                process.stdout.write(`\rUpdated ${successCount}/${toUpdate.length}`);
            } catch (e) {
                failCount++;
                console.error(`\nFailed to update ${doc.name}:`, e.message);
            }
        }

        console.log(`\nDone! Successfully updated ${successCount}. Failed to update ${failCount}.`);

    } catch (e) {
        console.error('An error occurred:', e.message);
    }
}

markAllFixed();
