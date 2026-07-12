import IPMCore
import simd

// A worked example so you can eyeball the IPM geometry without a device:
// a camera 1.5 m above the floor, 3 m back, tilted down to look at a 3 m × 3 m
// ground patch in front of it. Prints the projected image quad, the Core Image
// perspective-correction corners, the metric scale, and a round-trip check.

func lookAtTransform(
  position: SIMD3<Double>, target: SIMD3<Double>, worldUp: SIMD3<Double> = SIMD3<Double>(0, 1, 0)
) -> simd_double4x4 {
  let forward = simd_normalize(target - position)
  let right = simd_normalize(simd_cross(forward, worldUp))
  let up = simd_cross(right, forward)
  return simd_double4x4(
    columns: (
      SIMD4<Double>(right.x, right.y, right.z, 0),
      SIMD4<Double>(up.x, up.y, up.z, 0),
      SIMD4<Double>(-forward.x, -forward.y, -forward.z, 0),  // camera looks down local -Z
      SIMD4<Double>(position.x, position.y, position.z, 1)
    ))
}

func fmt(_ p: SIMD2<Double>) -> String {
  String(format: "(%.1f, %.1f)", p.x, p.y)
}

let imageSize = SIMD2<Double>(1920, 1080)
let camera = PinholeCamera(
  fx: 1000, fy: 1000, cx: imageSize.x / 2, cy: imageSize.y / 2,
  cameraTransform: lookAtTransform(
    position: SIMD3<Double>(0, 1.5, 3), target: SIMD3<Double>(0, 0, -1)),
  imageSize: imageSize)

let rect = GroundRect(
  width: 3, depth: 3, center: SIMD3<Double>(0, 0, -1), forward: SIMD2<Double>(0, -1))
let corners = rect.worldCorners

print("== IPMCore worked example ==")
print(
  "camera: 1.5m up, 3m back, looking at the floor; image \(Int(imageSize.x))x\(Int(imageSize.y))")
print("ground rect: 3m x 3m centered at (0,0,-1)\n")

print("ground corners (world x,y,z) -> image (px):")
let labels = ["topLeft ", "topRight", "botRight", "botLeft "]
for (i, c) in corners.enumerated() {
  let img = camera.project(c).map(fmt) ?? "behind camera"
  print(String(format: "  %@  (% .2f, % .2f, % .2f)  ->  %@", labels[i], c.x, c.y, c.z, img))
}

if let quad = IPM.imageQuad(groundCorners: corners, camera: camera),
  let ci = IPM.flippedPerspectiveCorners(quad: quad, imageHeight: imageSize.y)
{
  print("\nCore Image perspective-correction inputs (bottom-left origin, Y-flipped):")
  print("  inputTopLeft     \(fmt(ci.topLeft))")
  print("  inputTopRight    \(fmt(ci.topRight))")
  print("  inputBottomRight \(fmt(ci.bottomRight))")
  print("  inputBottomLeft  \(fmt(ci.bottomLeft))")
}

let outPx = 512.0
print(
  String(
    format: "\nmetric scale: %.0f px output over 3 m => %.2f mm/pixel", outPx,
    IPM.mmPerPixel(outputPixels: outPx, rectMeters: 3)))

// Round-trip: image -> ground via the homography solved from the 4 corners.
let quad = IPM.imageQuad(groundCorners: corners, camera: camera)!
let groundXZ = corners.map { SIMD2<Double>($0.x, $0.z) }
let H = Homography.homography(from: quad, to: groundXZ)!
let interior = SIMD3<Double>(0.3, 0, -0.4)
let recovered = Homography.apply(H, to: camera.project(interior)!)
print(
  String(
    format: "\nround-trip interior point: ground (%.2f, %.2f) -> image -> recovered (%.4f, %.4f)",
    interior.x, interior.z, recovered.x, recovered.y))
