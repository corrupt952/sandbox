// A thin Swift wrapper around the libdave C API.
// Opaque-handle lifetimes ride on class deinit; output buffers owned by daveFree are
// copied into [UInt8] and freed immediately.
import CLibDave
import Foundation

// Sink for MLS failure callbacks. C function pointers cannot capture context, so we use a
// trampoline that passes an Unmanaged reference through userData.
final class MLSFailureRecorder {
  private(set) var failures: [(source: String, reason: String)] = []
  func record(source: String, reason: String) {
    failures.append((source, reason))
  }
}

private let mlsFailureTrampoline: DAVEMLSFailureCallback = { source, reason, userData in
  guard let userData else { return }
  let recorder = Unmanaged<MLSFailureRecorder>.fromOpaque(userData).takeUnretainedValue()
  recorder.record(
    source: source.map { String(cString: $0) } ?? "",
    reason: reason.map { String(cString: $0) } ?? "")
}

private func withCStringArray<R>(
  _ strings: [String],
  _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>, Int) -> R
) -> R {
  let cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
  defer { cStrings.forEach { free($0) } }
  var pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
  return pointers.withUnsafeMutableBufferPointer { buffer in
    body(buffer.baseAddress!, strings.count)
  }
}

private func copyAndFree(_ bytes: UnsafeMutablePointer<UInt8>?, _ length: Int) -> [UInt8]? {
  guard let bytes, length > 0 else {
    if let bytes { daveFree(bytes) }
    return nil
  }
  let copied = Array(UnsafeBufferPointer(start: bytes, count: length))
  daveFree(bytes)
  return copied
}

final class DaveKeyRatchet: @unchecked Sendable {
  let handle: DAVEKeyRatchetHandle
  init(handle: DAVEKeyRatchetHandle) {
    self.handle = handle
  }
  deinit { daveKeyRatchetDestroy(handle) }
}

struct CommitOutcome {
  let failed: Bool
  let ignored: Bool
  let rosterMemberIds: [UInt64]
}

final class DaveSession: @unchecked Sendable {
  let handle: DAVESessionHandle
  // Held for the session's lifetime so it can be passed as the callback's userData.
  let failureRecorder: MLSFailureRecorder

  init?(authSessionId: String) {
    let recorder = MLSFailureRecorder()
    let userData = Unmanaged.passUnretained(recorder).toOpaque()
    guard let handle = daveSessionCreate(nil, authSessionId, mlsFailureTrampoline, userData) else {
      return nil
    }
    self.handle = handle
    self.failureRecorder = recorder
  }

  deinit { daveSessionDestroy(handle) }

  func initialize(version: UInt16, groupId: UInt64, selfUserId: String) {
    daveSessionInit(handle, version, groupId, selfUserId)
  }

  var protocolVersion: UInt16 {
    daveSessionGetProtocolVersion(handle)
  }

  func setExternalSender(_ externalSender: [UInt8]) {
    daveSessionSetExternalSender(handle, externalSender, externalSender.count)
  }

  func marshalledKeyPackage() -> [UInt8]? {
    var out: UnsafeMutablePointer<UInt8>?
    var outLength: Int = 0
    daveSessionGetMarshalledKeyPackage(handle, &out, &outLength)
    return copyAndFree(out, outLength)
  }

  func processProposals(_ proposals: [UInt8], recognizedUserIds: [String]) -> [UInt8]? {
    var out: UnsafeMutablePointer<UInt8>?
    var outLength: Int = 0
    withCStringArray(recognizedUserIds) { ids, count in
      daveSessionProcessProposals(handle, proposals, proposals.count, ids, count, &out, &outLength)
    }
    return copyAndFree(out, outLength)
  }

  func processCommit(_ commit: [UInt8]) -> CommitOutcome? {
    guard let result = daveSessionProcessCommit(handle, commit, commit.count) else {
      return nil
    }
    defer { daveCommitResultDestroy(result) }

    var ids: UnsafeMutablePointer<UInt64>?
    var idsLength: Int = 0
    daveCommitResultGetRosterMemberIds(result, &ids, &idsLength)
    var roster: [UInt64] = []
    if let ids, idsLength > 0 {
      roster = Array(UnsafeBufferPointer(start: ids, count: idsLength))
    }
    if let ids { daveFree(ids) }

    return CommitOutcome(
      failed: daveCommitResultIsFailed(result),
      ignored: daveCommitResultIsIgnored(result),
      rosterMemberIds: roster)
  }

