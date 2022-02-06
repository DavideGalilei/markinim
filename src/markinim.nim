import std/[asyncdispatch, logging, options, os, times, strutils, strformat, tables, random, sets, parsecfg, sequtils, streams, sugar]
import telebot, norm / [model, sqlite], nimkov / generator

import ./database
import ./utils/[unixtime, timeout, listen]

var L = newConsoleLogger(fmtStr="$levelname | [$time] ")
addHandler(L)

var
  conn: DbConn
  botUsername: string
  admins: HashSet[int64]
  banned: HashSet[int64]
  markovs: Table[int64, (int64, MarkovGenerator)] # (chatId): (timestamp, MarkovChain)
  adminsCache: Table[(int64, int64), (int64, bool)] # (chatId, userId): (unixtime, isAdmin) cache
  chatSessions: Table[int64, (int64, Session)] # (chatId): (unixtime, Session) cache
  antiFlood: Table[int64, seq[int64]]

let uptime = epochTime()

const
  MARKOV_DB = "markov.db"

  ANTIFLOOD_SECONDS = 10
  ANTIFLOOD_RATE = 5

  MARKOV_SAMPLES_CACHE_TIMEOUT = 60 * 30 # 30 minutes
  GROUP_ADMINS_CACHE_TIMEOUT = 60 * 5 # result is valid for five minutes
  MARKOV_CHAT_SESSIONS_TIMEOUT = 60 * 30 # 30 minutes

  MAX_SESSIONS = 20
  MAX_FREE_SESSIONS = 5
  MAX_SESSION_NAME_LENGTH = 16

  UNALLOWED = "You are not allowed to perform this command"

template get(self: Table[int64, (int64, MarkovGenerator)], chatId: int64): MarkovGenerator =
  self[chatId][1]

proc mention(user: database.User): string =
  return &"[{user.userId}](tg://user?id={user.userId})"

proc isFlood(chatId: int64, rate: int = ANTIFLOOD_RATE, seconds: int = ANTIFLOOD_SECONDS): bool =
  let time = unixTime()
  if chatId notin antiFlood:
    antiflood[chatId] = @[time]
  else:
    antiFlood[chatId].add(time)

  antiflood[chatId] = antiflood[chatId].filterIt(time - it < seconds)
  return len(antiflood[chatId]) > rate

proc getCachedSession*(conn: DbConn, chatId: int64): database.Session =
  if chatId in chatSessions:
    let (_, session) = chatSessions[chatId]
    return session

  result = conn.getDefaultSession(chatId)
  chatSessions[chatId] = (unixTime(), result)

proc cleanerWorker {.async.} =
  while true:
    let
      time = unixTime()
      antiFloodKeys = antiFlood.keys.toSeq()

    for chatId in antiFloodKeys:
      let messages = antiflood[chatId].filterIt(time - it < ANTIFLOOD_SECONDS)
      if len(messages) != 0:
        antiFlood[chatId] = antiflood[chatId].filterIt(time - it < ANTIFLOOD_SECONDS)
      else:
        antiflood.del(chatId)
    
    let adminsCacheKeys = adminsCache.keys.toSeq()
    for record in adminsCacheKeys:
      let (timestamp, _) = adminsCache[record]
      if time - timestamp > GROUP_ADMINS_CACHE_TIMEOUT:
        adminsCache.del(record)
    
    let markovsKeys = markovs.keys.toSeq()
    for record in markovsKeys:
      let (timestamp, _) = markovs[record]
      if time - timestamp > MARKOV_SAMPLES_CACHE_TIMEOUT:
        markovs.del(record)

    let chatSessionsKeys = chatSessions.keys.toSeq()
    for record in chatSessionsKeys:
      let (timestamp, _) = chatSessions[record]
      if time - timestamp > MARKOV_CHAT_SESSIONS_TIMEOUT:
        chatSessions.del(record)

    await sleepAsync(30)

proc isAdminInGroup(bot: Telebot, chatId: int64, userId: int64): Future[bool] {.async.} =
  let time = unixTime()
  if (chatId, userId) in adminsCache:
    let (_, isAdmin) = adminsCache[(chatId, userId)]
    return isAdmin

  try:
    let member = await bot.getChatMember(chatId = $chatId, userId = userId.int)
    result = member.status == "creator" or member.status == "administrator"
  except Exception:
    result = false

  adminsCache[(chatId, userId)] = (time, result)


