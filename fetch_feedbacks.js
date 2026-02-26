fetch("https://firestore.googleapis.com/v1/projects/tennis-app-mp-2026/databases/(default)/documents/feedbacks")
    .then(r => r.json())
    .then(data => {
        const docs = data.documents;
        if (!docs) return console.log("No feedback found");
        docs.sort((a, b) => {
            const dateA = a.fields.createdAt?.timestampValue || "";
            const dateB = b.fields.createdAt?.timestampValue || "";
            return dateA.localeCompare(dateB);
        });
        const formatted = docs.map((d, i) => {
            const fields = d.fields;
            const desc = fields.description?.stringValue || "N/A";
            const type = fields.type?.stringValue || "N/A";
            const date = fields.createdAt?.timestampValue ? new Date(fields.createdAt.timestampValue).toLocaleString() : "N/A";
            const location = fields.screenContext?.stringValue || "N/A";
            return `${i + 1}. [${type}] - ${date}\n   Location: ${location}\n   Description: ${desc}`;
        });
        console.log(formatted.join('\n\n'));
    });
