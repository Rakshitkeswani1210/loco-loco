import Foundation

// Sends commands to a Loco Loco built with `scripts/build.sh --test-hooks`.
// Usage: loco-test <command> [<command> ...]   A command of "sleep <seconds>" waits instead.
let center = DistributedNotificationCenter.default()
for arg in CommandLine.arguments.dropFirst() {
  if arg.hasPrefix("sleep "), let s = Double(arg.dropFirst(6)) {
    Thread.sleep(forTimeInterval: s)
    continue
  }
  center.postNotificationName(.init("com.rakshit.locoloco.test"), object: arg, userInfo: nil, deliverImmediately: true)
}
Thread.sleep(forTimeInterval: 0.05)
