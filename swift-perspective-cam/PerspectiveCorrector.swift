import CoreImage

/// Core Image 標準の `CIPerspectiveCorrection` フィルターを薄くラップしたもの。
/// 4隅の座標（quadrilateral）を渡すと、その領域を正面から見た矩形に補正してくれる。
///
/// 重要: 座標は CIImage のネイティブ座標系（原点が左下、Y が上向き）で渡すこと。
/// SwiftUI/AppKit のビュー座標（原点が左上、Y が下向き）から変換する場合は
/// `y' = imageHeight - y` を忘れないこと。
enum PerspectiveCorrector {

    /// - Parameters:
    ///   - image: 入力画像
    ///   - topLeft, topRight, bottomRight, bottomLeft:
    ///       画面上で「見た目通り」に top-left / top-right / bottom-right / bottom-left
    ///       に相当する点を、CIImage 座標系（左下原点・Y上向き）で指定する。
    /// - Returns: 補正後の CIImage（失敗時は nil）
    static func correct(
        image: CIImage,
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        bottomLeft: CGPoint
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        return filter.outputImage
    }
}
