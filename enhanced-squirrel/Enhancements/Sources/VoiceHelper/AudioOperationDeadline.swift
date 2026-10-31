import Foundation

// This queue never executes audio-driver work. A timeout on the audio control
// queue itself cannot protect a call which has stopped returning.
final class AudioOperationDeadline {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "org.rime.audio.deadline")
  private var owner: UUID?
  private var work: DispatchWorkItem?

  @discardableResult func arm(seconds: TimeInterval, expired: @escaping () -> Void) -> UUID {
    let ticket = UUID()
    let item = DispatchWorkItem { [weak self] in
      guard self?.complete(ticket) == true else { return }
      expired()
    }
    lock.lock(); work?.cancel(); owner = ticket; work = item; lock.unlock()
    queue.asyncAfter(deadline: .now() + seconds, execute: item)
    return ticket
  }
  @discardableResult func complete(_ ticket: UUID) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard owner == ticket else { return false }
    owner = nil; work?.cancel(); work = nil
    return true
  }
  deinit { work?.cancel() }
}
