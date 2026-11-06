// Apple SDK compilation and device execution have not been verified.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Resolves only the signed, bundled kernel. The handle deliberately lives for
/// the process lifetime: kernel threads and callbacks can outlive a Flutter view.
final class NativeGuestKernelAccess: GuestKernelAccess {
  static let shared = NativeGuestKernelAccess()
  private typealias Status = @convention(c) () -> Int32
  private typealias End = @convention(c) () -> Void
  private struct Symbols {
    let handle: UnsafeMutableRawPointer?
    let status: Status?
    let begin: Status?
    let end: End?
  }
  private let loadLock = NSLock()
  private var loaded: Symbols?

  private init() {}

  // Registering the Flutter channel does not map iSH into memory. Resolve on
  // the first explicit capability/install request or installed-engine start.
  private func symbols() -> Symbols {
    loadLock.lock()
    defer { loadLock.unlock() }
    if let loaded { return loaded }
    let path = Bundle.main.privateFrameworksPath.map { $0 + "/DshGuest.framework/DshGuest" }
    let handle = path.flatMap { dlopen($0, RTLD_NOW | RTLD_LOCAL) }
    let value: Symbols
    if let handle,
       let statusSymbol = dlsym(handle, "dsh_guest_status"),
       let beginSymbol = dlsym(handle, "dsh_guest_begin_install_change"),
       let endSymbol = dlsym(handle, "dsh_guest_end_install_change") {
      value = Symbols(handle: handle, status: unsafeBitCast(statusSymbol, to: Status.self),
        begin: unsafeBitCast(beginSymbol, to: Status.self), end: unsafeBitCast(endSymbol, to: End.self))
    } else { value = Symbols(handle: handle, status: nil, begin: nil, end: nil) }
    loaded = value
    return value
  }

  var available: Bool {
    let value = symbols()
    guard let status = value.status, value.begin != nil, value.end != nil else { return false }
    // COLD, READY and RUNNING expose the capability; QUARANTINED cannot run.
    return (0...2).contains(status())
  }

  func reserveRootfsMutation() throws -> GuestRootfsLease {
    let value = symbols()
    guard let status = value.status, let begin = value.begin, let end = value.end else {
      throw GuestFailure("unavailable", "The Linux backend is unavailable in this build.")
    }
    // The native gate, not this status observation, admits the mutation atomically.
    guard begin() == 0 else {
      if status() != 0 {
        throw GuestFailure("restart_required", "Restart the app before changing the Linux installation; its kernel has already started.")
      }
      throw GuestFailure("busy", "The Linux installation is in use; retry after the current operation finishes.")
    }
    return NativeGuestRootfsLease(end: end)
  }
}

private final class NativeGuestRootfsLease: GuestRootfsLease {
  private let lock = NSLock()
  private var end: (@convention(c) () -> Void)?
  init(end: @escaping @convention(c) () -> Void) { self.end = end }
  func release() {
    lock.lock()
    let action = end
    end = nil
    // Keep release linearized: a second caller cannot return before the native
    // gate has been released by the first caller.
    action?()
    lock.unlock()
  }
  deinit { release() }
}
