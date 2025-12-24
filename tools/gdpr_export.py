# python3 tools/gdpr_export.py --user-id=12345678 --output-file=/tmp/export.json [--markovdb=/path/to/markov.db]
# python3 tools/gdpr_export.py --chat-id=-100123456789 --output-file=/tmp/export.json [--markovdb=/path/to/markov.db]

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
Export shape (user export):
{
    "export_type": "user",
    "export_date": "2021-10-01T00:00:00Z",
    "user_id": 12345678,
    "banned": false,
    "consented": true,
    "users": [{"user_id": 12345678, "banned": false, "consented": true}],
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
                            "sender_user_id": 12345678,
                            "text": "Hello, world!"
                        }
                    ]
                }
            ]
        }
    ]
}

Export shape (chat export):
{
    "export_type": "chat",
    "chat_id": -100123456789,
    "users": [{"user_id": 111, "banned": false, "consented": true}],
    "total_messages": 3,
    "chats": [ ... same shape ... ]
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
target_group = parser.add_mutually_exclusive_group(required=True)
target_group.add_argument(
    "--user-id", type=int, help="Export all messages sent by this user"
)
target_group.add_argument(
    "--chat-id", type=int, help="Export all messages from this chat"
)
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


class UserInfo(BaseModel):
    user_id: UserId
    banned: bool
    consented: bool


class Message(BaseModel):
    id: InternalMessageId
    sender_user_id: UserId
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
    export_type: str
    export_date: datetime.datetime
    user_id: UserId | None = None
    chat_id: ChatId | None = None
    banned: bool | None = None
    consented: bool | None = None
    users: list[UserInfo]
    total_chats: int
    total_messages: int
    chats: list[Chat]


with sqlite3.connect(markovdb) as conn:
    # enable row factory to access columns by name
    conn.row_factory = sqlite3.Row

    try:
        export_type = "user" if args.user_id is not None else "chat"
        target_user_id: UserId | None = args.user_id
        target_chat_id: ChatId | None = args.chat_id

        cached_chats: dict[InternalChatId, Chat] = {}
        cached_sessions: dict[SessionId, Session] = {}
        session_internal_chat_ids: dict[SessionId, InternalChatId] = {}
        users_info: dict[int, UserInfo] = {}

        internal_chat_id: InternalChatId | None = None
        user_internal_id: int | None = None

        if export_type == "user":
            user = conn.execute(
                "SELECT * FROM users WHERE userId = ?", (target_user_id,)
            ).fetchone()

            if user is None:
                console.print(f"[red]User not found: {target_user_id}[/red]")
                exit(1)

            users_info[user["id"]] = UserInfo(
                user_id=user["userId"], banned=user["banned"], consented=user["consented"]
            )
            user_internal_id = user["id"]

        if export_type == "chat":
            chat_row = conn.execute(
                "SELECT * FROM chats WHERE chatId = ?", (target_chat_id,)
            ).fetchone()

            if chat_row is None:
                console.print(f"[red]Chat not found: {target_chat_id}[/red]")
                exit(1)

            internal_chat_id = chat_row["id"]

        # get messages count
        if export_type == "user":
            total_messages = conn.execute(
                "SELECT COUNT(*) AS total_messages FROM messages WHERE sender = ?",
                (user_internal_id,),
            ).fetchone()["total_messages"]
        else:
            total_messages = conn.execute(
                """
                SELECT COUNT(*) AS total_messages
                FROM messages m
                JOIN sessions s ON m.session = s.id
                WHERE s.chat = ?
                """,
                (internal_chat_id,),
            ).fetchone()["total_messages"]

        console.print(
            f"[bold green]Exporting {total_messages} messages for {export_type} target...[/bold green]"
        )

        with Progress() as progress:
            task = progress.add_task("Exporting messages...", total=total_messages)

            if export_type == "user":
                messages_cursor = conn.execute(
                    """
                    SELECT m.*, s.chat as session_chat
                    FROM messages m
                    JOIN sessions s ON m.session = s.id
                    WHERE m.sender = ?
                    """,
                    (user_internal_id,),
                )
            else:
                messages_cursor = conn.execute(
                    """
                    SELECT m.*, s.chat as session_chat
                    FROM messages m
                    JOIN sessions s ON m.session = s.id
                    WHERE s.chat = ?
                    """,
                    (internal_chat_id,),
                )

            while True:
                messages_chunk = messages_cursor.fetchmany(1000)
                if not messages_chunk:
                    break

                for message in messages_chunk:
                    progress.update(task, advance=1)
                    session_id: SessionId = message["session"]
                    session_chat_id: InternalChatId = message["session_chat"]
                    sender_internal_id = message["sender"]

                    if sender_internal_id not in users_info:
                        sender_user_row = conn.execute(
                            "SELECT * FROM users WHERE id = ?", (sender_internal_id,)
                        ).fetchone()
                        users_info[sender_internal_id] = UserInfo(
                            user_id=sender_user_row["userId"],
                            banned=sender_user_row["banned"],
                            consented=sender_user_row["consented"],
                        )

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
                            this_session["chat"] if this_session else session_chat_id
                        )

                    cached_sessions[session_id].messages.append(
                        Message(
                            id=message["id"],
                            sender_user_id=users_info[sender_internal_id].user_id,
                            text=message["text"],
                        )
                    )

            for session in cached_sessions.values():
                internal_session_chat_id: InternalChatId = session_internal_chat_ids[
                    session.session_id
                ]

                if internal_session_chat_id != -1:
                    if internal_session_chat_id not in cached_chats:
                        this_chat = conn.execute(
                            "SELECT * FROM chats WHERE id = ?", (internal_session_chat_id,)
                        ).fetchone()

                        cached_chats[internal_session_chat_id] = Chat(
                            chat_id=this_chat["chatId"], sessions=[]
                        )

                    cached_chats[internal_session_chat_id].sessions.append(session)
                else:
                    console.print(
                        f"[red]Session {session.session_id} has no chat associated with it[/red]"
                    )
                    if internal_session_chat_id not in cached_chats:
                        console.print(
                            f"[red]Creating a new fallback chat for session {session.session_id}[/red]"
                        )
                        cached_chats[internal_session_chat_id] = Chat(chat_id=-1, sessions=[])
                    cached_chats[internal_session_chat_id].sessions.append(session)

            unique_users = {v.user_id: v for v in users_info.values()}

            export_data = ExportData(
                export_type=export_type,
                export_date=datetime.datetime.now(tz=datetime.UTC),
                user_id=target_user_id if export_type == "user" else None,
                chat_id=target_chat_id if export_type == "chat" else None,
                banned=users_info[user_internal_id].banned if export_type == "user" else None,
                consented=users_info[user_internal_id].consented if export_type == "user" else None,
                users=list(unique_users.values()),
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
