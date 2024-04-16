import std/[asyncdispatch, logging, options, os, times, strutils, strformat, tables, random, sets, parsecfg, sequtils, streams, sugar, re, algorithm]
from std / unicode import runeOffset
import pkg / norm / [model, sqlite]
import pkg / [telebot, owoifynim, emojipasta]
import pkg / nimkov / [generator, objects, typedefs, constants]

import database
import utils / [unixtime, timeout, listen, as_emoji, get_owoify_level, human_bytes, random_emoji]
import quotes / quote

var L = newConsoleLogger(fmtStr="$levelname | [$time] ", levelThreshold = Level.lvlAll)

var
  conn {.threadvar.}: DbConn
  admins {.threadvar.}: HashSet[int64]
  banned {.threadvar.}: HashSet[int64]
  markovs {.threadvar.}: Table[int64, (int64, MarkovGenerator)] # (chatId): (timestamp, MarkovChain)
  adminsCache {.threadvar.}: Table[(int64, int64), (int64, bool)] # (chatId, userId): (unixtime, isAdmin) cache
  chatSessions {.threadvar.}: Table[int64, (int64, Session)] # (chatId): (unixtime, Session) cache
  antiFlood {.threadvar.}: Table[int64, seq[int64]]
  keepLast: int = 1500
  quoteConfig {.threadvar.}: QuoteConfig

let uptime = epochTime()

const
  root = currentSourcePath().parentDir()
  MARKOV_DB = "markov.db"

  ANTIFLOOD_SECONDS = 10
  ANTIFLOOD_RATE = 6

  MARKOV_SAMPLES_CACHE_TIMEOUT = 60 * 30 # 30 minutes
  GROUP_ADMINS_CACHE_TIMEOUT = 60 * 5 # result is valid for five minutes
  MARKOV_CHAT_SESSIONS_TIMEOUT = 60 * 30 # 30 minutes

  MAX_SESSIONS = 20
  MAX_FREE_SESSIONS = 5
  MAX_SESSION_NAME_LENGTH = 16

  UNALLOWED = "You are not allowed to perform this command"
  CREATOR_STRING = " Please contact my creator if you think this is a mistake (more information on @Markinim)"
  SETTINGS_TEXT = "Tap on a button to toggle an option. Use /percentage to change the ratio of answers from the bot. Use /sessions to manage the sessions."
  CONSENT_TEXT = "Markinim is an opt-in service. With the options below, you can manage your data settings. For more information, see /privacy."
  HELP_TEXT = staticRead(root / "help.md")
  PRIVACY_TEXT = staticRead(root / "privacy.md")


let
  SfwRegex = re(
    (block:
      const words = staticRead(root / "premium/bad-words.csv").strip(chars = {' ', '\n', '\r'})
      words.split("\n").join("|")),
    flags = {reIgnoreCase, reStudy},
  )

  UrlRegex = re(r"""(?i)\b((?:https?://|www\d{0,3}[.]|[a-z0-9.\-]+[.][a-z]{2,4}/)(?:[^\s()<>]+|\(([^\s()<>]+|(\([^\s()<>]+\)))*\))+(?:\(([^\s()<>]+|(\([^\s()<>]+\)))*\)|[^\s`!()\[\]{};:'\".,<>?«»“”‘’]))""", flags = {reIgnoreCase, reStudy})
  UsernameRegex = re("@([a-zA-Z](_(?!_)|[a-zA-Z0-9]){3,32}[a-zA-Z0-9])", flags = {reIgnoreCase, reStudy})

template get(self: Table[int64, (int64, MarkovGenerator)], chatId: int64): MarkovGenerator =
  self[chatId][1]

proc echoError(args: varargs[string]) =
  for arg in args:
    write(stderr, arg)
  write(stderr, '\n')
  flushFile(stderr)

proc getThread(message: types.Message): int =
  result = -1
  if (message.messageThreadId.isSome and
      message.isTopicMessage.isSome and
      message.isTopicMessage.get):
    result = message.messageThreadId.get

proc mention(user: database.User): string =
  return &"[{user.userId}](tg://user?id={user.userId})"

proc isMessageOk(session: Session, text: string): bool =
  {.cast(gcsafe).}:
    if text.strip() == "":
      return false
    elif session.chat.keepSfw and text.find(SfwRegex) != -1:
      return false
    elif session.chat.blockLinks and text.find(UrlRegex) != -1:
      return false
    elif session.chat.blockUsernames and text.find(UsernameRegex) != -1:
      return false
    return true

proc isFlood(chatId: int64, rate: int = ANTIFLOOD_RATE, seconds: int = ANTIFLOOD_SECONDS): bool =
  let time = unixTime()
  if chatId notin antiFlood:
    antiflood[chatId] = @[time]
  else:
    antiFlood[chatId].add(time)

  antiflood[chatId] = antiflood[chatId].filterIt(time - it < seconds)
  return len(antiflood[chatId]) > rate

proc getCachedSession*(conn: DbConn, chatId: int64): database.Session {.gcsafe.} =
  if chatId in chatSessions:
    let (_, session) = chatSessions[chatId]
    return session

  result = conn.getDefaultSession(chatId)
  chatSessions[chatId] = (unixTime(), result)