type KeyboardInterrupt = ref object of CatchableError
proc handler() {.noconv.} =
  raise KeyboardInterrupt(msg: "Keyboard Interrupt")
setControlCHook(handler)


proc showSessions(bot: Telebot, chatId, messageId: int64, sessions: seq[Session] = @[]) {.async.} =
  var sessions = sessions
  if sessions.len == 0:
    sessions = conn.getSessions(chatId = chatId)

  discard await bot.editMessageText(chatId = $chatId,
    messageId = int(messageId),
    text = "*Current sessions in this chat.* Send /delete to delete the current one.",
    replyMarkup = newInlineKeyboardMarkup(
      sessions.mapIt(
        @[InlineKeyboardButton(text: if it.isDefault: &"{it.name} 🎩" else: it.name, callbackData: some &"set_{chatId}_{it.uuid}")]
      ) & @[InlineKeyboardButton(text: "Add session", callbackData: some &"addsession_{chatId}")]
    ),
    parseMode = "markdown",
  )

proc handleCommand(bot: Telebot, update: Update, command: string, args: seq[string]) {.async.} =
  let
    message = update.message.get
    senderId = message.fromUser.get().id

  case command:
  of "start":
    const startMessage = "Hello, I learn from your messages and try to formulate my own sentences. Add me in a chat or send /enable to try me out here ᗜᴗᗜ"
    if message.chat.id != senderId: # /start only works in PMs
      if len(args) > 0 and args[0] == "enable":
        discard await bot.sendMessage(message.chat.id, startMessage)
      return
    discard await bot.sendMessage(message.chat.id,
      startMessage,
      replyMarkup = newInlineKeyboardMarkup(@[InlineKeyboardButton(text: "Add me :D", url: some &"https://t.me/{botUsername}?startgroup=enable")])
    )
  of "help":
    discard
  of "admin", "unadmin", "remadmin":
    if len(args) < 1:
      return
    elif senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return

    try:
      let userId = parseBiggestInt(args[0])
      discard conn.setAdmin(userId = userId, admin = (command == "admin"))
      
      if command == "admin":
        admins.incl(userId)
      else:
        admins.excl(userId)

      discard await bot.sendMessage(message.chat.id,
        if command == "admin": &"Successfully promoted [{userId}](tg://user?id={userId})"
        else: &"Successfully demoted [{userId}](tg://user?id={userId})",
        parseMode = "markdown")
    except Exception as error:
      discard await bot.sendMessage(message.chat.id, &"An error occurred: <code>{$typeof(error)}: {getCurrentExceptionMsg()}</code>", parseMode = "html")
  of "botadmins":
    if senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return

    let admins = conn.getBotAdmins()

    discard await bot.sendMessage(message.chat.id,
      "*List of the bot admins:*\n" &
      admins.mapIt("~ " & it.mention).join("\n"),
      parseMode = "markdown",
    )
  of "count", "stats":
    if senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return
    discard await bot.sendMessage(message.chat.id,
      &"*Users*: `{conn.getCount(database.User)}`\n" &
      &"*Chats*: `{conn.getCount(database.Chat)}`\n" &
      &"*Messages*: `{conn.getCount(database.Message)}`\n" &
      &"*Sessions*: `{conn.getCount(database.Session)}`\n" &
      &"*Uptime*: `{toInt(epochTime() - uptime)}`s",
      parseMode = "markdown")
  of "banpeer", "unbanpeer":
    const banCommand = "banpeer"

    if len(args) < 1:
      return
    elif senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return

    try:
      let peerId = parseBiggestInt(args[0])
      if peerId == senderId:
        discard await bot.sendMessage(message.chat.id, "You are not allowed to ban yourself")
        return
      elif peerId < 0:
        discard conn.setBanned(chatId = peerId, banned = (command == banCommand))
      else:
        discard conn.setBanned(userId = peerId, banned = (command == banCommand))

      if command == banCommand:
        banned.incl(peerId)
      else:
        banned.excl(peerId)

      discard await bot.sendMessage(message.chat.id,
        if command == banCommand: &"Successfully banned [{peerId}](tg://user?id={peerId})"
        else: &"Successfully unbanned [{peerId}](tg://user?id={peerId})",
        parseMode = "markdown")
    except Exception as error:
      discard await bot.sendMessage(message.chat.id, &"An error occurred: <code>{$typeof(error)}: {getCurrentExceptionMsg()}</code>", parseMode = "html")
  of "enable", "disable":
    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return

    discard conn.setEnabled(message.chat.id, enabled = (command == "enable"))

    discard await bot.sendMessage(message.chat.id,
      if command == "enable": "Successfully enabled learning in this chat"
      else: "Successfully disabled learning in this chat"
    )
  of "sessions":
    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return

    let sessions = conn.getSessions(message.chat.id)
    discard await bot.sendMessage(message.chat.id,
      "*Current sessions in this chat*",
      replyMarkup = newInlineKeyboardMarkup(
        sessions.mapIt(
          @[InlineKeyboardButton(text: if it.isDefault: &"{it.name} 🎩" else: it.name, callbackData: some &"set_{message.chat.id}_{it.uuid}")]
        ) & @[InlineKeyboardButton(text: "Add session", callbackData: some &"addsession_{message.chat.id}")]
      ),
      parseMode = "markdown",
    )
  of "percentage":
    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return

    var chat = conn.getOrInsert(database.Chat(chatId: message.chat.id))
    if len(args) == 0:
      discard await bot.sendMessage(message.chat.id,
        "This command needs an argument. Example: `/percentage 40` (default: `30`)\n" &
        &"Current percentage: `{chat.percentage}`%",
        parseMode = "markdown")
      return

    try:
      let percentage = parseInt(args[0].strip(chars = Whitespace + {'%'}))

      if percentage notin 1 .. 100:
        discard await bot.sendMessage(message.chat.id, "Percentage must be a number between 1 and 100")
        return

      chat.percentage = percentage
      conn.update(chat)

      discard await bot.sendMessage(message.chat.id,
        &"Percentage has been successfully updated to `{percentage}`%",
        parseMode = "markdown")
    except ValueError:
      discard await bot.sendMessage(message.chat.id, "The value you inserted is not a number")
  of "markov":
    let enabled = conn.getOrInsert(database.Chat(chatId: message.chat.id)).enabled
    if not enabled:
      discard bot.sendMessage(message.chat.id, "Learning is not enabled in this chat. Enable it with /enable (for groups: admins only)")
      return
    
    if not markovs.hasKey(message.chat.id):
      markovs[message.chat.id] = (unixTime(), newMarkov(@[]))
      for dbMessage in conn.getLatestMessages(session = conn.getCachedSession(message.chat.id)):
        if dbMessage.text != "":
          markovs.get(message.chat.id).addSample(dbMessage.text)

    if len(markovs.get(message.chat.id).getSamples()) == 0:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a sentence")
      return

    let generated = markovs.get(message.chat.id).generate()
    if generated.isSome:
      discard await bot.sendMessage(message.chat.id, generated.get())
    else:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a sentence")
  of "export":
    if senderId notin admins:
      # discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return
    let tmp = getTempDir()
    copyFileToDir(MARKOV_DB, tmp)
    discard await bot.sendDocument(senderId, "file://" & (tmp / MARKOV_DB))
    discard tryRemoveFile(tmp / MARKOV_DB)
  of "settings":
    discard
  of "distort":
    discard
  of "hazmat":
    discard
  of "delete":
    var deleting {.global.}: HashSet[int64]

    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, UNALLOWED)
      return
    elif message.chat.id in deleting:
      discard await bot.sendMessage(message.chat.id, "I am already deleting the messages from my database. Please hold on")
    elif len(args) > 0 and args[0].toLower() == "confirm":
      deleting.incl(message.chat.id)
      defer: deleting.excl(message.chat.id)
      try:
        let 
          sentMessage = await bot.sendMessage(message.chat.id, "I am deleting data for this session...")
          defaultSession = conn.getCachedSession(message.chat.id)
          deleted = conn.deleteMessages(session = defaultSession)

        if markovs.hasKey(message.chat.id):
          markovs.del(message.chat.id)
        
        if conn.getSessionsCount(chatId = message.chat.id) < 2:
          conn.delete(defaultSession.dup)
          chatSessions[message.chat.id] = (unixTime(), conn.getCachedSession(chatId = message.chat.id))

        discard await bot.editMessageText(chatId = $message.chat.id, messageId = sentMessage.messageId,
          text = &"Operation completed. Successfully deleted `{deleted}` messages from my database!",
          parseMode = "markdown"
        )
        return
      except Exception as error:
        discard await bot.sendMessage(message.chat.id, text = "An error occurred. Operation has been aborted.", replyToMessageId = message.messageId)
        raise error
    else:
      discard await bot.sendMessage(message.chat.id,
        "If you are sure to delete data in this chat (of the current session), send `/delete confirm`. *NOTE*: This cannot be reverted",
        parseMode = "markdown")


