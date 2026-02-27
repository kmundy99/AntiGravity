import firebase_admin
from firebase_admin import credentials, firestore

cred = credentials.Certificate('/home/kiranmundy/AntiGravity_Tennis_App/antigravity-36100-firebase-adminsdk-jly0f-f44e138acc.json')
firebase_admin.initialize_app(cred)
db = firestore.client()

docs = db.collection('users').get()
for doc in docs:
    data = doc.to_dict()
    name = data.get('display_name')
    if name in ['Kix', 'Bookings', 'Woburn Racquet', 'Winchester Indoor']:
        print(f"ID: {doc.id} | Name: {name} | Email: {data.get('email', 'N/A')} | Phone: {data.get('primary_contact', 'N/A')} | Status: {data.get('accountStatus')}")
