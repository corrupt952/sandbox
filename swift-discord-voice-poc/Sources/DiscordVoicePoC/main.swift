// Discord Voice E2E receive PoC (Swift fullscratch + libdave + libopus)
//
// Connects to a real Discord voice channel as a bot, joins the DAVE (MLS-based E2EE)
// group, then receives other participants' audio via RTP -> transport decrypt
// (AES-256-GCM rtpsize) -> DAVE decrypt -> Opus decode -> per-speaker WAV output.
//
// Full pipeline:
//   [main gateway] Identify → READY → VoiceStateUpdate → VOICE_SERVER_UPDATE
//   [voice gateway v8] Hello → Identify(max_dave=1) → Ready → UDP IP Discovery
//     → SelectProtocol(aead_aes256_gcm_rtpsize) → SessionDescription(secret_key)
//   [DAVE/MLS] op25 ExternalSender → op26 KeyPackage → op27 Proposals /
//     op29 Commit / op30 Welcome → group join (per-user key ratchet)
//   [audio] UDP RTP → transport decrypt → DAVE decrypt → Opus decode → WAV
//
// DAVE wire format (confirmed against discord.js / discord-ext-voice-recv sources):
//   recv binary: [seq: uint16 BE][opcode: uint8][payload]
//   send binary: [opcode: uint8][payload]  (no seq prefix)
//   op25 ExternalSender = raw bytes / op27 Proposals = [optype:u8][MLS] /
//   op29 Commit=[tid:u16BE][commit] / op30 Welcome=[tid:u16BE][welcome]
//   op26 KeyPackage send / op28 CommitWelcome send (commit+welcome concat) are payload as-is
//   op21/22/24 recv and op23/31 send are JSON
import CLibDave
import Foundation
import Network

let startedAt = Date()

func log(_ tag: String, _ message: String) {
  let elapsed = String(format: "%7.2fs", Date().timeIntervalSince(startedAt))
  print("[\(elapsed)][\(tag)] \(message)")
  fflush(stdout)
}

func fail(_ message: String) -> Never {
  log("fatal", message)
  exit(1)
}

func loadEnv(path: String) -> [String: String] {
  guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
  var env: [String: String] = [:]
  for line in content.split(separator: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
    let key = String(trimmed[..<eq])
    var value = String(trimmed[trimmed.index(after: eq)...])
    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    env[key] = value
  }
  return env
}

extension FixedWidthInteger {
  var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}

// Received message (handles both JSON and binary)
struct GatewayMessage {
  var op: Int
  var seq: Int?
  var json: [String: Any]?
  var binaryPayload: Data?  // payload after stripping seq+opcode
  var isBinary: Bool { binaryPayload != nil }
}

final class WSClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  private var task: URLSessionWebSocketTask!
  let name: String
  var onClose: (@Sendable (Int, String) -> Void)?

  init(url: URL, name: String) {
    self.name = name
    super.init()
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    task = session.webSocketTask(with: url)
  }

  func connect() { task.resume() }
  func cancel() { task.cancel(with: .normalClosure, reason: nil) }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    log(name, "!!! closed: code=\(closeCode.rawValue) reason=\(reasonText)")
    onClose?(closeCode.rawValue, reasonText)
  }

  func sendJSON(_ json: [String: Any], note: String? = nil) async throws {
    let data = try JSONSerialization.data(withJSONObject: json)
    log(name, "send \(note ?? String(data: data, encoding: .utf8) ?? "?")")
    try await task.send(.string(String(data: data, encoding: .utf8)!))
  }

  // DAVE outbound binary frame: [opcode: uint8][payload]
  func sendBinary(opcode: UInt8, payload: Data, note: String) async throws {
    var frame = Data([opcode])
    frame.append(payload)
    log(name, "send op=\(opcode) \(note) (\(frame.count)B)")
    try await task.send(.data(frame))
  }

  func receive() async throws -> GatewayMessage {
    let message = try await task.receive()
    switch message {
    case .string(let text):
      let data = text.data(using: .utf8) ?? Data()
      let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
      return GatewayMessage(
        op: json["op"] as? Int ?? -1, seq: json["seq"] as? Int, json: json, binaryPayload: nil)
    case .data(let binary):
      guard binary.count >= 3 else {
        return GatewayMessage(op: -1, seq: nil, json: nil, binaryPayload: Data())
      }
      let bytes = [UInt8](binary)
      let seq = Int(bytes[0]) << 8 | Int(bytes[1])
      let op = Int(bytes[2])
      let payload = Data(bytes[3...])
      return GatewayMessage(op: op, seq: seq, json: nil, binaryPayload: payload)
    @unknown default:
      return GatewayMessage(op: -1, seq: nil, json: nil, binaryPayload: nil)
    }
  }
}