proc refillMarkov(conn: DbConn, session: Session) =
  for message in conn.getLatestMessages(session = session, count = keepLast):
    if session.isMessageOk(message.text):
      markovs.get(session.chat.chatId).addSample(message.text, asLower = not session.caseSensitive)

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


proc byLength(a, b: string): int = cmp(len(a), len(b))
proc trimUnicode(s: string, length: int): string =
  let offset = s.runeOffset(length)
  if offset == -1:
    return s
  return s[0 ..< offset]
proc sortCandidates(options: seq[string], length: int): seq[string] =
  var options = options
  # let
  #   lengths = options.mapIt(it.len)
  #   minLength = min(lengths)
  #   maxLength = max(lengths)

  options.sort(byLength)
  options.reverse()

  for i in 0 ..< options.len:
    if options[i].len > length:
      options[i] = options[i].trimUnicode(length)

  return options


proc showSessions(bot: Telebot, chatId, messageId: int64, sessions: seq[Session] = @[]) {.async.} =
  var sessions = sessions
  if sessions.len == 0:
    sessions = conn.getSessions(chatId = chatId)
  # if checkDefault:
  let defaultSession = conn.getDefaultSession(chatId)

  discard await bot.editMessageText(chatId = $chatId,
    messageId = int(messageId),
    text = "*Current sessions in this chat.* Send /delete to delete the current one.",
    replyMarkup = newInlineKeyboardMarkup(
      sessions.mapIt(
        @[InlineKeyboardButton(text: (if it.isDefault or it.uuid == defaultSession.uuid: &"🎩 {it.name}" else: it.name) & &" - {conn.getMessagesCount(it)}",
            callbackData: some &"set_{chatId}_{it.uuid}")]
      ) & @[InlineKeyboardButton(text: "Add session", callbackData: some &"addsession_{chatId}")]
    ),
    parseMode = "markdown",
  )

proc getSettingsKeyboard(session: Session): InlineKeyboardMarkup =
  let chatId = session.chat.chatId
  return newInlineKeyboardMarkup(
    @[
      InlineKeyboardButton(text: &"Usernames {asEmoji(not session.chat.blockUsernames)}", callbackData: some &"usernames_{chatId}"),
      InlineKeyboardButton(text: &"Links {asEmoji(not session.chat.blockLinks)}", callbackData: some &"links_{chatId}"),
    ],
    @[
      InlineKeyboardButton(text: &"Keep SFW {asEmoji(session.chat.keepSfw)}", callbackData: some &"sfw_{chatId}")
    ],
    @[
      InlineKeyboardButton(text: &"Disable /markov {asEmoji(session.chat.markovDisabled)}", callbackData: some &"markov_{chatId}"),
      InlineKeyboardButton(text: &"Disable quotes {asEmoji(session.chat.quotesDisabled)}", callbackData: some &"quotes_{chatId}"),
    ],
    @[
      InlineKeyboardButton(text: &"[BETA] Would you rather {asEmoji(not session.chat.pollsDisabled)}", callbackData: some &"polls_{chatId}"),
    ],
    @[
      InlineKeyboardButton(text: "Session Bound:", callbackData: some"nothing"),
    ],
    @[
      InlineKeyboardButton(text: &"Emojipasta {asEmoji(session.emojipasta)}", callbackData: some &"emojipasta_{chatId}_{session.uuid}"),
      InlineKeyboardButton(text: &"Owoify {asEmoji(session.owoify)}", callbackData: some &"owoify_{chatId}_{session.uuid}"),
    ],
    @[
      InlineKeyboardButton(text: &"Case sensitive {asEmoji(session.caseSensitive)}", callbackData: some &"casesensivity_{chatId}_{session.uuid}"),
    ],
    @[
      InlineKeyboardButton(text: &"Always reply to replies {asEmoji(session.alwaysReply)}", callbackData: some &"alwaysreply_{chatId}_{session.uuid}"),
    ],
    @[
      InlineKeyboardButton(text: &"Randomly quote messages {asEmoji(session.randomReplies)}", callbackData: some &"randomreplies_{chatId}_{session.uuid}"),
    ],
    @[
      InlineKeyboardButton(text: &"Pause learning {asEmoji(session.learningPaused)}", callbackData: some &"pauselearning_{chatId}_{session.uuid}"),
    ],
  )