proc handleCallbackQuery(bot: Telebot, update: Update) {.async.} =
  let
    callback = update.callbackQuery.get()
    userId = callback.fromUser.id
    data = callback.data.get()
  
  let
    splitted = data.split('_')
    command = splitted[0]
    args = splitted[1 .. ^1]
  
  case command:
  of "set":
    if len(args) < 2:
      discard await bot.answerCallbackQuery(callback.id, "Error: try again with a new message", showAlert = true)
      return

    let
      chatId = parseBiggestInt(args[0])
      uuid = args[1]

    if not await bot.isAdminInGroup(chatId = chatId, userId = userId):
      discard await bot.answerCallbackQuery(callback.id, UNALLOWED, showAlert = true)
      return

    try:
      let default = conn.getCachedSession(chatId = chatId)
      if default.uuid == uuid:
        discard await bot.answerCallbackQuery(callback.id, "This is already the default session for this chat", showAlert = true)
        return
    except:
      discard

    let sessions = conn.setDefaultSession(chatId = chatId, uuid = uuid)
    await bot.showSessions(chatId = callback.message.get().chat.id,
      messageId = callback.message.get().messageId,
      sessions = sessions)

    discard await bot.answerCallbackQuery(callback.id, "Done", showAlert = true)
  of "addsession":
    let chatId = parseBiggestInt(args[0])

    if not await bot.isAdminInGroup(chatId = chatId, userId = userId):
      discard await bot.answerCallbackQuery(callback.id, UNALLOWED, showAlert = true)
      return
    discard await bot.answerCallbackQuery(callback.id)
    
    let chat = conn.getChat(chatId = chatId)
    let sessionsCount = conn.getSessionsCount(chatId)
    if sessionsCount >= MAX_FREE_SESSIONS or sessionsCount >= MAX_SESSIONS and not chat.premium:
      let currentMax = if sessionsCount >= MAX_SESSIONS: MAX_SESSIONS else: MAX_FREE_SESSIONS
      discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
        messageId = callback.message.get().messageId,
        text = &"You cannot add more than {currentMax} sessions per chat.",
      )
      return

    discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
      messageId = callback.message.get().messageId,
      text = "*Send me the name for the new session.* Send /cancel to cancel the current operation.",
      parseMode = "markdown",
    )

    try:
      var message = (await getMessage(userId = userId, chatId = chatId)).message.get()
      while not message.text.isSome or message.caption.isSome:
        message = (await getMessage(userId = userId, chatId = chatId)).message.get()
      let text = if message.text.isSome: message.text.get else: message.caption.get()

      if text.toLower().startswith("/cancel"):
        discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
          text = "*Operation cancelled...*",
          parseMode = "markdown",
        )
        await sleepAsync(3 * 1000)
        discard await bot.deleteMessage(chatId = $callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
        )
        return
      elif text.len > MAX_SESSION_NAME_LENGTH:
        discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
          text = &"*Operation cancelled...* The session name is longer than `{MAX_SESSION_NAME_LENGTH}` characters",
          parseMode = "markdown",
        )
        return

      chatSessions[chatId] = (unixTime(), conn.addSession(Session(name: text, chat: conn.getChat(chatId))))
      await bot.showSessions(chatId = callback.message.get().chat.id, messageId = callback.message.get().messageId)
    except TimeoutError:
      discard await bot.deleteMessage(chatId = $callback.message.get().chat.id,
        messageId = callback.message.get().messageId,
      )