actor SeqBox {
  private var value: Int?
  func set(_ newValue: Int?) { value = newValue }
  func get() -> Int? { value }
}

// Tracks channel participants (excluding the bot). Used to compute recognizedUserIds.
actor Roster {
  private var participants: Set<String> = []
  func join(_ userId: String) { participants.insert(userId) }
  func leave(_ userId: String) { participants.remove(userId) }
  func all() -> Set<String> { participants }
}

// Groups mutable flags read/written from multiple async contexts and closures.
actor PoCState {
  var voiceClosed = false
  var daveInitialized = false
  var sessionDescribed = false
  var mlsJoined = false
  var secretKey: [UInt8] = []
  var epochGen = 0
  func setVoiceClosed() { voiceClosed = true }
  func markInitialized() -> Bool {
    if daveInitialized { return false }
    daveInitialized = true
    return true
  }
  func setSessionDescribed() { sessionDescribed = true }
  func setMlsJoined() { mlsJoined = true }
  func setSecretKey(_ k: [UInt8]) { secretKey = k }
  func bumpEpoch() { epochGen += 1 }
}

// SSRC<->user_id mapping (from op5 Speaking) and per-user received-PCM accumulation.
actor AudioSink {
  private var ssrcToUser: [UInt32: String] = [:]
  private var pcmByUser: [String: [Int16]] = [:]
  private var framesByUser: [String: Int] = [:]
  func mapSSRC(_ ssrc: UInt32, to userId: String) { ssrcToUser[ssrc] = userId }
  func user(for ssrc: UInt32) -> String? { ssrcToUser[ssrc] }
  func append(_ samples: [Int16], user: String) {
    pcmByUser[user, default: []].append(contentsOf: samples)
    framesByUser[user, default: 0] += 1
  }
  func allUsers() -> [String] { Array(pcmByUser.keys) }
  func pcm(for user: String) -> [Int16] { pcmByUser[user] ?? [] }
  func frameCount(for user: String) -> Int { framesByUser[user] ?? 0 }
  func summary() -> [(user: String, frames: Int, samples: Int)] {
    pcmByUser.keys.map {
      (user: $0, frames: framesByUser[$0] ?? 0, samples: pcmByUser[$0]?.count ?? 0)
    }
  }
}

// MARK: - Configuration
// Reads Bot Token / Guild / Channel from a project-local .env (or environment variables).
// See .env.example. Do not commit values (.env is gitignored).

let envPath = FileManager.default.currentDirectoryPath + "/.env"
let fileEnv = loadEnv(path: envPath)
let processEnv = ProcessInfo.processInfo.environment
func cfg(_ key: String) -> String? { fileEnv[key] ?? processEnv[key] }
guard let botToken = cfg("DISCORD_BOT_TOKEN"),
  let guildId = cfg("DISCORD_GUILD_ID"),
  let channelId = cfg("DISCORD_VOICE_CHANNEL_ID")
