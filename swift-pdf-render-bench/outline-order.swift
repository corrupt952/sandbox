import Foundation
import PDFKit
import Quartz

func appResolvesPage(_ outline: PDFOutline, in doc: PDFDocument) -> Int? {
  if let p = outline.destination?.page {
    let idx = doc.index(for: p)
    if idx != NSNotFound { return idx }
  }
  if let dest = (outline.action as? PDFActionGoTo)?.destination, let p = dest.page {
    let idx = doc.index(for: p)
    if idx != NSNotFound { return idx }
  }
  return nil
}

guard CommandLine.arguments.count > 1 else {
  print("usage: outline-order <pdf>")
  exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let doc = PDFDocument(url: url) else {
  print("cannot open")
  exit(1)
}
guard let root = doc.outlineRoot else {
  print("NO outlineRoot")
  exit(0)
}

// アプリの collectItems と同じ pre-order DFS（親 → 子）で平坦化
var collected: [(level: Int, label: String, page: Int)] = []
func walk(_ node: PDFOutline, level: Int) {
  for i in 0..<node.numberOfChildren {
    guard let child = node.child(at: i) else { continue }
    if let page = appResolvesPage(child, in: doc) {
      collected.append((level, child.label ?? "(nil)", page))
    }
    walk(child, level: level + 1)
  }
}
walk(root, level: 0)

print("==== collectItems と同じ順序（pre-order DFS）====")
var prev = -1
var inversions = 0
for (i, e) in collected.enumerated() {
  let indent = String(repeating: "  ", count: e.level)
  let flag = e.page < prev ? "  <-- 逆転(page<\(prev))" : ""
  if e.page < prev { inversions += 1 }
  print(String(format: "%3d p%3d %@%@%@", i, e.page, indent, e.label, flag))
  prev = e.page
}
print("\n逆転回数(前項目よりページが小さい): \(inversions) / \(collected.count)")
