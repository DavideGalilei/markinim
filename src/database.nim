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

proc addUser*(conn: DbConn, user: User): User =
  var user = user
  conn.insert user
  return conn.getUser(user.userId)

proc getOrInsert*(conn: DbConn, user: User): User =
  try:
    return conn.getUser(user.userId)
  except NotFoundError:
    return conn.addUser(user) 

proc updateOrCreate*(conn: DbConn, user: User): User =
  result = conn.getOrInsert(user)
  var user = user
  user.id = result.id
  conn.update(user)
  result = user

proc setAdmin*(conn: DbConn, userId: int64, admin: bool = true): User =
  result = conn.updateOrCreate(User(userId: userId, admin: admin))


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