proc handleCommand(bot: Telebot, update: Update, command: string, args: seq[string], dbUser: database.User) {.async, gcsafe.} =
  let
    message = update.message.get
    senderId = int64(message.fromUser.get().id)
    threadId = getThread(message)

  let senderAnonymousAdmin: bool = message.senderChat.isSome and message.chat.id == message.senderChat.get.id
  template isSenderAdmin: bool =
    senderAnonymousAdmin or await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId)

  case command:
  of "start":
    const startMessage = (
      "Hello, I learn from your messages and try to formulate my own sentences. Add me in a chat or send /enable to try me out here ᗜᴗᗜ" &
      "\nSee /help for more information, and /privacy for my privacy policy."
    )
    if message.chat.id != senderId: # /start only works in PMs
      if len(args) > 0:
        if args[0] == "enable":
          discard await bot.sendMessage(message.chat.id, startMessage, messageThreadId=threadId)
        else:
          discard await bot.sendMessage(message.chat.id, startMessage, messageThreadId=threadId)
      return

    if len(args) > 0:
      # Private chat, /start with arguments
      if args[0] == "consent":
        discard await bot.sendMessage(message.chat.id,
          CONSENT_TEXT,
          replyMarkup = newInlineKeyboardMarkup(
            @[
              if dbUser.consented:
                InlineKeyboardButton(text: "Revoke consent", callbackData: some "consent_revoke")
              else:
                InlineKeyboardButton(text: "Give consent", callbackData: some "consent_give")
            ],
          ),
          messageThreadId=threadId)
        return

    discard await bot.sendMessage(message.chat.id,
      startMessage,
      replyMarkup = newInlineKeyboardMarkup(@[InlineKeyboardButton(text: "Add me :D", url: some &"https://t.me/{bot.username}?startgroup=enable")]),
      messageThreadId=threadId,
    )
  of "deleteme":
    if message.chat.id != senderId: # /deleteme only works in PMs
      return

    if len(args) > 0 and args[0] == "confirm":
      let count = conn.deleteAllMessagesFromUser(userId = senderId)
      discard await bot.sendMessage(message.chat.id,
        &"Operation completed. Successfully deleted `{count}` messages from my database!" &
        "\nNote: some messages might still be cached in the bot's memory in the compiled markov model, they will expire soon (at most in 4 hours, after the bot restarts for its backup procedure)" &
        "\nIf this is an urgent matter, please contact my creator. You can find more information on the bot's bio.",
        parseMode = "markdown",
        messageThreadId=threadId)
      return

    let count = conn.getTotalUserMessagesCount(userId = senderId)
    discard await bot.sendMessage(message.chat.id,
      &"This command will delete all your {count} messages from my database. Are you sure? Send `/deleteme confirm` to confirm.",
      parseMode = "markdown",
      messageThreadId=threadId,
    )
  of "help":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      return
    discard await bot.sendMessage(message.chat.id, HELP_TEXT, parseMode = "markdown", messageThreadId=threadId)
  of "privacy":
    if message.chat.id != senderId: # /privacy only works in PMs
      return
    discard await bot.sendMessage(message.chat.id,
      PRIVACY_TEXT,
      parseMode = "markdown",
      messageThreadId=threadId)
  of "manageconsent":
    if message.chat.id != senderId: # /manageconsent only works in PMs
      return

    discard await bot.sendMessage(message.chat.id,
      CONSENT_TEXT,
      replyMarkup = newInlineKeyboardMarkup(
        @[
          if dbUser.consented:
            InlineKeyboardButton(text: "Revoke consent", callbackData: some "consent_revoke")
          else:
            InlineKeyboardButton(text: "Give consent", callbackData: some "consent_give")
        ],
      ),
      messageThreadId=threadId)
    return
  of "admin", "unadmin", "remadmin":
    if len(args) < 1:
      return
    elif senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
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
        parseMode = "markdown",
        messageThreadId=threadId)
    except Exception as error:
      discard await bot.sendMessage(
        message.chat.id,
        &"An error occurred: <code>{$typeof(error)}: {getCurrentExceptionMsg()}</code>",
        parseMode = "html",
        messageThreadId=threadId)
  of "botadmins":
    if senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    let admins = conn.getBotAdmins()

    discard await bot.sendMessage(message.chat.id,
      "*List of the bot admins:*\n" &
      admins.mapIt("~ " & it.mention).join("\n"),
      parseMode = "markdown",
      messageThreadId=threadId,
    )
  of "count", "stats":
    if senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    var statsMessage = &"*Users*: `{conn.getCount(database.User)}`\n" &
      &"*Chats*: `{conn.getCount(database.Chat)}`\n" &
      &"*Messages*: `{conn.getCount(database.Message)}`\n" &
      &"*Sessions*: `{conn.getCount(database.Session)}`\n" &
      &"*Cached sessions*: `{len(chatSessions)}`\n" &
      &"*Cached markovs*: `{len(markovs)}`\n" &
      &"*Uptime*: `{toInt(epochTime() - uptime)}`s\n" &
      &"*Database size*: `{humanBytes(getFileSize(DATA_FOLDER / MARKOV_DB))}`\n" &
      &"*Memory usage (getOccupiedMem)*: `{humanBytes(getOccupiedMem())}`\n" &
      &"*Memory usage (getTotalMem)*: `{humanBytes(getTotalMem())}`\n"

    if command == "stats":
      statsMessage &= &"\n\n*Memory usage*:\n{GC_getStatistics()}"
    discard await bot.sendMessage(message.chat.id,
      statsMessage,
      parseMode = "markdown",
      messageThreadId=threadId)
  of "banpeer", "unbanpeer":
    const banCommand = "banpeer"

    if len(args) < 1:
      return
    elif senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    try:
      let peerId = parseBiggestInt(args[0])
      if peerId == senderId:
        discard await bot.sendMessage(message.chat.id, "You are not allowed to ban yourself", messageThreadId=threadId)
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
        parseMode = "markdown",
        messageThreadId=threadId)
    except Exception as error:
      discard await bot.sendMessage(
        message.chat.id,
        &"An error occurred: <code>{$typeof(error)}: {getCurrentExceptionMsg()}</code>",
        parseMode = "html",
        messageThreadId=threadId)
  of "enable", "disable":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    discard conn.setEnabled(message.chat.id, enabled = (command == "enable"))
    if command == "enable":
      var dbUser = conn.getOrInsert(database.User(userId: senderId))
      dbUser.consented = true
      conn.update(dbUser)

    if message.chat.kind.endswith("group"):
      discard await bot.sendMessage(message.chat.id,
        if command == "enable": "Successfully enabled learning in this chat"
        else: "Successfully disabled learning in this chat. If you want to enable it, send /enable.",
        messageThreadId=threadId,
      )
    else:
      discard await bot.sendMessage(message.chat.id,
        if command == "enable": "Successfully enabled learning in this chat"
        else: "Successfully disabled learning in this chat. If you want to enable it, send /enable." &
          "\nNote: the bot will still learn in groups where it is enabled. If you don't want this, check out /manageconsent.",
        messageThreadId=threadId,
      )
  of "sessions":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    discard conn.getDefaultSession(message.chat.id)
    let sessions = conn.getSessions(message.chat.id)
    discard await bot.sendMessage(message.chat.id,
      "*Current sessions in this chat.* Send /delete to delete the current one.",
      replyMarkup = newInlineKeyboardMarkup(
        sessions.mapIt(
          @[InlineKeyboardButton(text: (if it.isDefault: &"🎩 {it.name}" else: it.name) & &" - {conn.getMessagesCount(it)}",
              callbackData: some &"set_{message.chat.id}_{it.uuid}")]
        ) & @[InlineKeyboardButton(text: "Add session", callbackData: some &"addsession_{message.chat.id}")]
      ),
      parseMode = "markdown",
      messageThreadId=threadId,
    )
  of "percentage":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    var chat = conn.getOrInsert(database.Chat(chatId: message.chat.id))
    if len(args) == 0:
      discard await bot.sendMessage(message.chat.id,
        "This command needs an argument. Example: `/percentage 40` (default: `30`)\n" &
        &"Current percentage: `{chat.percentage}`%",
        parseMode = "markdown",
        messageThreadId=threadId)
      return

    if not message.chat.kind.endswith("group") and not dbUser.consented:
      discard await bot.sendMessage(
        message.chat.id,
        &"❕ You have not given consent to the bot's learning. Please [click here](https://t.me/{bot.username}?start=consent) to manage your data settings.",
        parseMode = "markdown",
        disableWebPagePreview = true,
        replyToMessageId = message.messageId,
        messageThreadId=threadId)
      return

    try:
      let percentage = parseInt(args[0].strip(chars = Whitespace + {'%'}))

      if percentage notin 0 .. 100:
        discard await bot.sendMessage(message.chat.id, "Percentage must be a number between 0 and 100", messageThreadId=threadId)
        return

      chat.percentage = percentage
      conn.update(chat)

      discard await bot.sendMessage(message.chat.id,
        &"Percentage has been successfully updated to `{percentage}`%",
        parseMode = "markdown",
        messageThreadId=threadId)
    except ValueError:
      discard await bot.sendMessage(message.chat.id, "The value you inserted is not a number", messageThreadId=threadId)
  of "markov", "quote":
    let enabled = conn.getOrInsert(database.Chat(chatId: message.chat.id)).enabled
    if not enabled:
      discard bot.sendMessage(
        message.chat.id,
        "Learning is not enabled in this chat. Enable it with /enable (for groups: admins only)",
        messageThreadId=threadId)
      return

    if not dbUser.consented:
      discard bot.sendMessage(
        message.chat.id,
        &"❕ You have not given consent to the bot's learning. Please [click here](https://t.me/{bot.username}?start=consent) to manage your data settings.",
        parseMode = "markdown",
        replyToMessageId = message.messageId,
        disableWebPagePreview = true,
        messageThreadId=threadId)
      return

    let cachedSession = conn.getCachedSession(message.chat.id)

    if cachedSession.chat.markovDisabled or (command == "quote" and cachedSession.chat.quotesDisabled):
      if not isSenderAdmin:
        return
    
    if not markovs.hasKey(message.chat.id):
      markovs[message.chat.id] = (unixTime(), newMarkov(@[]))
      conn.refillMarkov(cachedSession)

    if len(markovs.get(message.chat.id).samples) == 0:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a sentence", messageThreadId=threadId)
      return

    var start = args.join(" ")
    if not cachedSession.caseSensitive:
      start = start.toLower()

    let options = if len(args) > 0 and (args[0] != mrkvEnd or len(args) >= 2):
        newMarkovGenerateOptions(begin = some start)
      else:
        newMarkovGenerateOptions()

    {.cast(gcsafe).}:
      let generator = markovs.get(message.chat.id)
      let generated = try:
          generator.generate(options = options)
        except MarkovGenerateError:
          generator.generate()

    if generated.isSome:
      var text = generated.get()
      if cachedSession.owoify != 0:
        {.cast(gcsafe).}:
          text = text.owoify(getOwoifyLevel(cachedSession.owoify))
      if cachedSession.emojipasta:
        {.cast(gcsafe).}:
          text = emojify(text)
      
      var replyToMessageId = 0
      if message.replyToMessage.isSome():
        replyToMessageId = message.replyToMessage.get().messageId

      if command == "markov":
        discard await bot.sendMessage(message.chat.id, text, messageThreadId=threadId, replyToMessageId = replyToMessageId)
      elif command == "quote" and not isFlood(message.chat.id, rate = 3, seconds = 20):
        {.cast(gcsafe).}:
          let quotePic = genQuote(
            text = text,
            config = quoteConfig,
          )
        discard await bot.sendPhoto(message.chat.id, "file://" & quotePic, replyToMessageId = replyToMessageId)
        discard tryRemoveFile(quotePic)
    else:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a sentence", messageThreadId=threadId)
  of "wouldyourather":
    let enabled = conn.getOrInsert(database.Chat(chatId: message.chat.id)).enabled
    if not enabled:
      discard bot.sendMessage(
        message.chat.id,
        "Learning is not enabled in this chat. Enable it with /enable (for groups: admins only)",
        messageThreadId=threadId)
      return

    if not dbUser.consented:
      discard bot.sendMessage(
        message.chat.id,
        &"❕ You have not given consent to the bot's learning. Please [click here](https://t.me/{bot.username}?start=consent) to manage your data settings.",
        parseMode = "markdown",
        replyToMessageId = message.messageId,
        disableWebPagePreview = true,
        messageThreadId=threadId)
      return

    let cachedSession = conn.getCachedSession(message.chat.id)

    if cachedSession.chat.pollsDisabled:
      if not isSenderAdmin:
        return
    
    if not markovs.hasKey(message.chat.id):
      markovs[message.chat.id] = (unixTime(), newMarkov(@[]))
      conn.refillMarkov(cachedSession)

    if len(markovs.get(message.chat.id).samples) < 10:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a would you rather poll", messageThreadId=threadId)
      return

    let generator = markovs.get(message.chat.id)
    var options: seq[string]
    for i in 0 ..< 10:
      {.cast(gcsafe).}:
        let generated = generator.generate()
      if generated.isSome:
        var text = generated.get()
        if cachedSession.owoify != 0:
          {.cast(gcsafe).}:
            text = text.owoify(getOwoifyLevel(cachedSession.owoify))
        if cachedSession.emojipasta:
          {.cast(gcsafe).}:
            text = emojify(text)
        options.add(text)
      else:
        break

    options = options.deduplicate(isSorted = false)
    options = options.sortCandidates(length = 100)

    if len(options) < 2:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a would you rather poll", messageThreadId=threadId)
      return

    var isAnon: bool = false
    if args.len > 0 and args[0] == "anon":
      isAnon = true

    discard await bot.sendPoll(
      chatId = message.chat.id,
      question = &"{randomEmoji()} Would you rather...",
      options = options[0 ..< 2],
      messageThreadId = threadId,
      isAnonymous = isAnon,  # currently not working idk why
    )
  #[ of "export":
    if senderId notin admins:
      # discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return
    let tmp = getTempDir()
    copyFileToDir(DATA_FOLDER / MARKOV_DB, tmp)
    discard await bot.sendDocument(senderId, "file://" & (tmp / MARKOV_DB))
    discard tryRemoveFile(tmp / MARKOV_DB) ]#
  of "settings":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    let session = conn.getCachedSession(message.chat.id)
    discard await bot.sendMessage(message.chat.id,
      SETTINGS_TEXT,
      replyMarkup = getSettingsKeyboard(session),
      parseMode = "markdown",
      messageThreadId=threadId,
    )
    return
  of "distort":
    discard
  of "hazmat":
    discard
  of "delete":
    var deleting {.global, threadvar.}: HashSet[int64]

    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return
    elif message.chat.id in deleting:
      discard await bot.sendMessage(
        message.chat.id,
        "I am already deleting the messages from my database. Please hold on",
        messageThreadId=threadId)
    elif len(args) > 0 and args[0].toLower() == "confirm":
      try:
        deleting.incl(message.chat.id)
        let 
          sentMessage = await bot.sendMessage(message.chat.id, "I am deleting data for this session...", messageThreadId=threadId)
          defaultSession = conn.getCachedSession(message.chat.id)
          deleted = conn.deleteMessages(session = defaultSession)

        if markovs.hasKey(message.chat.id):
          markovs.del(message.chat.id)
        
        if chatSessions.hasKey(message.chat.id):
          chatSessions.del(message.chat.id)

        if conn.getSessionsCount(chatId = message.chat.id) > 1:
          conn.delete(defaultSession.dup)
          chatSessions[message.chat.id] = (unixTime(), conn.getCachedSession(chatId = message.chat.id))

        discard await bot.editMessageText(chatId = $message.chat.id, messageId = sentMessage.messageId,
          text = &"Operation completed. Successfully deleted `{deleted}` messages from my database!",
          parseMode = "markdown"
        )
        return
      except Exception as error:
        discard await bot.sendMessage(
          message.chat.id,
          text = "An error occurred. Operation has been aborted." & CREATOR_STRING,
          replyToMessageId = message.messageId,
          messageThreadId=threadId)
        raise error
      finally:
        deleting.excl(message.chat.id)
    else:
      discard await bot.sendMessage(message.chat.id,
        "If you are sure to delete data in this chat (of the current session), send `/delete confirm`. *NOTE*: This cannot be reverted",
        parseMode = "markdown",
        messageThreadId=threadId)
  of "deletefrom", "delfrom", "delete_from", "del_from":
    # deleteFromUserInChat
    if not message.chat.kind.endswith("group"):
      discard await bot.sendMessage(message.chat.id, "This command works only in groups", messageThreadId=threadId)
      return
    if not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return
    elif len(args) > 0 or message.replyToMessage.isSome():
      try:
        var userId: int64
        try:
          userId = if len(args) > 0:
              parseBiggestInt(args[0])
            elif message.replyToMessage.get().fromUser.isSome():
              message.replyToMessage.get().fromUser.get().id
            elif message.replyToMessage.get().senderChat.isSome():
              message.replyToMessage.get().senderChat.get().id
            else:
              discard await bot.sendMessage(chatId = message.chat.id,
                text = &"Operation failed. No user has been found. {CREATOR_STRING}",
                messageThreadId=threadId,
              )
              return
        except ValueError:
          discard await bot.sendMessage(chatId = message.chat.id,
            text = "Operation failed. Invalid integer (usernames are not allowed).",
            messageThreadId=threadId,
          )
          return

        let defaultSession = conn.getCachedSession(message.chat.id)

        if conn.getUserMessagesCount(defaultSession, userId) < 1:
          discard await bot.sendMessage(chatId = message.chat.id,
            text = &"There are 0 messages belonging to the specified user in this chat session. ",
            messageThreadId=threadId,
          )
          return

        let 
          sentMessage = await bot.sendMessage(
            message.chat.id,
            "I am deleting data from the specified user for this session...",
            messageThreadId=threadId)
          deleted = conn.deleteFromUserInChat(session = defaultSession, userId = userId)

        if markovs.hasKey(message.chat.id):
          markovs.del(message.chat.id)

        discard await bot.editMessageText(chatId = $message.chat.id, messageId = sentMessage.messageId,
          text = &"Operation completed. Successfully deleted `{deleted}` messages sent by the specified user from my database!",
          parseMode = "markdown"
        )
        return
      except Exception as error:
        discard await bot.sendMessage(
          message.chat.id,
          text = "An error occurred (does the user exist?). Operation has been aborted." & CREATOR_STRING,
          replyToMessageId = message.messageId,
          messageThreadId=threadId)
        raise error
    else:
      discard await bot.sendMessage(message.chat.id,
        "Send `/delfrom user_id` or use it in reply to someone. It will delete all messages a user sent from the bot's database. *NOTE*: This cannot be reverted",
        parseMode = "markdown",
        messageThreadId=threadId)