proc updateHandler(bot: Telebot, update: Update): Future[bool] {.async, gcsafe.} =
  if await listenUpdater(bot, update):
    return
  if not (update.message.isSome or update.callbackQuery.isSome):
      # return true will make bot stop process other callbacks
      return true

  try:
    if update.callbackQuery.isSome:
      let msgUser = update.callbackQuery.get().fromUser
      if msgUser.id in banned:
        return true

      await handleCallbackQuery(bot, update)
      return true
    elif not update.message.isSome:
      return true

    let response = update.message.get
    if response.text.isSome or response.caption.isSome:
      let
        msgUser = response.fromUser.get
        chatId = response.chat.id
      if msgUser.id notin admins and chatId in banned or msgUser.id in banned:
        return true

      var
        text = if response.text.isSome: response.text.get else: response.caption.get
        splitted = text.split()
        command = splitted[0].strip(chars = {'/'}, trailing = false)
        args = if len(splitted) > 1: splitted[1 .. ^1] else: @[]

      if text.startswith('/'):
        if msgUser.id notin admins and isFlood(chatId):
          return true

        if '@' in command:
          let splittedCommand = command.split('@')
          if splittedCommand[^1].toLower() != botUsername:
            return true
          command = splittedCommand[0]
        await handleCommand(bot, update, command, args)
        return true

      let chat = conn.getOrInsert(database.Chat(chatId: chatId))
      if not chat.enabled:
        return

      if not markovs.hasKeyOrPut(chatId, (unixTime(), newMarkov(@[text]))):
        for message in conn.getLatestMessages(session = conn.getCachedSession(chatId)):
          if message.text != "":
            markovs.get(chatId).addSample(message.text)
      else:
        markovs.get(chatId).addSample(text)

      let user = conn.getOrInsert(database.User(userId: msgUser.id))
      conn.addMessage(database.Message(text: text, sender: user, session: conn.getCachedSession(chat.chatId)))

      if rand(0 .. 100) <= chat.percentage and not isFlood(chatId, rate = 10, seconds = 60): # Max 10 messages per chat per minute
        let generated = markovs.get(chatId).generate()
        if generated.isSome:
          discard await bot.sendMessage(chatId, generated.get())
  except IOError:
    if "Bad Request: have no rights to send a message" in getCurrentExceptionMsg():
      try:
        if update.message.isSome():
          let chatId = update.message.get().chat.id
          discard await bot.leaveChat(chatId = $chatId)
      except: discard
    let msg = getCurrentExceptionMsg()
    L.log(lvlError, &"{$typeof(error)}: " & msg)
  except Exception as error:
    let msg = getCurrentExceptionMsg()
    L.log(lvlError, &"{$typeof(error)}: " & msg)
    raise error


