import
  std / [oids, options],
  norm / model,
  norm / pragmas,
  norm / sqlite

type
  User* {.tableName: "users".} = ref object of Model
    userId* {.unique.}: int64
    admin*: bool
    banned*: bool

  Chat* {.tableName: "chats".} = ref object of Model
    chatId* {.unique.}: int64
    enabled*: bool
    percentage*: int

    premium*: bool
    banned*: bool

    blockLinks*: bool
    blockUsernames*: bool
    keepSfw*: bool # [BETA]
    #    https://www.surgehq.ai/blog/the-obscenity-list-surge
    # -> https://www.kaggle.com/nicapotato/bad-bad-words

    markovDisabled*: bool

  Session* {.tableName: "sessions".} = ref object of Model
    name*: string
    uuid* {.unique.}: string
    chat* {.onDelete: "CASCADE".}: Chat
    isDefault*: bool

    owoify*: int
    emojipasta*: bool

  Message* {.tableName: "messages".} = ref object of Model
    session* {.onDelete: "CASCADE".}: Session
    sender*: User
    text*: string


proc initDatabase*(name: string = "markov.db"): DbConn =
  result = open(name, "", "", "")
  result.createTables(User())
  result.createTables(Chat())
  result.createTables(Session(chat: Chat()))
  result.createTables(Message(sender: User(), session: Session(chat: Chat())))
  result.exec(sql"""
    BEGIN TRANSACTION;
    ALTER TABLE sessions ADD owoify INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE sessions ADD emojipasta INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE chats ADD markovDisabled INTEGER NOT NULL DEFAULT 0;
    COMMIT;
  """)

proc getUser*(conn: DbConn, userId: int64): User =
  new result
  conn.select(result, "users.userId = ?", userId)

proc getChat*(conn: DbConn, chatId: int64): Chat =
  new result
  conn.select(result, "chats.chatId = ?", chatId)

proc getSession*(conn: DbConn, uuid: string): Session =
  result = Session(chat: Chat())
  conn.select(result, "uuid = ?", uuid)

proc getSessions*(conn: DbConn, chatId: int64): seq[Session] =
  result = @[Session(chat: Chat())]
  conn.select(result, "chatId = ?", chatId)

proc addUser*(conn: DbConn, user: User): User =
  var user = user
  conn.insert user
  return conn.getUser(user.userId)

proc addSession*(conn: DbConn, session: Session): Session =
  var session = session
  session.uuid = $genOid()
  conn.insert session
  return conn.getSession(session.uuid)

proc getSessionsCount*(conn: DbConn, chatId: int64): int64 =
  let query = "SELECT COUNT(*) FROM sessions WHERE chat = (SELECT id FROM chats WHERE chatId = ? LIMIT 1)"
  let params = @[
    DbValue(kind: dvkInt, i: chatId)
  ]
  return get conn.getValue(int64, sql query, params)
  # return conn.count(Session, "chatId = ?", chatId)

proc getOrInsert*(conn: DbConn, chat: Chat, doNotCreateSession: bool = false): Chat

proc getDefaultSession*(conn: DbConn, chatId: int64): Session =
  result = Session(chat: Chat())
  try:
    conn.select(result, "chat.chatId = ? AND isDefault", chatId)
  except NotFoundError:
    if conn.getSessionsCount(chatId) > 0:
      conn.select(result, "chat.chatId = ?", chatId)
      result.isDefault = true
      conn.update(result)
      return

    return conn.addSession(Session(
      name: "default",
      uuid: $genOid(),
      chat: conn.getOrInsert(chat = Chat(chatId: chatId), doNotCreateSession = true),
      isDefault: true,
    ))

proc setDefaultSession*(conn: DbConn, chatId: int64, uuid: string): seq[Session] =
  for session in conn.getSessions(chatId = chatId):
    var session = session
    if session.uuid == uuid:
      session.isDefault = true
      conn.update(session)
    elif session.isDefault:
      session.isDefault = false
      conn.update(session)
    result.add(session)

const DEFAULT_TRIGGER_PERCENTAGE = 30#%
proc addChat*(conn: DbConn, chat: Chat, doNotCreateSession: bool = false): Chat =
  var chat = chat
  if chat.percentage == 0:
    chat.percentage = if chat.chatId < 0: DEFAULT_TRIGGER_PERCENTAGE
      else: 100
  chat.enabled = true # chat.chatId > 0
  conn.insert chat

  result = conn.getChat(chat.chatId)
  
  if not doNotCreateSession:
    discard conn.addSession(Session(
      name: "default",
      uuid: $genOid(),
      chat: result,
      isDefault: true,
    ))

proc getOrInsert*(conn: DbConn, user: User): User =
  try:
    return conn.getUser(user.userId)
  except NotFoundError:
    return conn.addUser(user) 