proc handleCallbackQuery(bot: Telebot, update: Update) {.async, gcsafe.} =
  let
    callback = update.callbackQuery.get()
    userId = callback.fromUser.id
    data = callback.data.get()
  
  let
    splitted = data.split('_')
    command = splitted[0]
    args = splitted[1 .. ^1]
  
  try:
    block callbackBlock:
      template editSettings =
        discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
          text = SETTINGS_TEXT,
          replyMarkup = getSettingsKeyboard(session),
          parseMode = "markdown",
        )

      template adminCheck =
        let chatId = callback.message.get().chat.id
        if callback.message.get().chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = chatId, userId = userId):
          discard await bot.answerCallbackQuery(callback.id, UNALLOWED, showAlert = true)
          return

      case command: 
      of "set":
        if len(args) < 2:
          discard await bot.answerCallbackQuery(callback.id, "Error: try again with a new message", showAlert = true)
          break callbackBlock

        let
          chatId = parseBiggestInt(args[0])
          uuid = args[1]

        adminCheck()

        let default = conn.getCachedSession(chatId = chatId)
        if default.uuid == uuid:
          discard await bot.answerCallbackQuery(callback.id, "This is already the default session for this chat", showAlert = true)
          break callbackBlock

        let sessions = conn.setDefaultSession(chatId = chatId, uuid = uuid)
        var newSession = sessions.filterIt(it.isDefault)

        if newSession.len < 1:
          let defaultSession = conn.getDefaultSession(chatId)
          newSession.add(defaultSession)

        chatSessions[chatId] = (unixTime(), newSession[0])

        markovs[chatId] = (unixTime(), newMarkov(
          conn.getLatestMessages(session = newSession[0], count = keepLast)
          .filterIt(newSession[0].isMessageOk(it.text))
          .mapIt(it.text), asLower = not newSession[0].caseSensitive)
        )

        await bot.showSessions(chatId = callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
          sessions = sessions)

        discard await bot.answerCallbackQuery(callback.id, "Done", showAlert = true)
      of "addsession":
        adminCheck()
        let chatId = parseBiggestInt(args[0])

        discard await bot.answerCallbackQuery(callback.id)

        let chat = conn.getChat(chatId = chatId)
        var sessionsCount = conn.getSessionsCount(chatId)

        if sessionsCount >= MAX_FREE_SESSIONS or (sessionsCount >= MAX_SESSIONS and not chat.premium):
          let currentMax = if chat.premium: MAX_SESSIONS else: MAX_FREE_SESSIONS
          discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
            messageId = callback.message.get().messageId,
            text = &"You cannot add more than {currentMax} sessions per chat.",
          )
          break callbackBlock

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
            break callbackBlock
          elif text.len > MAX_SESSION_NAME_LENGTH:
            discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
              messageId = callback.message.get().messageId,
              text = &"*Operation cancelled...* The session name is longer than `{MAX_SESSION_NAME_LENGTH}` characters",
              parseMode = "markdown",
            )
            break callbackBlock
          
          sessionsCount = conn.getSessionsCount(chatId)
          if sessionsCount >= MAX_FREE_SESSIONS or (sessionsCount >= MAX_SESSIONS and not chat.premium):
            let currentMax = if chat.premium: MAX_SESSIONS else: MAX_FREE_SESSIONS
            discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
              messageId = callback.message.get().messageId,
              text = &"You cannot add more than {currentMax} sessions per chat.",
            )
          else:
            discard conn.addSession(Session(name: text, chat: conn.getChat(chatId)))
            # chatSessions[chatId] = (unixTime(), conn.addSession(Session(name: text, chat: conn.getChat(chatId))))
            await bot.showSessions(chatId = callback.message.get().chat.id, messageId = callback.message.get().messageId)
        except TimeoutError:
          discard await bot.deleteMessage(chatId = $callback.message.get().chat.id,
            messageId = callback.message.get().messageId,
          )
      of "nothing":
        discard await bot.answerCallbackQuery(callback.id, "This button serves no purpose! ☔️", showAlert = true)
        return
      of "consent":
        var dbUser = conn.getOrInsert(database.User(userId: userId))
        dbUser.consented = args[0] == "give"
        conn.update(dbUser)
        discard await bot.answerCallbackQuery(callback.id, "Your consent settings have been successfully updated!", showAlert = true)
        discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
          text = CONSENT_TEXT,
          replyMarkup = newInlineKeyboardMarkup(
            @[
              if dbUser.consented:
                InlineKeyboardButton(text: "Revoke consent", callbackData: some "consent_revoke")
              else:
                InlineKeyboardButton(text: "Give consent", callbackData: some "consent_give")
            ],
          ),
          parseMode = "markdown",
        )
      of "usernames":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.blockUsernames = not session.chat.blockUsernames
        conn.update(session.chat)
        editSettings()
      of "links":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.blockLinks = not session.chat.blockLinks
        conn.update(session.chat)
        editSettings()
      of "markov":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.markovDisabled = not session.chat.markovDisabled
        conn.update(session.chat)
        editSettings()
      of "quotes":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.quotesDisabled = not session.chat.quotesDisabled
        conn.update(session.chat)
        editSettings()
      of "polls":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.pollsDisabled = not session.chat.pollsDisabled
        conn.update(session.chat)
        editSettings()
      of "casesensivity":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.caseSensitive = not session.caseSensitive
        conn.update(session)
        editSettings()
      of "alwaysreply":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.alwaysReply = not session.alwaysReply
        conn.update(session)
        editSettings()
      of "randomreplies":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.randomReplies = not session.randomReplies
        conn.update(session)
        editSettings()
      of "pauselearning":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.learningPaused = not session.learningPaused
        conn.update(session)
        editSettings()
      of "sfw":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.keepSfw = not session.chat.keepSfw
        conn.update(session.chat)
        editSettings()
        discard await bot.answerCallbackQuery(callback.id,
          "Done! NOTE: This feature is highly experimental, and it works for english messages only!",
          showAlert = true,
        )
        return
      of "owoify":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.owoify = (session.owoify + 1) mod 4
        conn.update(session)
        editSettings()
      of "emojipasta":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.emojipasta = not session.emojipasta
        conn.update(session)
        editSettings()

    # After any callback query
    discard await bot.answerCallbackQuery(callback.id, "Done!")
  except IOError as err:
    if "message is not modified" in err.msg:
      discard await bot.answerCallbackQuery(callback.id, "Done!")
      return
    discard await bot.answerCallbackQuery(callback.id, "😔 Oh no, an ERROR occurred, try again. " & CREATOR_STRING, showAlert = true)
    raise err

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
        threadId = getThread(response)
      if msgUser.id notin admins and chatId in banned or msgUser.id in banned:
        return true

      var
        text = if response.text.isSome: response.text.get else: response.caption.get
        splitted = text.split()
        command = splitted[0].strip(chars = {'/'}, trailing = false)
        args = if len(splitted) > 1: splitted[1 .. ^1] else: @[]

      let user = conn.getOrInsert(database.User(userId: msgUser.id))

      if text.startswith('/'):
        if msgUser.id notin admins and isFlood(chatId):
          return true

        if '@' in command:
          let splittedCommand = command.split('@')
          if splittedCommand[^1].toLower() != bot.username.toLower():
            return true
          command = splittedCommand[0]
        await handleCommand(bot, update, command, args, user)
        return true

      let chat = conn.getOrInsert(database.Chat(chatId: chatId))
      if not chat.enabled:
        return

      let cachedSession = conn.getCachedSession(chatId)

      if not cachedSession.isMessageOk(text):
        return
      elif not markovs.hasKeyOrPut(chatId, (unixTime(), newMarkov((if user.consented and not cachedSession.learningPaused: @[text] else: @[]), asLower = not cachedSession.caseSensitive))):
        conn.refillMarkov(cachedSession)
      else:
        if user.consented and not cachedSession.learningPaused:
          markovs.get(chatId).addSample(text, asLower = not cachedSession.caseSensitive)

      if user.consented and not cachedSession.learningPaused:
        conn.addMessage(database.Message(text: text, sender: user, session: conn.getCachedSession(chat.chatId)))

      if not response.chat.kind.endswith("group") and not user.consented:
        discard await bot.sendMessage(
          chatId,
          &"❕ You have not given consent to the bot's learning. Please [click here](https://t.me/{bot.username}?start=consent) to manage your data settings.",
          parseMode = "markdown",
          replyToMessageId = response.messageId,
          disableWebPagePreview = true,
          messageThreadId=threadId)
        return

      var percentage = chat.percentage
      let replyMessage = update.message.get().replyToMessage
      
      let repliedToMarkinim = replyMessage.isSome() and replyMessage.get().fromUser.isSome and replyMessage.get().fromUser.get().id == bot.id

      if repliedToMarkinim:
        percentage *= 2

      if (rand(1 .. 100) <= percentage or (percentage > 0 and repliedToMarkinim and cachedSession.alwaysReply)) and not isFlood(chatId, rate = 10, seconds = 30):
        # Max 10 messages per chat per 30 seconds

        {.cast(gcsafe).}:
          let generated = markovs.get(chatId).generate()
        if generated.isSome:
          var text = generated.get()
          if cachedSession.owoify != 0:
            {.cast(gcsafe).}:
              text = text.owoify(getOwoifyLevel(cachedSession.owoify))
          if cachedSession.emojipasta:
            {.cast(gcsafe).}:
              text = emojify(text)

          if not cachedSession.chat.quotesDisabled and rand(0 .. 30) == 20:
            # Randomly send a quote
            {.cast(gcsafe).}:
              let quotePic = genQuote(
                text = text,
                config = quoteConfig,
              )
            discard await bot.sendPhoto(chat.chatId, "file://" & quotePic)
            discard tryRemoveFile(quotePic)
          else:
            if repliedToMarkinim or (rand(1 .. 100) <= (percentage div 2) and cachedSession.randomReplies):
              discard await bot.sendMessage(chatId, text, replyToMessageId = response.messageId, messageThreadId=threadId)
            else:
              discard await bot.sendMessage(chatId, text, messageThreadId=threadId)
  except IOError as error:
    if "Bad Request: have no rights to send a message" in error.msg or "not enough rights to send text messages to the chat" in error.msg:
      try:
        if update.message.isSome():
          let chatId = update.message.get().chat.id
          discard await bot.leaveChat(chatId = $chatId)
      except: discard
    echoError &"[ERROR] | " & $error.name & ": " & error.msg & ";"
  except Exception as error:
    echoError &"[ERROR] | " & $error.name & ": " & error.msg & ";"
    # raise error
  except:
    echoError "[ERROR] Fatal: uncaught error"