  func processWelcome(_ welcome: [UInt8], recognizedUserIds: [String]) -> [UInt64]? {
    let result = withCStringArray(recognizedUserIds) { ids, count in
      daveSessionProcessWelcome(handle, welcome, welcome.count, ids, count)
    }
    guard let result else { return nil }
    defer { daveWelcomeResultDestroy(result) }

    var ids: UnsafeMutablePointer<UInt64>?
    var idsLength: Int = 0
    daveWelcomeResultGetRosterMemberIds(result, &ids, &idsLength)
    guard let ids, idsLength > 0 else {
      if let ids { daveFree(ids) }
      return nil
    }
    let roster = Array(UnsafeBufferPointer(start: ids, count: idsLength))
    daveFree(ids)
    return roster
  }

  func keyRatchet(userId: String) -> DaveKeyRatchet? {
    guard let ratchet = daveSessionGetKeyRatchet(handle, userId) else { return nil }
    return DaveKeyRatchet(handle: ratchet)
  }
}

final class DaveEncryptor: @unchecked Sendable {
  let handle: DAVEEncryptorHandle
  // SetKeyRatchet does not take ownership, so we keep the ratchet alive here.
  private var retainedRatchet: DaveKeyRatchet?

  init?() {
    guard let handle = daveEncryptorCreate() else { return nil }
    self.handle = handle
  }

  deinit { daveEncryptorDestroy(handle) }

  func assignSsrc(_ ssrc: UInt32, codec: DAVECodec) {
    daveEncryptorAssignSsrcToCodec(handle, ssrc, codec)
  }

  func setKeyRatchet(_ ratchet: DaveKeyRatchet) {
    retainedRatchet = ratchet
    daveEncryptorSetKeyRatchet(handle, ratchet.handle)
  }

  func setPassthrough(_ enabled: Bool) {
    daveEncryptorSetPassthroughMode(handle, enabled)
  }

  func encrypt(
    mediaType: DAVEMediaType, ssrc: UInt32, frame: [UInt8]
  ) -> (code: DAVEEncryptorResultCode, bytes: [UInt8]) {
    let capacity = max(daveEncryptorGetMaxCiphertextByteSize(handle, mediaType, frame.count), 1)
    var output = [UInt8](repeating: 0, count: capacity)
    var written: Int = 0
    let code = output.withUnsafeMutableBufferPointer { buffer in
      daveEncryptorEncrypt(
        handle, mediaType, ssrc, frame, frame.count, buffer.baseAddress, buffer.count, &written)
    }
    return (code, Array(output.prefix(written)))
  }
}

final class DaveDecryptor: @unchecked Sendable {
  let handle: DAVEDecryptorHandle
  private var retainedRatchet: DaveKeyRatchet?

  init?() {
    guard let handle = daveDecryptorCreate() else { return nil }
    self.handle = handle
  }

  deinit { daveDecryptorDestroy(handle) }

  func transitionToKeyRatchet(_ ratchet: DaveKeyRatchet) {
    retainedRatchet = ratchet
    daveDecryptorTransitionToKeyRatchet(handle, ratchet.handle)
  }

  func transitionToPassthrough(_ enabled: Bool) {
    daveDecryptorTransitionToPassthroughMode(handle, enabled)
  }

  func decrypt(
    mediaType: DAVEMediaType, frame: [UInt8]
  ) -> (code: DAVEDecryptorResultCode, bytes: [UInt8]) {
    let capacity = max(daveDecryptorGetMaxPlaintextByteSize(handle, mediaType, frame.count), 1)
    var output = [UInt8](repeating: 0, count: capacity)
    var written: Int = 0
    let code = output.withUnsafeMutableBufferPointer { buffer in
      daveDecryptorDecrypt(
        handle, mediaType, frame, frame.count, buffer.baseAddress, buffer.count, &written)
    }
    return (code, Array(output.prefix(written)))
  }
}