proc getOrInsert*(conn: DbConn, chat: Chat, doNotCreateSession: bool = false): Chat =
  try:
    return conn.getChat(chat.chatId)
  except NotFoundError:
    return conn.addChat(chat, doNotCreateSession = doNotCreateSession) 

proc getOrInsert*(conn: DbConn, session: Session): Session =
  try:
    return conn.getSession(session.uuid)
  except NotFoundError:
    return conn.addSession(session) 

proc updateOrCreate*(conn: DbConn, user: User): User =
  result = conn.getOrInsert(user)
  var user = user
  user.id = result.id
  conn.update(user)
  result = user

proc updateOrCreate*(conn: DbConn, chat: Chat): Chat =
  result = conn.getOrInsert(chat)
  var chat = chat
  chat.id = result.id
  conn.update(chat)
  result = chat

proc addMessage*(conn: DbConn, message: Message) =
  var message = message
  conn.insert message

proc getLatestMessages*(conn: DbConn, session: Session, count: int = 1500): seq[Message] =
  result = @[Message(sender: User(), session: Session(chat: Chat()))]
  conn.select(result, "uuid = ? AND chatId = ? ORDER BY messages.id DESC LIMIT ?", session.uuid, session.chat.chatId, count)

proc getMessagesCount*(conn: DbConn, session: Session): int64 =
  let query = "SELECT COUNT(*) FROM messages WHERE session = (SELECT id FROM sessions WHERE uuid = ? LIMIT 1)"
  let params = @[
    DbValue(kind: dvkString, s: session.uuid)
  ]
  return get conn.getValue(int64, sql query, params)
  # return conn.count(Session, "chatId = ?", chatId)

proc getUserMessagesCount*(conn: DbConn, session: Session, userId: int64): int64 =
  let query = "SELECT COUNT(*) FROM messages WHERE session = (SELECT id FROM sessions WHERE uuid = ? LIMIT 1) AND sender = (SELECT id FROM users WHERE userId = ?)"
  let params = @[
    DbValue(kind: dvkString, s: session.uuid),
    DbValue(kind: dvkInt, i: userId),
  ]
  return get conn.getValue(int64, sql query, params)
  # return conn.count(Session, "chatId = ?", chatId)

proc deleteMessages*(conn: DbConn, session: Session): int64 =
  result = conn.getMessagesCount(session)
  var query = "DELETE FROM sessions WHERE uuid = ? AND chat = (SELECT id FROM chats WHERE chatId = ? LIMIT 1)"
  var params = @[
    DbValue(kind: dvkString, s: session.uuid),
    DbValue(kind: dvkInt, i: session.chat.chatId),
  ]
  conn.exec(sql query, params)
  conn.exec(sql "DELETE FROM messages WHERE session = ?", DbValue(kind: dvkInt, i: session.id))

proc deleteFromUserInChat*(conn: DbConn, session: Session, userId: int64): int64 =
  result = conn.getUserMessagesCount(session, userId = userId)
  var query = "DELETE FROM messages WHERE session = (SELECT id FROM sessions WHERE uuid = ? LIMIT 1) AND sender = (SELECT id FROM users WHERE userId = ? LIMIT 1)"
  var params = @[
    DbValue(kind: dvkString, s: session.uuid),
    DbValue(kind: dvkInt, i: userId),
  ]
  conn.exec(sql query, params)

proc getBotAdmins*(conn: DbConn): seq[User] =
  result = @[User()]
  conn.select(result, "admin")

proc getBannedUsers*(conn: DbConn): seq[User] =
  result = @[User()]
  conn.select(result, "banned")

proc setAdmin*(conn: DbConn, userId: int64, admin: bool = true): User =
  var user = conn.getOrInsert(User(userId: userId))
  user.admin = admin
  conn.update(user)
  return user

proc setBanned*(conn: DbConn, userId: int64, banned: bool = true): User =
  var user = conn.getOrInsert(User(userId: userId))
  user.banned = banned
  conn.update(user)
  return user

proc setEnabled*(conn: DbConn, chatId: int64, enabled: bool = true): Chat =
  var chat = conn.getOrInsert(Chat(chatId: chatId))
  chat.enabled = enabled
  conn.update(chat)
  return chat

proc setBanned*(conn: DbConn, chatId: int64, banned: bool = true): Chat =
  var chat = conn.getOrInsert(Chat(chatId: chatId))
  chat.banned = banned
  conn.update(chat)
  return chat

proc getCount*(conn: DbConn, model: typedesc): int64 =
  return conn.count(model)

when isMainModule:
  import os
  import std / with

  discard os.tryRemoveFile("markov.db")

  let conn = initDatabase()
  var user = User(userId: 5001234567)

  with conn:
    insert user

  var selected = User()
  conn.select(selected, "users.userId = ?", 5001234567)
  echo selected[]

  echo conn.getUser(5001234567)[]
  echo conn.getUser(1234)[]