else {
  fail("DISCORD_BOT_TOKEN / DISCORD_GUILD_ID / DISCORD_VOICE_CHANNEL_ID required (\(envPath) or environment)")
}
guard let channelIdU64 = UInt64(channelId) else { fail("channel_id is not a valid uint64") }
let holdSeconds = Double(processEnv["VOICE_POC_HOLD"] ?? "90") ?? 90
log("cfg", "guild=\(guildId) channel=\(channelId) hold=\(Int(holdSeconds))s")

let roster = Roster()

// MARK: - 1. Main gateway (+ participant tracking)

let mainGw = WSClient(
  url: URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!, name: "main-gw")
mainGw.connect()
let mainSeq = SeqBox()

let hello = try await mainGw.receive()
guard hello.op == 10,
  let mainInterval = (hello.json?["d"] as? [String: Any])?["heartbeat_interval"] as? Double
else { fail("main-gw: no Hello") }
log("main-gw", "recv op=10 Hello interval=\(mainInterval)ms")

let mainHeartbeat = Task {
  while !Task.isCancelled {
    try? await Task.sleep(nanoseconds: UInt64(mainInterval * 1_000_000))
    let seq = await mainSeq.get()
    try? await mainGw.sendJSON(["op": 1, "d": seq ?? NSNull()], note: "op=1 Heartbeat")
  }
}

try await mainGw.sendJSON(
  [
    "op": 2,
    "d": [
      "token": botToken, "intents": 129,
      "properties": ["os": "macos", "browser": "colloq-dave-poc", "device": "colloq-dave-poc"],
    ],
  ], note: "op=2 Identify (token redacted)")

var botUserId: String?
var voiceSessionId: String?
var voiceToken: String?
var voiceEndpoint: String?

while voiceSessionId == nil || voiceToken == nil || voiceEndpoint == nil {
  let msg = try await mainGw.receive()
  if let s = msg.seq { await mainSeq.set(s) }
  let t = msg.json?["t"] as? String
  switch (msg.op, t) {
  case (0, "READY"):
    botUserId = ((msg.json?["d"] as? [String: Any])?["user"] as? [String: Any])?["id"] as? String
    log("main-gw", "recv READY user_id=\(botUserId ?? "?")")
    try await mainGw.sendJSON(
      [
        "op": 4,
        "d": [
          "guild_id": guildId, "channel_id": channelId, "self_mute": false, "self_deaf": false,
        ],
      ],
      note: "op=4 VoiceStateUpdate join")
  case (0, "VOICE_STATE_UPDATE"):
    let d = msg.json?["d"] as? [String: Any]
    let uid = d?["user_id"] as? String
    let ch = d?["channel_id"] as? String
    if uid == botUserId {
      voiceSessionId = d?["session_id"] as? String
      log("main-gw", "recv VOICE_STATE_UPDATE (self) got session_id")
    } else if let uid {
      if ch == channelId {
        await roster.join(uid)
        log("main-gw", "participant JOIN \(uid)")
      } else {
        await roster.leave(uid)
        log("main-gw", "participant LEAVE \(uid)")
      }
    }
  case (0, "VOICE_SERVER_UPDATE"):
    let d = msg.json?["d"] as? [String: Any]
    voiceToken = d?["token"] as? String
    voiceEndpoint = d?["endpoint"] as? String
    log("main-gw", "recv VOICE_SERVER_UPDATE endpoint=\(voiceEndpoint ?? "?")")
  case (0, "GUILD_CREATE"):
    // Participants already present before we connect arrive in voice_states; seed the roster here.
    let d = msg.json?["d"] as? [String: Any]
    let voiceStates = d?["voice_states"] as? [[String: Any]] ?? []
    for vs in voiceStates where vs["channel_id"] as? String == channelId {
      if let uid = vs["user_id"] as? String, uid != botUserId {
        await roster.join(uid)
        log("main-gw", "participant PRESENT \(uid) (from GUILD_CREATE)")
      }
    }
  default: break
  }
}

guard let botUserId, let voiceSessionId, let voiceToken, let voiceEndpoint else {
  fail("missing voice connection info")
}

