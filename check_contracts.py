import firebase_admin
from firebase_admin import credentials, firestore

cred = credentials.Certificate('ServiceAccountKey.json')
firebase_admin.initialize_app(cred)

db = firestore.client()

contracts = db.collection('contracts').get()
for c in contracts:
    data = c.to_dict()
    print(f"Contract ID: {c.id}")
    print(f"Organizer ID: {data.get('organizer_id')}")
    print(f"Club Name: {data.get('club_name')}")
    print(f"Roster UIDs: {data.get('roster_uids')}")
    print("---")

users = db.collection('users').get()
for u in users:
    data = u.to_dict()
    if data and 'Kiran Mundy' in data.get('display_name', ''):
        print(f"User ID: {u.id}, Name: {data.get('display_name')}")