proc main {.async.} =
  let
    configFile = currentSourcePath.parentDir / "../secret.ini"
    config = if fileExists(configFile): loadConfig(configFile)
      else: loadConfig(newStringStream())
    botToken = config.getSectionValue("config", "token", getEnv("BOT_TOKEN"))
    admin = config.getSectionValue("config", "admin", getEnv("ADMIN_ID"))

  conn = initDatabase(MARKOV_DB)
  defer: conn.close()

  if admin != "":
    admins.incl(conn.setAdmin(userId = parseBiggestInt(admin)).userId)
  
  for admin in conn.getBotAdmins():
    admins.incl(admin.userId)

  for bannedUser in conn.getBannedUsers():
    banned.incl(bannedUser.userId)

  let bot = newTeleBot(botToken)
  botUsername = (await bot.getMe()).username.get().toLower()

  asyncCheck cleanerWorker()

  bot.onUpdate(updateHandler)
  await bot.pollAsync(timeout = 200, clean = true)

when isMainModule:
  when defined(windows):
    if CompileDate != now().format("yyyy-MM-dd"):
      echo "You can't run this on windows after a day"
      quit(1)

  try:
    waitFor main()
  except KeyboardInterrupt:
    echo "\nQuitting...\nProgram has run for ", toInt(epochTime() - uptime), " seconds."
    quit(0)