// Keep the main gateway running to reflect participant join/leave into the roster.
let mainDrain = Task {
  while !Task.isCancelled {
    guard let msg = try? await mainGw.receive() else { break }
    if let s = msg.seq { await mainSeq.set(s) }
    if msg.op == 0, msg.json?["t"] as? String == "VOICE_STATE_UPDATE" {
      let d = msg.json?["d"] as? [String: Any]
      guard let uid = d?["user_id"] as? String, uid != botUserId else { continue }
      let ch = d?["channel_id"] as? String
      if ch == channelId {
        await roster.join(uid)
        log("main-gw", "participant JOIN \(uid)")
      } else {
        await roster.leave(uid)
        log("main-gw", "participant LEAVE \(uid)")
      }
    }
  }
}

// MARK: - 2. Voice gateway handshake

let voiceGw = WSClient(url: URL(string: "wss://\(voiceEndpoint)/?v=8")!, name: "voice-gw")
let state = PoCState()
voiceGw.onClose = { _, _ in Task { await state.setVoiceClosed() } }
voiceGw.connect()
let voiceSeq = SeqBox()

let vHello = try await voiceGw.receive()
guard vHello.op == 8,
  let voiceInterval = (vHello.json?["d"] as? [String: Any])?["heartbeat_interval"] as? Double
else { fail("voice-gw: no Hello (op8)") }
log("voice-gw", "recv op=8 Hello interval=\(voiceInterval)ms")

try await voiceGw.sendJSON(
  [
    "op": 0,
    "d": [
      "server_id": guildId, "user_id": botUserId, "session_id": voiceSessionId,
      "token": voiceToken, "max_dave_protocol_version": 1,
    ],
  ], note: "op=0 Identify (token redacted, max_dave=1)")

let voiceHeartbeat = Task {
  var nonce = 0
  while !Task.isCancelled {
    try? await Task.sleep(nanoseconds: UInt64(voiceInterval * 1_000_000))
    nonce += 1
    let seqAck = await voiceSeq.get()
    try? await voiceGw.sendJSON(
      ["op": 3, "d": ["t": nonce, "seq_ack": seqAck ?? -1]], note: "op=3 Heartbeat")
  }
}

var ssrc: UInt32?
var udpIp: String?
var udpPort: UInt16?
var modes: [String] = []
while ssrc == nil {
  let msg = try await voiceGw.receive()
  if let s = msg.seq { await voiceSeq.set(s) }
  if msg.op == 2 {
    let d = msg.json?["d"] as? [String: Any]
    ssrc = (d?["ssrc"] as? NSNumber)?.uint32Value
    udpIp = d?["ip"] as? String
    udpPort = (d?["port"] as? NSNumber)?.uint16Value
    modes = d?["modes"] as? [String] ?? []
    log("voice-gw", "recv op=2 Ready ssrc=\(ssrc ?? 0) udp=\(udpIp ?? "?"):\(udpPort ?? 0)")
  }
}
guard let ssrc, let udpIp, let udpPort else { fail("incomplete Ready") }
// Select AES-256-GCM (natively supported by CryptoKit; XChaCha20 is not).
// The transport cipher chosen in SelectProtocol also applies to received media.
let selectedMode = "aead_aes256_gcm_rtpsize"
guard modes.contains(selectedMode) else { fail("required mode not offered: \(modes)") }
// UDP IP Discovery (74 bytes). Keep the connection open so we can keep receiving.
// Port is big-endian (discord.js uses readUInt16BE). LE happened to connect earlier because
// the server uses the actual UDP source address; receiving needs the correct BE value.
let udpConn = NWConnection(host: .init(udpIp), port: .init(rawValue: udpPort)!, using: .udp)
udpConn.start(queue: .global())
try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
  udpConn.stateUpdateHandler = { st in
    switch st {
    case .ready: cont.resume()
    case .failed(let e): cont.resume(throwing: e)
    default: break
    }
  }
}
do {
  var packet = Data()
  packet.append(UInt16(0x1).bigEndianData)
  packet.append(UInt16(70).bigEndianData)
  packet.append(ssrc.bigEndianData)
  packet.append(Data(count: 66))
  udpConn.send(content: packet, completion: .contentProcessed { _ in })
}
let discResp: Data = try await withCheckedThrowingContinuation { cont in
  udpConn.receiveMessage { data, _, _, error in
    if let error {
      cont.resume(throwing: error)
    } else if let data {
      cont.resume(returning: data)
    } else {
      cont.resume(throwing: NSError(domain: "udp", code: -1))
    }
  }
}
let extAddr = String(bytes: discResp[8..<72].prefix { $0 != 0 }, encoding: .utf8) ?? "?"
let extPort = UInt16(discResp[72]) << 8 | UInt16(discResp[73])  // big-endian
log("udp", "external \(extAddr):\(extPort)")

