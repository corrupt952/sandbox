import CLibDave

let version = daveMaxSupportedProtocolVersion()
print("DAVE max supported protocol version: \(version)")

guard let session = daveSessionCreate(nil, "poc-auth-session", nil, nil) else {
  fatalError("daveSessionCreate returned NULL")
}
print("daveSessionCreate succeeded: \(session)")

daveSessionInit(session, UInt16(version), 12345, "poc-user-id")
print("daveSessionInit called")

print("session protocol version: \(daveSessionGetProtocolVersion(session))")

daveSessionDestroy(session)
print("daveSessionDestroy called")
