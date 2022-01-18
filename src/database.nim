import
  norm / model,
  norm / pragmas,
  norm / sqlite

type
  User* {.tableName: "users".} = ref object of Model
    userId* {.unique.}: int64
    admin*: bool

  Chat* {.tableName: "chats".} = ref object of Model
    chatId* {.unique.}: int64
    enabled*: bool
    percentage*: int

  Message* {.tableName: "messages".} = ref object of Model
    sender*: User
    chat*: Chat
    text*: string


proc initDatabase*(name: string = "markov.db"): DbConn =
  result = open(name, "", "", "")
  result.createTables(User())
  result.createTables(Message(sender: User(), chat: Chat()))

proc getUser*(conn: DbConn, userId: int64): User =
  new result
  conn.select(result, "users.userId = ?", userId)

proc getChat*(conn: DbConn, chatId: int64): Chat =
  new result
  conn.select(result, "chats.chatId = ?", chatId)

proc addUser*(conn: DbConn, user: User): User =
  var user = user
  conn.insert user
  return conn.getUser(user.userId)

const DEFAULT_TRIGGER_PERCENTAGE = 30#%
proc addChat*(conn: DbConn, chat: Chat): Chat =
  var chat = chat
  if chat.percentage == 0:
    chat.percentage = if chat.chatId < 0: DEFAULT_TRIGGER_PERCENTAGE
      else: 100
  if chat.chatId > 0:
    chat.enabled = true
  conn.insert chat
  return conn.getChat(chat.chatId)

proc getOrInsert*(conn: DbConn, user: User): User =
  try:
    return conn.getUser(user.userId)
  except NotFoundError:
    return conn.addUser(user) 

proc getOrInsert*(conn: DbConn, chat: Chat): Chat =
  try:
    return conn.getChat(chat.chatId)
  except NotFoundError:
    return conn.addChat(chat) 

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

proc getLatestMessages*(conn: DbConn, chatId: int64, count: int = 500): seq[Message] =
  result = @[Message(sender: User(), chat: Chat())]
  conn.select(result, "chatId = ? ORDER BY messages.id DESC LIMIT ?", chatId, count)

proc getBotAdmins*(conn: DbConn): seq[User] =
  result = @[User()]
  conn.select(result, "admin = true")

proc setAdmin*(conn: DbConn, userId: int64, admin: bool = true): User =
  result = conn.updateOrCreate(User(userId: userId, admin: admin))

proc setEnabled*(conn: DbConn, chatId: int64, enabled: bool = true): Chat =
  result = conn.updateOrCreate(Chat(chatId: chatId, enabled: enabled))

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
