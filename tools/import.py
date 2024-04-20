# Small utility script to import the messages from a CSV file
# into the database. The CSV file should have the following
# columns:
# session | sender | text
# session: int (the session id)
# sender: int (the sender's id)
# text: str (the message text)

import argparse
import csv
import sqlite3
import traceback
from dataclasses import dataclass
from pathlib import Path

root = Path(__file__).parent.parent
markovdb = root / "data" / "markov.db"
env = root / ".env"

parser = argparse.ArgumentParser(
    description="Import messages from a CSV file into the database"
)
parser.add_argument("file", type=Path, help="The CSV file to import")
args = parser.parse_args()

csv_file = args.file
if not csv_file.exists():
    print(f"File not found: {csv_file}")
    exit(1)


@dataclass
class Message:
    session: int
    sender: int
    text: str


messages: list[Message] = []
session_id: int | None = None

with csv_file.open() as f:
    reader = csv.DictReader(f)
    for row in reader:
        if session_id is None:
            session_id = int(row["session"])

        assert session_id == int(
            row["session"]
        ), "All messages should belong to the same session"

        messages.append(
            Message(
                session=int(row["session"]),
                sender=int(row["sender"]),
                text=row["text"],
            )
        )


with sqlite3.connect(markovdb) as conn:
    try:
        last_message_id = (
            conn.cursor().execute("SELECT MAX(id) FROM messages").fetchone()[0]
        )
        if last_message_id is None:
            print("No messages found in the database")
            exit(1)

        print(f"Last message id: {last_message_id}")

        print(f"Inserting {len(messages)} messages...")
        cur = conn.cursor()

        for message in messages:
            last_message_id += 1
            cur.execute(
                "INSERT INTO messages (id, session, sender, text) VALUES (?, ?, ?, ?)",
                (last_message_id, message.session, message.sender, message.text),
            )

        conn.commit()
    except sqlite3.OperationalError:
        traceback.print_exc()

print("done")
