# python3 tools/gdpr_import.py --export-file=/tmp/export.json --chat-id=-100123456789 [--markovdb=/path/to/markov.db] [--session-name="Imported session"]

import argparse
import datetime
import sqlite3
import traceback
import uuid
from pathlib import Path

import orjson
from rich.console import Console
from rich.progress import Progress

root = Path(__file__).parent.parent

parser = argparse.ArgumentParser(
    description="Import messages from a GDPR export into a new session"
)
parser.add_argument(
    "--export-file",
    type=Path,
    required=True,
    help="The GDPR export file to import",
)
parser.add_argument(
    "--chat-id",
    type=int,
    required=True,
    help="The chat id where the session will be created",
)
parser.add_argument(
    "--markovdb",
    type=Path,
    default=root / "data" / "markov.db",
    help="The path to the markov database",
)
parser.add_argument(
    "--session-name",
    type=str,
    help="Optional name for the new session",
)
args = parser.parse_args()

console = Console()

export_file = args.export_file
chat_id = args.chat_id
markovdb = args.markovdb
session_name = args.session_name

if not export_file.exists():
    console.print(f"[red]Export file not found: {export_file}[/red]")
    exit(1)


if not markovdb.exists():
    console.print(f"[red]Database not found: {markovdb}[/red]")
    exit(1)


try:
    export_data = orjson.loads(export_file.read_bytes())
except Exception:
    console.print("[red]Failed to read export file[/red]")
    console.print(traceback.format_exc())
    exit(1)


export_type = export_data.get("export_type", "user")
export_chat_id = export_data.get("chat_id")

users_info = {
    int(user.get("user_id")): {
        "banned": bool(user.get("banned", False)),
        "consented": bool(user.get("consented", True)),
    }
    for user in export_data.get("users", [])
    if user.get("user_id") is not None
}


messages = []
first_session_name = None

for chat in export_data.get("chats", []):
    for session in chat.get("sessions", []):
        if first_session_name is None and session.get("session_name"):
            first_session_name = session["session_name"]

        for message in session.get("messages", []):
            text = message.get("text")
            sender_user_id = message.get("sender_user_id")
            if sender_user_id is None:
                sender_user_id = export_data.get("user_id")
            message_id = message.get("id", 0)
            if text is None or sender_user_id is None:
                continue
            messages.append(
                {
                    "id": int(message_id),
                    "text": text,
                    "sender_user_id": int(sender_user_id),
                }
            )


if not messages:
    console.print("[yellow]No messages found in export; nothing to import[/yellow]")
    exit(0)


messages.sort(key=lambda m: m["id"])

if session_name is None:
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    prefix = "Imported session" if export_type != "user" else "Imported user session"
    if first_session_name:
        session_name = f"Imported {first_session_name} ({timestamp})"
    else:
        session_name = f"{prefix} ({timestamp})"


console.print(
    f"[bold green]Importing {len(messages)} messages into chat {chat_id} (export type: {export_type})[/bold green]"
)

if export_type == "chat" and export_chat_id is not None and export_chat_id != chat_id:
    console.print(
        f"[yellow]Warning: export chat_id ({export_chat_id}) differs from target chat_id ({chat_id}). Proceeding anyway.[/yellow]"
    )


try:
    with sqlite3.connect(markovdb, timeout=30, isolation_level=None) as conn:
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("BEGIN IMMEDIATE")

        cursor = conn.cursor()

        chat_row = cursor.execute(
            "SELECT id FROM chats WHERE chatId = ?", (chat_id,)
        ).fetchone()

        if chat_row is None:
            console.print(f"[red]Chat not found: {chat_id}[/red]")
            conn.rollback()
            exit(1)

        internal_chat_id = chat_row["id"]

        user_cache: dict[int, int] = {}

        def get_internal_user(sender_user_id: int) -> int:
            if sender_user_id in user_cache:
                return user_cache[sender_user_id]

            info = users_info.get(sender_user_id, {"banned": False, "consented": True})

            existing = cursor.execute(
                "SELECT id FROM users WHERE userId = ?", (sender_user_id,)
            ).fetchone()

            if existing is None:
                cursor.execute(
                    "INSERT INTO users (userId, admin, banned, consented) VALUES (?, 0, ?, ?)",
                    (sender_user_id, int(info["banned"]), int(info["consented"])),
                )
                internal_id = cursor.lastrowid
            else:
                internal_id = existing["id"]
                cursor.execute(
                    "UPDATE users SET banned = ?, consented = ? WHERE userId = ?",
                    (int(info["banned"]), int(info["consented"]), sender_user_id),
                )

            user_cache[sender_user_id] = internal_id
            return internal_id

        cursor.execute(
            """
            INSERT INTO sessions (
                name, uuid, chat, isDefault, owoify, emojipasta, caseSensitive, alwaysReply, randomReplies, learningPaused
            ) VALUES (?, ?, ?, 0, 0, 0, 1, 0, 0, 0)
            """,
            (session_name, uuid.uuid4().hex, internal_chat_id),
        )

        new_session_id = cursor.lastrowid

        last_message_id = cursor.execute(
            "SELECT COALESCE(MAX(id), 0) AS max_id FROM messages"
        ).fetchone()["max_id"]

        with Progress() as progress:
            task = progress.add_task("Importing messages", total=len(messages))

            for message in messages:
                last_message_id += 1
                sender_internal_id = get_internal_user(message["sender_user_id"])
                cursor.execute(
                    "INSERT INTO messages (id, session, sender, text) VALUES (?, ?, ?, ?)",
                    (last_message_id, new_session_id, sender_internal_id, message["text"]),
                )
                progress.update(task, advance=1)

        conn.commit()
        console.print(
            f"[bold green]Imported {len(messages)} messages into session '{session_name}' (id: {new_session_id})[/bold green]"
        )
except sqlite3.OperationalError:
    console.print("[red]Failed to import messages due to a database error[/red]")
    console.print(traceback.format_exc())
    exit(1)
except Exception:
    console.print("[red]Unexpected error while importing messages[/red]")
    console.print(traceback.format_exc())
    exit(1)
