import AppKit
import CoreImage

extension CIImage {
    /// 表示用に CGImage 経由で NSImage へ変換する。
    /// 呼び出し側で CIContext を使い回すことで毎フレームのコンテキスト生成コストを避ける。
    func nsImage(using context: CIContext) -> NSImage? {
        guard let cgImage = context.createCGImage(self, from: self.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: extent.width, height: extent.height))
    }
}