try await voiceGw.sendJSON(
  [
    "op": 1,
    "d": [
      "protocol": "udp", "data": ["address": extAddr, "port": Int(extPort), "mode": selectedMode],
    ],
  ],
  note: "op=1 SelectProtocol")

// MARK: - 3. DAVE session and MLS flow

let daveSession = DaveSession(authSessionId: "")
guard let daveSession else { fail("failed to create DaveSession") }
let audioSink = AudioSink()

// recognizedUserIds = current participants + self
func recognizedIds() async -> [String] {
  Array(await roster.all()) + [botUserId]
}

// Log the MLS roster (UInt64 set) against the expected participants.
func verifyRoster(_ label: String, _ rosterIds: [UInt64]) async {
  let expected = Set((await roster.all()).compactMap { UInt64($0) } + [UInt64(botUserId) ?? 0])
  let got = Set(rosterIds)
  let match = expected == got
  log(
    "dave",
    "\(label): MLS roster=\(got.sorted()) expected=\(expected.sorted()) \(match ? "MATCH" : "MISMATCH")")
}

// Send KeyPackage (op26)
func sendKeyPackage() async {
  guard let kp = daveSession.marshalledKeyPackage() else {
    log("dave", "marshalledKeyPackage failed")
    return
  }
  try? await voiceGw.sendBinary(opcode: 26, payload: Data(kp), note: "KeyPackage")
}

// Epoch preparation: session Init (which Resets internally) + KeyPackage send.
// Called from both Session Description and op24 PrepareEpoch. Making it re-entrant
// correctly handles the reset to a new epoch (epoch=1) when everyone else leaves.
// (An earlier once-only guard dropped the leave-time op24 and caused an epoch mismatch.)
func prepareEpoch(version: UInt16) async {
  await state.markInitialized()
  await state.bumpEpoch()
  daveSession.initialize(version: version, groupId: channelIdU64, selfUserId: botUserId)
  log("dave", "session (re)init version=\(version) groupId=channel selfUserId=\(botUserId)")
  await sendKeyPackage()
}

// Send op23 Transition Ready (only when transition_id != 0)
func sendTransitionReady(_ transitionId: Int) async {
  guard transitionId != 0 else { return }
  try? await voiceGw.sendJSON(
    ["op": 23, "d": ["transition_id": transitionId]],
    note: "op=23 TransitionReady tid=\(transitionId)")
}

// MARK: - 4. Wait for Session Description, then drive the DAVE flow

