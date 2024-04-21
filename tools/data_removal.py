# python3 tools/data_removal.py --chat-id=-100123456789 --replace-text="Hello, world!" --with-text=""  [--markovdb=/path/to/markov.db]

import argparse
import sqlite3
from pathlib import Path

from pydantic import BaseModel
from rich.console import Console
from rich.progress import Progress

"""
database schema:
CREATE TABLE "chats"(chatId INTEGER NOT NULL UNIQUE, enabled INTEGER NOT NULL, percentage INTEGER NOT NULL, premium INTEGER NOT NULL, banned INTEGER NOT NULL, blockLinks INTEGER NOT NULL, blockUsernames INTEGER NOT NULL, keepSfw INTEGER NOT NULL, markovDisabled INTEGER NOT NULL, quotesDisabled INTEGER NOT NULL, id INTEGER NOT NULL PRIMARY KEY, pollsDisabled INTEGER NOT NULL DEFAULT 1)
CREATE TABLE "messages"(session INTEGER NOT NULL, sender INTEGER NOT NULL, text TEXT NOT NULL, id INTEGER NOT NULL PRIMARY KEY, FOREIGN KEY(session) REFERENCES "sessions"(id) ON DELETE CASCADE, FOREIGN KEY(sender) REFERENCES "users"(id))
CREATE TABLE "sessions"(name TEXT NOT NULL, uuid TEXT NOT NULL UNIQUE, chat INTEGER NOT NULL, isDefault INTEGER NOT NULL, owoify INTEGER NOT NULL, emojipasta INTEGER NOT NULL, caseSensitive INTEGER NOT NULL, alwaysReply INTEGER NOT NULL, id INTEGER NOT NULL PRIMARY KEY, randomReplies INTEGER NOT NULL DEFAULT 0, learningPaused INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(chat) REFERENCES "chats"(id) ON DELETE CASCADE)
CREATE TABLE "users"(userId INTEGER NOT NULL UNIQUE, admin INTEGER NOT NULL, banned INTEGER NOT NULL, id INTEGER NOT NULL PRIMARY KEY, consented INTEGER NOT NULL DEFAULT 0)
"""

root = Path(__file__).parent.parent

parser = argparse.ArgumentParser(
    description="Replace text from messages in the database"
)
parser.add_argument(
    "--chat-id", type=int, required=True, help="The chat id to remove messages from"
)
parser.add_argument(
    "--replace-text", type=str, required=True, help="The text to replace"
)
parser.add_argument(
    "--with-text", type=str, required=True, help="The text to replace with"
)
parser.add_argument(
    "--markovdb",
    type=Path,
    default=root / "data" / "markov.db",
    help="The path to the markov database",
)
args = parser.parse_args()

chat_id = args.chat_id
replace_text = args.replace_text
with_text = args.with_text
markovdb = args.markovdb

console = Console()

if not markovdb.exists():
    console.print(f"Database not found: {markovdb}")
    exit(1)


ChatId = int
SessionId = int
MessageId = int


class Message(BaseModel):
    id: MessageId
    text: str


class Session(BaseModel):
    session_id: SessionId
    session_name: str
    messages: list[Message]


class Chat(BaseModel):
    chat_id: ChatId
    sessions: list[Session]


with sqlite3.connect(markovdb) as conn:
    # Enable row factory to access columns by name
    conn.row_factory = sqlite3.Row

    with Progress() as progress:
        chat = Chat(chat_id=chat_id, sessions=[])
        cursor = conn.cursor()

        # check if chat exists
        cursor.execute("SELECT * FROM chats WHERE chatId = ?", (chat_id,))
        if not (this_chat := cursor.fetchone()):
            console.print(f"[red]Chat not found: {chat_id}[/red]")
            exit(1)

        internal_chat_id = this_chat["id"]

        # Get all sessions for the chat
        cursor.execute("SELECT * FROM sessions WHERE chat = ?", (internal_chat_id,))

        while True:
            sessions = cursor.fetchmany(10)
            if not sessions:
                break

            for session in sessions:
                session_id = session["id"]
                session_name = session["name"]

                chat.sessions.append(
                    Session(
                        session_id=session_id,
                        session_name=session_name,
                        messages=[],
                    )
                )

        # Total sessions
        console.print(f"[bold green]Total sessions: {len(chat.sessions)}[/bold green]")

        # Get total count
        total_messages = 0
        total_deleted = 0
        total_updated = 0
        for session in chat.sessions:
            cursor.execute(
                "SELECT COUNT(*) AS total_messages FROM messages WHERE session = ?",
                (session.session_id,),
            )
            total_messages += cursor.fetchone()["total_messages"]

        if total_messages == 0:
            console.print("[bold yellow]No messages found: nothing to do[/bold yellow]")
            exit(0)

        console.print(f"[bold green]Total messages: {total_messages}[/bold green]")
        task = progress.add_task("Replacing text", total=total_messages)

        for session in chat.sessions:
            cursor.execute(
                "SELECT * FROM messages WHERE session = ?", (session.session_id,)
            )

            while True:
                messages = cursor.fetchmany(100)
                if not messages:
                    break

                for message in messages:
                    progress.update(task, advance=1)
                    message_id = message["id"]
                    text = message["text"]

                    if replace_text in text:
                        new_text = text.replace(replace_text, with_text)
                        if not new_text.strip():
                            cursor.execute(
                                "DELETE FROM messages WHERE id = ?", (message_id,)
                            )
                            total_deleted += 1
                        else:
                            cursor.execute(
                                "UPDATE messages SET text = ? WHERE id = ?",
                                (new_text, message_id),
                            )
                            total_updated += 1

    console.print("[bold green]Committing changes...[/bold green]")
    conn.commit()
    # VACUUM the database to free up space
    console.print("[bold green]Vacuuming database...[/bold green]")
    conn.execute("VACUUM")
    conn.commit()
    console.print("[bold green]Database vacuumed[/bold green]")
    # Done! Total messages: 1000, deleted: 100, updated: 900
    console.print(
        f"[bold green]Done! Total messages: {total_messages}, deleted: {total_deleted}, updated: {total_updated}[/bold green]"
    )
