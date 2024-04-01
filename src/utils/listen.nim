import std / [asyncdispatch, tables, options, oids]
import telebot

import ./timeout

type Record[T] = tuple[pair: (int64, int64), future: Future[T]]

var
  pendingMessages {.threadvar.}: Table[string, Record[Update]] # (uuid): ((userId, chatId), Update Future)


proc listenUpdater*(bot: Telebot, update: Update): Future[bool] {.async, gcsafe.} =
  if not update.message.isSome():
    return

  let
    response = update.message.get()
    userId = response.fromUser.get().id.int64
    chatId = response.chat.id

  for uuid, record in pendingMessages.pairs():
    if (userId, chatId) == record.pair:
      pendingMessages.del(uuid)
      record.future.complete(update)
      return true


const DEFAULT_TIMEOUT = 60 * 3 # 3 minutes
proc getMessage*(userId, chatId: int64, timeout: int = DEFAULT_TIMEOUT): Future[Update] {.async, gcsafe.} =
  let future = newFuture[Update]("getMessage")
  pendingMessages[$genOid()] = ((userId, chatId), future)
  return await timeoutFuture(future, timeout = timeout)
