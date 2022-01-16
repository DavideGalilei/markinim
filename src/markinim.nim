import std/[asyncdispatch, logging, options, os, times, strutils, strformat, tables]
import telebot, norm / [model, sqlite]
import ./database

var L = newConsoleLogger(fmtStr="$levelname, [$time] ")
addHandler(L)

const API_KEY = slurp("../secret.key").strip()
var conn: DbConn
let t = epochTime()


type KeyboardInterrupt = ref object of CatchableError
proc handler() {.noconv.} =
  raise KeyboardInterrupt(msg: "Keyboard Interrupt")
setControlCHook(handler)


proc handleCommand(bot: Telebot, update: Update, user: database.User) {.async.} =
  let
    message = update.message.get
    text = message.text.get
    splitted = text.split()
    command = splitted[0].strip(chars = {'/'}, trailing = false)
    args = if len(splitted) > 1: splitted[1 .. ^1] else: @[]

  case command:
  of "start":
    if message.chat.id != user.userId: # /start only works in PMs
      return
    discard await bot.sendMessage(message.chat.id, "gtfo")
  of "admin", "unadmin":
    if len(args) < 1:
      return
    elif not user.admin:
      discard await bot.sendMessage(message.chat.id, &"You are not allowed to perform this command")
      return

    try:
      let userId = parseBiggestInt(args[0])
      discard conn.setAdmin(userId = userId, admin = (command == "admin"))

      discard await bot.sendMessage(message.chat.id,
        if command == "admin": &"Successfully promoted [{userId}](tg://user?id={userId})"
        else: &"Successfully demoted [{userId}](tg://user?id={userId})",
        parseMode = "markdown")
    except Exception:
      discard await bot.sendMessage(message.chat.id, &"An error occurred: <code>{getCurrentExceptionMsg()}</code>", parseMode = "html")


proc updateHandler(bot: Telebot, u: Update): Future[bool] {.async, gcsafe.} =
  if not u.message.isSome:
    # return true will make bot stop process other callbacks
    return true

  let response = u.message.get
  let msgUser = response.fromUser.get

  let user = conn.getOrInsert(database.User(userId: msgUser.id))

  if response.text.isSome:
    let text = response.text.get
    if text.startswith('/'):
      await bot.handleCommand(u, user)
      return true

when isMainModule:
  try:
    conn = initDatabase("markov.db")
    let bot = newTeleBot(API_KEY)
    bot.onUpdate(updateHandler)
    bot.poll(timeout=300)
  except KeyboardInterrupt:
    echo "\nQuitting...\nProgram has run for ", formatFloat(epochTime() - t, precision = 0), " seconds."
    quit(0)