func handleVoiceMessage(_ msg: GatewayMessage) async {
  switch msg.op {
  case 4:  // Session Description (JSON)
    let d = msg.json?["d"] as? [String: Any]
    let keyArr = (d?["secret_key"] as? [Any])?.compactMap { ($0 as? NSNumber)?.uint8Value } ?? []
    let daveVersion = (d?["dave_protocol_version"] as? NSNumber)?.intValue ?? 0
    log(
      "voice-gw",
      "recv op=4 SessionDescription secret_key=\(keyArr.count)B dave_version=\(daveVersion)"
    )
    await state.setSecretKey(keyArr)
    await state.setSessionDescribed()
    if daveVersion > 0 { await prepareEpoch(version: UInt16(daveVersion)) }

  case 5:  // Speaking (JSON) - update the SSRC<->user_id map
    let d = msg.json?["d"] as? [String: Any]
    if let ssrcNum = (d?["ssrc"] as? NSNumber)?.uint32Value, let uid = d?["user_id"] as? String {
      await audioSink.mapSSRC(ssrcNum, to: uid)
      log("voice-gw", "op=5 Speaking ssrc=\(ssrcNum) user=\(uid)")
    }

  case 25:  // MLS External Sender (binary, raw bytes)
    guard let p = msg.binaryPayload else { break }
    daveSession.setExternalSender([UInt8](p))
    log("dave", "op=25 setExternalSender (\(p.count)B)")

  case 27:  // MLS Proposals (binary, pass the whole [optype][MLS])
    guard let p = msg.binaryPayload else { break }
    let optype = p.first ?? 0
    let ids = await recognizedIds()
    log("dave", "op=27 Proposals optype=\(optype) recognized=\(ids)")
    if let commitWelcome = daveSession.processProposals([UInt8](p), recognizedUserIds: ids) {
      try? await voiceGw.sendBinary(opcode: 28, payload: Data(commitWelcome), note: "CommitWelcome")
    } else {
      log(
        "dave", "⚠️ processProposals returned nil (failures=\(daveSession.failureRecorder.failures))"
      )
    }

  case 29:  // Announce Commit Transition (binary, [tid:u16BE][commit])
    guard let p = msg.binaryPayload, p.count >= 2 else { break }
    let bytes = [UInt8](p)
    let tid = Int(bytes[0]) << 8 | Int(bytes[1])
    let commit = Array(bytes[2...])
    if let outcome = daveSession.processCommit(commit) {
      log(
        "dave", "op=29 processCommit tid=\(tid) failed=\(outcome.failed) ignored=\(outcome.ignored)"
      )
      if !outcome.failed && !outcome.ignored {
        await state.setMlsJoined()
        await verifyRoster("after commit(tid=\(tid))", outcome.rosterMemberIds)
        await sendTransitionReady(tid)
      }
    } else {
      log("dave", "⚠️ processCommit returned nil")
    }

  case 30:  // MLS Welcome (binary, [tid:u16BE][welcome])
    guard let p = msg.binaryPayload, p.count >= 2 else { break }
    let bytes = [UInt8](p)
    let tid = Int(bytes[0]) << 8 | Int(bytes[1])
    let welcome = Array(bytes[2...])
    let ids = await recognizedIds()
    if let rosterIds = daveSession.processWelcome(welcome, recognizedUserIds: ids) {
      await state.setMlsJoined()
      log("dave", "op=30 processWelcome tid=\(tid) joined")
      await verifyRoster("after welcome(tid=\(tid))", rosterIds)
      await sendTransitionReady(tid)
    } else {
      log("dave", "processWelcome returned nil -> resending KeyPackage")
      await sendKeyPackage()
    }

  case 21:  // Prepare Transition (JSON)
    let d = msg.json?["d"] as? [String: Any]
    let tid = (d?["transition_id"] as? NSNumber)?.intValue ?? 0
    log("dave", "op=21 PrepareTransition tid=\(tid)")
    await sendTransitionReady(tid)

  case 22:  // Execute Transition (JSON) - start using the new epoch's key ratchet
    let d = msg.json?["d"] as? [String: Any]
    let tid = (d?["transition_id"] as? NSNumber)?.intValue ?? 0
    log("dave", "op=22 ExecuteTransition tid=\(tid)")
    await state.bumpEpoch()

  case 24:  // Prepare Epoch (JSON) - re-init into a new MLS group on epoch=1
    let d = msg.json?["d"] as? [String: Any]
    let epochRaw = d?["epoch"]
    let epoch = (epochRaw as? NSNumber)?.intValue ?? Int("\(epochRaw ?? "")")
    let ver = (d?["protocol_version"] as? NSNumber)?.intValue ?? 0
    log("dave", "op=24 PrepareEpoch epoch=\(epoch ?? -1) version=\(ver)")
    if ver > 0, epoch == 1 { await prepareEpoch(version: UInt16(ver)) }

  case 6:
    break  // HeartbeatACK

  default:
    log(
      "voice-gw",
      "recv op=\(msg.op)\(msg.isBinary ? " [binary \(msg.binaryPayload?.count ?? 0)B]" : "")")
  }
}

