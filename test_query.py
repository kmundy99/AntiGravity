import firebase_admin
from firebase_admin import credentials, firestore

cred = credentials.Certificate('ServiceAccountKey.json')
firebase_admin.initialize_app(cred)
db = firestore.client()

print("Fetching user Kiran Mundy")
users = db.collection('users').get()
for u in users:
    data = u.to_dict()
    if data and 'Kiran' in data.get('display_name', ''):
        print(f"ID: {u.id}, Name: {data.get('display_name')}, phone: {data.get('phone_number')}, contact: {data.get('primary_contact')}, email: {data.get('email')}")

print("Fetching contracts")
contracts = db.collection('contracts').get()
for c in contracts:
    data = c.to_dict()
    print(f"Contract {c.id} Org: {data.get('organizer_id')} Roster: {data.get('roster_uids')}")
