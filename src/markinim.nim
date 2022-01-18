import std/[asyncdispatch, logging, options, os, times, strutils, strformat, tables, random, sets, parsecfg, sequtils, streams]
import telebot, norm / [model, sqlite], nimkov / generator
import ./database

var L = newConsoleLogger(fmtStr="$levelname, [$time] ")
addHandler(L)

var
  conn: DbConn
  botUsername: string
  admins: HashSet[int64]
  markovs: Table[int64, MarkovGenerator]
  adminsCache: Table[(int64, int64), (int64, bool)] # (chatId, userId): (unixtime, isAdmin) cache
  antiFlood: Table[int64, seq[int64]]

const
  MARKOV_DB = "markov.db"

  ANTIFLOOD_SECONDS = 15
  ANTIFLOOD_RATE = 5

let t = epochTime()

proc isFlood(chatId: int64, rate: int = ANTIFLOOD_RATE, seconds: int = ANTIFLOOD_SECONDS): bool =
  let time = getTime().toUnix
  if chatId notin antiFlood:
    antiflood[chatId] = @[time]
  else:
    antiFlood[chatId].add(time)

  antiflood[chatId] = antiflood[chatId].filterIt(time - it < seconds)
  return len(antiflood[chatId]) >= rate

proc cleanerWorker {.async.} =
  while true:
    let time = getTime().toUnix
    for chatId in antiFlood.keys:
      antiFlood[chatId] = antiflood[chatId].filterIt(time - it < ANTIFLOOD_SECONDS)
    await sleepAsync(30)

proc isAdminInGroup(bot: Telebot, chatId: int64, userId: int64): Future[bool] {.async.} =
  let time = getTime().toUnix
  if (chatId, userId) in adminsCache:
    let (timestamp, isAdmin) = adminsCache[(chatId, userId)]
    if not time - timestamp > (5 * 60): # result is valid for five minutes
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
  of "admin", "unadmin", "remadmin":
    if len(args) < 1:
      return
    elif senderId notin admins:
      discard await bot.sendMessage(message.chat.id, &"You are not allowed to perform this command")
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
  of "count":
    if senderId notin admins:
      discard await bot.sendMessage(message.chat.id, &"You are not allowed to perform this command")
      return
    discard await bot.sendMessage(message.chat.id,
      &"*Users*: `{conn.getCount(database.User)}`\n*Chats*: `{conn.getCount(database.Chat)}`\n*Messages:* `{conn.getCount(database.Message)}`",
      parseMode = "markdown")
  of "enable", "disable":
    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, "You are not allowed to perform this command")
      return

    discard conn.setEnabled(message.chat.id, enabled = (command == "enable"))

    discard await bot.sendMessage(message.chat.id,
      if command == "enable": "Successfully enabled learning in this chat"
      else: "Successfully disabled learning in this chat"
    )
  of "percentage":
    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, "You are not allowed to perform this command")
      return
    elif len(args) < 1:
      discard await bot.sendMessage(message.chat.id, "This command needs an argument. Example: `/percentage 40` (default: `30`)", parseMode = "markdown")
      return

    try:
      let percentage = parseInt(args[0].strip(chars = Whitespace + {'%'}))

      if percentage notin 1 .. 100:
        discard await bot.sendMessage(message.chat.id, "Percentage must be a number between 1 and 100")
        return

      var chat = conn.getOrInsert(database.Chat(chatId: message.chat.id))
      chat.percentage = percentage
      conn.update(chat)

      discard await bot.sendMessage(message.chat.id, "Percentage has been successfully updated")
    except ValueError:
      discard await bot.sendMessage(message.chat.id, "The value you inserted is not a number")
  of "markov":
    let enabled = conn.getOrInsert(database.Chat(chatId: message.chat.id)).enabled
    if not enabled:
      discard bot.sendMessage(message.chat.id, "Learning is not enabled in this chat. Enable it with /enable (for groups: admins only)")
      return
    
    if not markovs.hasKey(message.chat.id):
      markovs[message.chat.id] = newMarkov(@[])
      for dbMessage in conn.getLatestMessages(chatId = message.chat.id):
        if dbMessage.text != "":
          markovs[message.chat.id].addSample(dbMessage.text)

    let generated = markovs[message.chat.id].generate()
    if generated.isSome:
      discard await bot.sendMessage(message.chat.id, generated.get())
    else:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a sentence")
  of "export":
    if senderId notin admins:
      # discard await bot.sendMessage(message.chat.id, &"You are not allowed to perform this command")
      return
    let tmp = getTempDir()
    copyFileToDir(MARKOV_DB, tmp)
    discard await bot.sendDocument(senderId, "file://" & (tmp / MARKOV_DB))
    discard tryRemoveFile(tmp / MARKOV_DB)


proc updateHandler(bot: Telebot, u: Update): Future[bool] {.async, gcsafe.} =
  try:
    if not u.message.isSome:
      # return true will make bot stop process other callbacks
      return true

    let
      response = u.message.get
      msgUser = response.fromUser.get
      chatId = response.chat.id

    if response.text.isSome or response.caption.isSome:
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
        await handleCommand(bot, u, command, args)
        return true

      let chat = conn.getOrInsert(database.Chat(chatId: chatId))
      if not chat.enabled:
        return

      if not markovs.hasKeyOrPut(chatId, newMarkov(@[text])):
        for message in conn.getLatestMessages(chatId = chatId):
          if message.text != "":
            markovs[chatId].addSample(message.text)
      else:
        markovs[chatId].addSample(text)

      let user = conn.getOrInsert(database.User(userId: msgUser.id))
      conn.addMessage(database.Message(text: text, sender: user, chat: chat))

      if rand(0 .. 100) <= chat.percentage:
        let generated = markovs[chatId].generate()
        if generated.isSome:
          discard await bot.sendMessage(chatId, generated.get())
  except Exception as error:
    L.log(lvlError, &"{$typeof(error)}: {getCurrentExceptionMsg()}")


proc main {.async.} =
  let
    configFile = currentSourcePath.parentDir / "../secret.ini"
    config = if fileExists(configFile): loadConfig(configFile)
      else: loadConfig(newStringStream())
    botToken = config.getSectionValue("config", "token", getEnv("BOT_TOKEN"))
    admin = config.getSectionValue("config", "admin", getEnv("ADMIN_ID"))

  conn = initDatabase(MARKOV_DB)

  if admin != "":
    admins.incl(conn.setAdmin(userId = parseBiggestInt(admin)).userId)
  
  for admin in conn.getBotAdmins():
    admins.incl(admin.userId)

  let bot = newTeleBot(botToken)
  botUsername = (await bot.getMe()).username.get().toLower()

  asyncCheck cleanerWorker()

  bot.onUpdate(updateHandler)
  await bot.pollAsync(timeout = 300, clean = true)

when isMainModule:
  when defined(windows):
    if CompileDate != now().format("yyyy-MM-dd"):
      echo "You can't run this on windows after a day"
      quit(1)

  try:
    waitFor main()
  except KeyboardInterrupt:
    echo "\nQuitting...\nProgram has run for ", toInt(epochTime() - t), " seconds."
    quit(0)