// Block until Session Description is received
while await !state.sessionDescribed {
  let msg = try await voiceGw.receive()
  if let s = msg.seq { await voiceSeq.set(s) }
  await handleVoiceMessage(msg)
}

log("poc", "=== handshake complete. DAVE MLS phase + \(Int(holdSeconds))s watch ===")

// MARK: - 4.5 UDP audio receive pipeline
// RTP recv -> transport decrypt (AES-GCM) -> DAVE decrypt (per-user ratchet) -> Opus decode -> PCM accumulate
// Decoders/decryptors are kept in task-local dictionaries (safe under single-task access).
// Epoch transitions are detected via state.epochGen; decryptors are dropped and ratchets refetched.

let udpReceive = Task { @Sendable in
  var decoders: [UInt32: OpusMonoDecoder] = [:]
  var decryptors: [String: DaveDecryptor] = [:]
  var localEpochGen = await state.epochGen
  var rawCount = 0
  var rtpCount = 0
  var decodedCount = 0
  var transportFail = 0
  var daveFail = 0

  while !Task.isCancelled {
    let packet: Data? = await withCheckedContinuation { cont in
      udpConn.receiveMessage { data, _, _, _ in cont.resume(returning: data) }
    }
    guard let packet else { continue }
    rawCount += 1
    // Log the first few raw packets to distinguish 'no packets' from 'decrypt failure'.
    if rawCount <= 8 {
      let head = [UInt8](packet.prefix(4)).map { String(format: "%02x", $0) }.joined(separator: " ")
      log("udp", "raw#\(rawCount) len=\(packet.count) head=[\(head)]")
    }
    guard packet.count > 12 else { continue }
    guard let header = parseRTPHeader(packet), header.payloadType == 0x78 else { continue }
    rtpCount += 1
    if rtpCount <= 3 {
      log(
        "audio",
        "RTP#\(rtpCount) ssrc=\(header.ssrc) headerLen=\(header.headerLen) len=\(packet.count)")
    }

    // Rebuild decryptors when the epoch changes (key ratchets are regenerated).
    let gen = await state.epochGen
    if gen != localEpochGen {
      decryptors.removeAll()
      localEpochGen = gen
      log("audio", "decryptors invalidated (epoch gen=\(gen))")
    }

    guard let userId = await audioSink.user(for: header.ssrc) else { continue }
    let key = await state.secretKey
    let diag = rtpCount <= 5
    guard let daveFrame = TransportCrypto.decryptRTPSize(packet: packet, secretKey: key) else {
      transportFail += 1
      if diag { log("audio", "RTP#\(rtpCount) ⚠️ transport decrypt FAIL") }
      continue
    }
    if diag { log("audio", "RTP#\(rtpCount) transport OK → daveFrame \(daveFrame.count)B") }

    // Per-user DAVE decryptor (create it by fetching the key ratchet if absent).
    let decryptor: DaveDecryptor
    if let existing = decryptors[userId] {
      decryptor = existing
    } else {
      guard let ratchet = daveSession.keyRatchet(userId: userId), let dec = DaveDecryptor() else {
        if diag { log("audio", "RTP#\(rtpCount) keyRatchet fetch failed user=\(userId)") }
        continue
      }
      dec.transitionToKeyRatchet(ratchet)
      decryptors[userId] = dec
      decryptor = dec
    }

    let dres = decryptor.decrypt(mediaType: DAVE_MEDIA_TYPE_AUDIO, frame: daveFrame)
    if diag {
      log(
        "audio", "RTP#\(rtpCount) dave decrypt code=\(dres.code.rawValue) out=\(dres.bytes.count)B")
    }
    guard dres.code == DAVE_DECRYPTOR_RESULT_CODE_SUCCESS, !dres.bytes.isEmpty else {
      daveFail += 1
      continue
    }

    // Opus decode -> 48kHz mono PCM
    let decoder: OpusMonoDecoder
    if let existing = decoders[header.ssrc] {
      decoder = existing
    } else {
      guard let d = OpusMonoDecoder() else { continue }
      decoders[header.ssrc] = d
      decoder = d
    }
    guard let pcm = decoder.decode(dres.bytes) else { continue }
    await audioSink.append(pcm, user: userId)
    decodedCount += 1
    if decodedCount % 100 == 1 {
      log(
        "audio",
        "rtp=\(rtpCount) decoded=\(decodedCount) transportFail=\(transportFail) daveFail=\(daveFail)"
      )
    }
  }
}

