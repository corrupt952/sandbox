import Foundation

// EventKit を使わずに「dispatchMain() だと main queue がデッドロックし、
// RunLoop.main.run() なら生き続ける」メカニズムを再現する最小デモ。
//
// 使い方:
//   HangDemoCore            → dispatchMain() で待機 (ハング再現、exit 1)
//   HangDemoCore --runloop  → RunLoop.main.run() で待機 (正常継続、exit 0)

let usesRunLoop = CommandLine.arguments.contains("--runloop")
let startedAt = Date()

// パイプ越し (SwiftUI ビューアなど) でも出力が即座に流れるようにする
setvbuf(stdout, nil, _IONBF, 0)

final class AtomicCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  @discardableResult
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }

  var current: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func store(_ newValue: Int) {
    lock.lock()
    defer { lock.unlock() }
    value = newValue
  }
}

let heartbeat = AtomicCounter()
let checkpoint = AtomicCounter()

func log(_ message: String) {
  let elapsed = String(format: "%+5.1fs", Date().timeIntervalSince(startedAt))
  let thread = Thread.isMainThread ? "main-thread" : "worker-thread"
  print("[\(elapsed)][\(thread)] \(message)")
}

/// EventKit の reminderStoreChanged 相当の配送処理。
///
/// Foundation の通知配送 (_CFXNotificationPost) は「本物のメインスレッド上か」で
/// 経路を変える。メインスレッド上ならインライン配送だが、そうでなければ
/// OperationQueue.main へ operation を積み、waitUntilFinished で完了を待つ。
/// dispatchMain() は main queue のブロックを [ワーカースレッドで代行実行] するため
/// 後者の経路に入り、operation は誰にも実行されず永久に待つ。
func deliverNotificationLikeEventKit() {
  log("配送コンテキスト: Thread.isMainThread = \(Thread.isMainThread)")

  if Thread.isMainThread {
    log("→ 本物のメインスレッド上なのでインライン配送。待ちは発生しない")
    return
  }

  log("→ メインスレッドではない (dispatchMain は main queue をワーカーで代行実行するため)")
  log("→ OperationQueue.main に operation を積み waitUntilFinished で待機…ここで詰まる")
  let operation = BlockOperation {
    log("operation 実行 (ハング時はここに到達しない)")
  }
  OperationQueue.main.addOperation(operation)
  operation.waitUntilFinished()
  log("waitUntilFinished から復帰")
}

// 0.5 秒ごとに main queue へハートビートを流し、main queue の生死を可視化する
let heartbeatTimer = DispatchSource.makeTimerSource(queue: .global())
heartbeatTimer.schedule(deadline: .now() + 0.5, repeating: 0.5)
heartbeatTimer.setEventHandler {
  DispatchQueue.main.async {
    let count = heartbeat.increment()
    log("main queue heartbeat #\(count)")
  }
}
heartbeatTimer.resume()

// +2.0 秒: EventKit 風の変更通知が main queue に到着する
DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
  DispatchQueue.main.async {
    log("=== EventKit 風の変更通知が main queue に到着 ===")
    deliverNotificationLikeEventKit()
    log("=== 通知配送が完了。main queue は健在 ===")
  }
}

// +2.5 秒: 通知到着直後のハートビート数を記録
DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
  checkpoint.store(heartbeat.current)
}

// +4.5 秒: ハートビートが進んでいるかで自動判定して終了する
DispatchQueue.global().asyncAfter(deadline: .now() + 4.5) {
  let before = checkpoint.current
  let after = heartbeat.current
  if after > before {
    print("")
    print("結果: ✅ ALIVE — main queue は流れ続けています (heartbeat \(before) → \(after))")
    exit(0)
  } else {
    print("")
    print("結果: ❌ HANG — 通知配送以降、main queue が閉塞しています (heartbeat \(after) で停止)")
    exit(1)
  }
}

if usesRunLoop {
  log("待機方式: RunLoop.main.run() — RunLoop ソースも main queue も両方捌く")
  RunLoop.main.run()
} else {
  log("待機方式: dispatchMain() — main queue しか捌かず、RunLoop は回らない")
  dispatchMain()
}
