# Small utility script to clean the redundant messages
# from the database, and vacuum it, to make it smaller
# and faster.

import re
import os

import sqlite3

from pathlib import Path
from collections import defaultdict

root = Path(__file__).parent.parent
file = root / "data" / "markov.db"
env = root / ".env"

KEEP_LAST_RE = re.compile(r"^KEEP_LAST\s*=\s*(\d+)")
KEEP_LAST = os.environ.get("KEEP_LAST", None)

if KEEP_LAST is None and env.exists():
    with env.open() as f:
        for line in f:
            m = KEEP_LAST_RE.match(line)
            if m:
                KEEP_LAST = int(m.group(1))
                break

if KEEP_LAST is None:
    # Fall back to default
    KEEP_LAST = 12000  # messages

with sqlite3.connect(file) as conn:
    count = conn.cursor().execute("SELECT COUNT(1) FROM messages").fetchone()[0]
    print(f"Fetching {count} messages...")
    all_messages = conn.cursor().execute("SELECT session, id FROM messages").fetchall()
    session_messages = defaultdict(set)

    for message in all_messages:
        session, mid = message
        session_messages[session].add(mid)

    print("Cleaning messages...")

    cur = conn.cursor()
    for session, messages in session_messages.items():
        to_delete = sorted(messages, reverse=True)[KEEP_LAST:]
        print(f"Deleting {len(to_delete)} messages in session={session}...")
        for mid in to_delete:
            cur.execute("DELETE FROM messages WHERE id = ?", (mid,))

    conn.commit()

    print("vacuum")
    conn.execute("VACUUM")
    conn.commit()

print("done")