// UDP keep-alive (maintains the NAT mapping. 8 bytes, first 4B = UInt32LE counter, every 5s)
let udpKeepAlive = Task { @Sendable in
  var counter: UInt32 = 0
  while !Task.isCancelled {
    var buf = Data(count: 8)
    buf.replaceSubrange(0..<4, with: withUnsafeBytes(of: counter.littleEndian) { Data($0) })
    udpConn.send(content: buf, completion: .contentProcessed { _ in })
    counter &+= 1
    try? await Task.sleep(nanoseconds: 5_000_000_000)
  }
}

// MARK: - 5. Steady state (process DAVE messages + watch roster changes)

let deadline = Task {
  try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
  log("poc", "=== watch ended. cleaning up ===")
  try? await mainGw.sendJSON(
    [
      "op": 4,
      "d": ["guild_id": guildId, "channel_id": NSNull(), "self_mute": false, "self_deaf": false],
    ],
    note: "op=4 VoiceStateUpdate leave")
  try? await Task.sleep(nanoseconds: 1_000_000_000)
  udpReceive.cancel()
  udpKeepAlive.cancel()
  mainHeartbeat.cancel()
  voiceHeartbeat.cancel()
  mainDrain.cancel()
  voiceGw.cancel()
  mainGw.cancel()

  // Write one WAV per user
  let outDir = FileManager.default.currentDirectoryPath + "/output"
  try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
  let summary = await audioSink.summary()
  for entry in summary {
    let pcm = await audioSink.pcm(for: entry.user)
    let path = "\(outDir)/\(entry.user).wav"
    writeWAV(path: path, samples: pcm)
    let seconds = Double(pcm.count) / 48000.0
    log(
      "audio",
      "wrote WAV user=\(entry.user) frames=\(entry.frames) samples=\(pcm.count) (\(String(format: "%.1f", seconds))s) -> \(path)"
    )
  }

  let joined = await state.mlsJoined
  let joinedText = joined ? "MLS group joined" : "MLS not joined (needs investigation)"
  let audioOK = !summary.isEmpty
  log(
    "poc",
    "RESULT: \(joinedText) / audio=\(audioOK ? "ok (\(summary.count) user(s))" : "none") / participants=\(await roster.all())"
  )
  exit(joined && audioOK ? 0 : 2)
}

while true {
  guard let msg = try? await voiceGw.receive() else {
    if await state.voiceClosed { break }
    log("voice-gw", "receive loop ended")
    break
  }
  if let s = msg.seq { await voiceSeq.set(s) }
  await handleVoiceMessage(msg)
}

// Even if the receive loop exits, wait for the deadline task to exit the process
try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