proc main {.async.} =
  let
    configFile = root / "../secret.ini"
    config = if fileExists(configFile): loadConfig(configFile)
      else: loadConfig(newStringStream())
    botToken = config.getSectionValue("config", "token", getEnv("BOT_TOKEN"))
    admin = config.getSectionValue("config", "admin", getEnv("ADMIN_ID"))
    loggingEnabled = config.getSectionValue("config", "logging", getEnv("LOGGING")).strip() == "1"

  if botToken == "":
    echoError "[ERROR]: Token not provided. Check secret.ini or environment variables"
    quit(1)

  keepLast = parseInt(config.getSectionValue("config", "keeplast", getEnv("KEEP_LAST", $keepLast)))

  conn = initDatabase(MARKOV_DB)
  defer: conn.close()

  quoteConfig = getQuoteConfig()

  if admin != "":
    admins.incl(conn.setAdmin(userId = parseBiggestInt(admin)).userId)
  
  for admin in conn.getBotAdmins():
    admins.incl(admin.userId)

  for bannedUser in conn.getBannedUsers():
    banned.incl(bannedUser.userId)

  let bot = newTeleBot(botToken)
  bot.username = (await bot.getMe()).username.get().strip()
  echoError "Running... Bot username: ", bot.username

  if loggingEnabled:
    addHandler(L)
  else:
    echoError "Warning: logging is not enabled. Enable it with [LOGGING=1 in .env] or [logging = 1 in secret.ini] if needed"

  asyncCheck cleanerWorker()
  bot.onUpdate(updateHandler)
  discard await bot.getUpdates(offset = -1)

  while true:
    try:
      await bot.pollAsync(timeout = 100, clean = true)
    except:  #  Exception, Defect, IndexDefect
      echoError "Fatal error occurred. Restarting the bot..."
      echoError "getCurrentExceptionMsg(): ", getCurrentExceptionMsg()
      await sleepAsync(5000) # sleep 5 seconds and retry again


when isMainModule:
  when defined(windows):
    # This easter egg deserves to be left here
    if CompileDate != now().format("yyyy-MM-dd"):
      echoError "You can't run this on windows after a day"
      quit(1)

  try:
    waitFor main()
  except KeyboardInterrupt:
    echo "\nQuitting...\nProgram has run for ", toInt(epochTime() - uptime), " seconds."
    quit(0)
