import
  std / [os, oids],
  norm / model,
  norm / pragmas,
  norm / sqlite

const
  DB_NAME = "markov.db"
  NEW_PREFIX = "new_"

type
  OldUser* {.tableName: "users".} = ref object of Model
    userId* {.unique.}: int64
    admin*: bool
  
  User* {.tableName: "users".} = ref object of Model
    userId* {.unique.}: int64
    admin*: bool
    banned*: bool

  OldChat* {.tableName: "chats".} = ref object of Model
    chatId* {.unique.}: int64
    enabled*: bool
    percentage*: int

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

  Session* {.tableName: "sessions".} = ref object of Model
    name*: string
    uuid* {.unique.}: string
    chat* {.onDelete: "CASCADE".}: Chat
    isDefault*: bool

  OldMessage* {.tableName: "messages".} = ref object of Model
    sender*: OldUser
    chat*: OldChat
    text*: string

  Message* {.tableName: "messages".} = ref object of Model
    session* {.onDelete: "CASCADE".}: Session
    sender*: User
    text*: string

proc main =
  discard tryRemoveFile(NEW_PREFIX & DB_NAME)
  let
    oldConn = open(DB_NAME, "", "", "")
    newConn = open(NEW_PREFIX & DB_NAME, "", "", "")
  defer:
    oldConn.close()
    newConn.close()

  newConn.createTables(User())
  newConn.createTables(Chat())
  newConn.createTables(Session(chat: Chat()))
  newConn.createTables(Message(sender: User(), session: Session(chat: Chat())))

  var selectedChats: seq[OldChat] = @[OldChat()]
  oldConn.selectAll(selectedChats)
  for chat in selectedChats:
    var chatToInsert = Chat(chatId: chat.chatId, enabled: chat.enabled, percentage: chat.percentage)
    newConn.insert(chatToInsert)

  var newChats: seq[Chat] = @[Chat()]
  newConn.selectAll(newChats)
  for chat in newChats:
    var session = Session(name: "default", uuid: $genOid(), chat: chat, isDefault: true)
    newConn.insert(session)

  var selectedUsers: seq[OldUser] = @[OldUser()]
  oldConn.selectAll(selectedUsers)
  for user in selectedUsers:
    var userToInsert = User(userId: user.userId, admin: user.admin)
    newConn.insert(userToInsert)

  var selectedMessages: seq[OldMessage] = @[OldMessage(sender: OldUser(), chat: OldChat())]
  oldConn.selectAll(selectedMessages)
  for message in selectedMessages:
    var
      session = Session(chat: Chat())
      sender = User()

    newConn.select(session, "chatId = ?", message.chat.chatId)
    newConn.select(sender, "userId = ?", message.sender.userId)

    var messageToInsert = Message(
      session: session,
      sender: sender,
      text: message.text,
    )
    newConn.insert(messageToInsert)


when isMainModule:
  main()
