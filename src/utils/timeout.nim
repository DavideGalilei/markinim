import std / asyncdispatch

type TimeoutError* = ref object of CatchableError
  timeout*: int

proc timeoutFuture*[T](future: Future[T], timeout: int): Future[T] {.async.} =
  let timeoutFuture = sleepAsync(timeout * 1000)
  timeoutFuture.callback = proc =
    if not future.finished:
      future.fail(TimeoutError(msg: "The future didn't complete in time", timeout: timeout))
  return await future

when isMainModule:
  proc longOperation(s: int): Future[int] {.async.} =
    await sleepAsync(s * 1000)
    return s

  proc main {.async.} =
    const TIMEOUT_SECONDS = 4
    let x = await timeoutFuture(longOperation(2), timeout = TIMEOUT_SECONDS)
    echo "Got x value: ", x

    let y = await timeoutFuture(longOperation(6), timeout = TIMEOUT_SECONDS)
    echo "Got y value: ", y

  waitFor main()
