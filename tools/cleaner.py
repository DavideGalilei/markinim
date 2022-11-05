# Small utility script to clean the redundant messages
# from the database, and vacuum it, to make it smaller
# and faster.

import sqlite3

from pathlib import Path

file = Path(__file__).parent / "data" / "markov.db"

with sqlite3.connect(file) as conn:
    cur = conn.cursor()
    for session_id in cur.execute("SELECT id FROM sessions").fetchall():
        cur.execute("DELETE FROM messages WHERE messages.session = ? AND id NOT IN (SELECT id FROM messages WHERE messages.session = ? ORDER BY id DESC LIMIT 1500)", session_id * 2)
        print(session_id)

    conn.commit()

    print("vacuum")
    conn.execute("VACUUM")
    conn.commit()

print("done")
