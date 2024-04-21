# python3 tools/gdpr_export.py --user-id=12345678 --output-dir=/tmp/export [--markovdb=/path/to/markov.db]

import argparse
import datetime
import sqlite3
import traceback
from pathlib import Path

import orjson
from pydantic import BaseModel
from rich.console import Console
from rich.progress import Progress

"""
{
    "export_date": "2021-10-01T00:00:00Z",
    "user_id": 12345678,
    "banned": false,
    "consented": true,
    "total_messages": 2,
    "chats": [
        {
            "chat_id": -100123456789,
            "sessions": [
                {
                    "session_id": 12345678,
                    "session_name": "My Chat",
                    "messages": [
                        {
                            "id": 1,
                            "text": "Hello, world!"
                        },
                        {
                            "id": 2,
                            "text": "Hello, world!"
                        }
                    ]
                }
            ]
        }
    ]
}
"""

"""
database schema:
CREATE TABLE "chats"(chatId INTEGER NOT NULL UNIQUE, enabled INTEGER NOT NULL, percentage INTEGER NOT NULL, premium INTEGER NOT NULL, banned INTEGER NOT NULL, blockLinks INTEGER NOT NULL, blockUsernames INTEGER NOT NULL, keepSfw INTEGER NOT NULL, markovDisabled INTEGER NOT NULL, quotesDisabled INTEGER NOT NULL, id INTEGER NOT NULL PRIMARY KEY, pollsDisabled INTEGER NOT NULL DEFAULT 1)
CREATE TABLE "messages"(session INTEGER NOT NULL, sender INTEGER NOT NULL, text TEXT NOT NULL, id INTEGER NOT NULL PRIMARY KEY, FOREIGN KEY(session) REFERENCES "sessions"(id) ON DELETE CASCADE, FOREIGN KEY(sender) REFERENCES "users"(id))
CREATE TABLE "sessions"(name TEXT NOT NULL, uuid TEXT NOT NULL UNIQUE, chat INTEGER NOT NULL, isDefault INTEGER NOT NULL, owoify INTEGER NOT NULL, emojipasta INTEGER NOT NULL, caseSensitive INTEGER NOT NULL, alwaysReply INTEGER NOT NULL, id INTEGER NOT NULL PRIMARY KEY, randomReplies INTEGER NOT NULL DEFAULT 0, learningPaused INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(chat) REFERENCES "chats"(id) ON DELETE CASCADE)
CREATE TABLE "users"(userId INTEGER NOT NULL UNIQUE, admin INTEGER NOT NULL, banned INTEGER NOT NULL, id INTEGER NOT NULL PRIMARY KEY, consented INTEGER NOT NULL DEFAULT 0)
"""

root = Path(__file__).parent.parent

parser = argparse.ArgumentParser(description="Export messages from the database")
parser.add_argument("--user-id", type=int, required=True, help="The user id to export")
parser.add_argument(
    "--output-file",
    type=Path,
    required=True,
    help="The output file to write the export to",
)
parser.add_argument(
    "--markovdb",
    type=Path,
    default=root / "data" / "markov.db",
    help="The path to the markov database",
)
args = parser.parse_args()

console = Console()

output_file = args.output_file
output_dir = output_file.parent
markovdb = args.markovdb
if not output_dir.exists() or not output_dir.is_dir():
    console.print(f"[red]Directory not found: {output_dir}[/red]")
    exit(1)


if not markovdb.exists():
    console.print(f"[red]Database not found: {markovdb}[/red]")
    exit(1)


ChatId = int
InternalChatId = int
SessionId = int
InternalMessageId = int
UserId = int


class Message(BaseModel):
    id: InternalMessageId
    text: str


class Session(BaseModel):
    session_id: SessionId
    session_name: str
    deleted: bool
    messages: list[Message]


class Chat(BaseModel):
    chat_id: ChatId
    sessions: list[Session]


class ExportData(BaseModel):
    export_date: datetime.datetime
    user_id: UserId
    banned: bool
    consented: bool
    total_chats: int
    total_messages: int
    chats: list[Chat]


with sqlite3.connect(markovdb) as conn:
    # enable row factory to access columns by name
    conn.row_factory = sqlite3.Row

    try:
        # get user
        user_id: UserId = args.user_id
        user = conn.execute(
            "SELECT * FROM users WHERE userId = ?", (user_id,)
        ).fetchone()

        if user is None:
            console.print(f"[red]User not found: {user_id}[/red]")
            exit(1)

        # get messages count
        total_messages = conn.execute(
            "SELECT COUNT(*) AS total_messages FROM messages WHERE sender = ?",
            (user["id"],),
        ).fetchone()["total_messages"]

        console.print(
            f"[bold green]Exporting {total_messages} messages for user {user_id}...[/bold green]"
        )

        with Progress() as progress:
            task = progress.add_task("Exporting messages...", total=total_messages)

            messages_sent_by_user = conn.execute(
                "SELECT * FROM messages WHERE sender = ?", (user["id"],)
            )

            cached_chats: dict[InternalChatId, Chat] = {}
            cached_sessions: dict[SessionId, Session] = {}
            session_internal_chat_ids: dict[SessionId, InternalChatId] = {}

            while True:
                messages_sent_by_user_chunk = messages_sent_by_user.fetchmany(1000)
                if not messages_sent_by_user_chunk:
                    break

                for message in messages_sent_by_user_chunk:
                    progress.update(task, advance=1)
                    session_id: SessionId = message["session"]

                    if session_id not in cached_sessions:
                        this_session = conn.execute(
                            "SELECT * FROM sessions WHERE id = ?", (session_id,)
                        ).fetchone()

                        cached_sessions[session_id] = Session(
                            session_id=session_id,
                            deleted=this_session is None,
                            session_name=this_session["name"] if this_session else "",
                            messages=[],
                        )
                        session_internal_chat_ids[session_id] = (
                            this_session["chat"] if this_session else -1
                        )

                    cached_sessions[session_id].messages.append(
                        Message(id=message["id"], text=message["text"])
                    )

            for session in cached_sessions.values():
                internal_chat_id: InternalChatId = session_internal_chat_ids[
                    session.session_id
                ]

                if internal_chat_id != -1:
                    if internal_chat_id not in cached_chats:
                        this_chat = conn.execute(
                            "SELECT * FROM chats WHERE id = ?", (internal_chat_id,)
                        ).fetchone()

                        cached_chats[internal_chat_id] = Chat(
                            chat_id=this_chat["chatId"], sessions=[]
                        )

                    cached_chats[internal_chat_id].sessions.append(session)
                else:
                    console.print(
                        f"[red]Session {session.session_id} has no chat associated with it[/red]"
                    )
                    if internal_chat_id not in cached_chats:
                        console.print(
                            f"[red]Creating a new fallback chat for session {session.session_id}[/red]"
                        )
                        cached_chats[internal_chat_id] = Chat(chat_id=-1, sessions=[])
                    cached_chats[internal_chat_id].sessions.append(session)

            export_data = ExportData(
                export_date=datetime.datetime.now(tz=datetime.UTC),
                user_id=user_id,
                banned=user["banned"],
                consented=user["consented"],
                total_chats=len(cached_chats),
                total_messages=total_messages,
                chats=list(cached_chats.values()),
            )
    except Exception:
        console.print(traceback.format_exc())
        exit(1)


with console.status("[bold green]Writing export data..."):
    with output_file.open("wb") as f:
        f.write(orjson.dumps(export_data.model_dump(), option=orjson.OPT_INDENT_2))

    console.print(
        f"[bold green]Exported {total_messages} messages to {output_file}[/bold green]"
    )
