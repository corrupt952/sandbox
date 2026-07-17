// Receive-side audio pipeline components:
// transport decrypt (AES-256-GCM rtpsize) -> DAVE decrypt -> Opus decode -> WAV write.
import CLibOpus
import CryptoKit
import Foundation

// MARK: - Transport decryption (aead_aes256_gcm_rtpsize)

enum TransportCrypto {
  // Receive-side decrypt for aead_aes256_gcm_rtpsize (follows discord-ext-voice-recv).
  //
  // Packet: [base RTP header 12+4*CC][ext preamble 4 (if X)][ciphertext+authTag 16B][nonce 4B]
  // - AAD = base header + ext preamble (profile 2B + length 2B). Ext VALUES are NOT included.
  // - nonce (12B) = trailing 4B (BE counter) + 8 zero bytes.
  // - ciphertext = after AAD .. before the trailing 4B nonce; last 16B is the auth tag.
  // - After decryption, the ext values (length*4 bytes) are encrypted, so stripping them
  //   from the front yields the DAVE/Opus frame.
  static func decryptRTPSize(packet: Data, secretKey: [UInt8]) -> [UInt8]? {
    let b = [UInt8](packet)
    guard b.count >= 12 else { return nil }
    let cc = Int(b[0] & 0x0F)
    let extended = (b[0] & 0x10) != 0
    let baseHeaderLen = 12 + 4 * cc
    let aadLen = baseHeaderLen + (extended ? 4 : 0)
    guard b.count >= aadLen + 16 + 4 else { return nil }

    let aad = Array(b[0..<aadLen])
    let noncePad = Array(b[(b.count - 4)...])
    var nonce12 = [UInt8](repeating: 0, count: 12)
    for i in 0..<4 { nonce12[i] = noncePad[i] }
    let encRegion = Array(b[aadLen..<(b.count - 4)])
    guard encRegion.count >= 16 else { return nil }
    let ciphertext = Array(encRegion[0..<(encRegion.count - 16)])
    let tag = Array(encRegion[(encRegion.count - 16)...])

    let plain: [UInt8]
    do {
      let key = SymmetricKey(data: Data(secretKey))
      let box = try AES.GCM.SealedBox(
        nonce: try AES.GCM.Nonce(data: Data(nonce12)),
        ciphertext: Data(ciphertext), tag: Data(tag))
      plain = [UInt8](try AES.GCM.open(box, using: key, authenticating: Data(aad)))
    } catch {
      return nil
    }

    guard extended else { return plain }
    // Number of ext value words = the length field in the preamble (baseHeaderLen+2..+4, uint16 BE).
    let length = Int(b[baseHeaderLen + 2]) << 8 | Int(b[baseHeaderLen + 3])
    let strip = length * 4
    guard plain.count >= strip else { return nil }
    return Array(plain[strip...])
  }
}

// MARK: - RTP header parsing

struct RTPHeader {
  var payloadType: UInt8
  var ssrc: UInt32
  var headerLen: Int  // Unencrypted header length used as AAD (incl. extension and CSRCs)
}

func parseRTPHeader(_ packet: Data) -> RTPHeader? {
  let b = [UInt8](packet)
  guard b.count >= 12 else { return nil }
  let cc = Int(b[0] & 0x0F)
  let hasExtension = (b[0] & 0x10) != 0
  let payloadType = b[1] & 0x7F
  let ssrc = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
  var headerLen = 12 + 4 * cc
  if hasExtension {
    guard b.count >= headerLen + 4 else { return nil }
    let extWords = Int(b[headerLen + 2]) << 8 | Int(b[headerLen + 3])
    headerLen += 4 + 4 * extWords
  }
  guard b.count >= headerLen else { return nil }
  return RTPHeader(payloadType: payloadType, ssrc: ssrc, headerLen: headerLen)
}

// MARK: - Opus decoder (48kHz mono)

final class OpusMonoDecoder: @unchecked Sendable {
  private let decoder: OpaquePointer
  static let sampleRate: Int32 = 48000

  init?() {
    var err: Int32 = 0
    guard let dec = opus_decoder_create(Self.sampleRate, 1, &err), err == 0 else { return nil }
    decoder = dec
  }
  deinit { opus_decoder_destroy(decoder) }

  // One Opus frame -> 48kHz mono Int16 PCM
  func decode(_ opusFrame: [UInt8]) -> [Int16]? {
    let maxSamples = 5760  // 120ms @ 48kHz
    var pcm = [Int16](repeating: 0, count: maxSamples)
    let decoded = opusFrame.withUnsafeBufferPointer { inBuf in
      pcm.withUnsafeMutableBufferPointer { outBuf in
        opus_decode(
          decoder, inBuf.baseAddress, Int32(opusFrame.count), outBuf.baseAddress!,
          Int32(maxSamples),
          0)
      }
    }
    guard decoded > 0 else { return nil }
    return Array(pcm.prefix(Int(decoded)))
  }
}

// MARK: - WAV writer (48kHz mono PCM16)

func writeWAV(path: String, samples: [Int16], sampleRate: Int32 = 48000) {
  let dataBytes = samples.count * 2
  var d = Data()
  func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
  func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
  d.append("RIFF".data(using: .ascii)!)
  d.append(u32(UInt32(36 + dataBytes)))
  d.append("WAVE".data(using: .ascii)!)
  d.append("fmt ".data(using: .ascii)!)
  d.append(u32(16))  // fmt chunk size
  d.append(u16(1))  // PCM
  d.append(u16(1))  // mono
  d.append(u32(UInt32(sampleRate)))
  d.append(u32(UInt32(sampleRate) * 2))  // byte rate
  d.append(u16(2))  // block align
  d.append(u16(16))  // bits per sample
  d.append("data".data(using: .ascii)!)
  d.append(u32(UInt32(dataBytes)))
  samples.forEach { d.append(withUnsafeBytes(of: $0.littleEndian) { Data($0) }) }
  try? d.write(to: URL(fileURLWithPath: path))
}
