import Foundation
import PDFKit
import Quartz

// アプリの pageIndex(for:) と同等の解決ロジック（2経路のみ）を再現
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

func actionTypeName(_ outline: PDFOutline) -> String {
  guard let action = outline.action else { return "nil" }
  return String(describing: type(of: action))
}

guard CommandLine.arguments.count > 1 else {
  print("usage: outline-dump <pdf>")
  exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let doc = PDFDocument(url: url) else {
  print("cannot open")
  exit(1)
}
print("pageCount=\(doc.pageCount)")
guard let root = doc.outlineRoot else {
  print("NO outlineRoot")
  exit(0)
}

var total = 0
var resolved = 0
var missing = 0
var actionCounts: [String: Int] = [:]
var hasDestinationButUnresolved = 0
var missingSamples: [String] = []

func walk(_ node: PDFOutline, level: Int) {
  for i in 0..<node.numberOfChildren {
    guard let child = node.child(at: i) else { continue }
    total += 1
    let label = child.label ?? "(nil)"
    let app = appResolvesPage(child, in: doc)
    let hasDest = child.destination != nil
    let hasDestPage = child.destination?.page != nil
    let at = actionTypeName(child)
    actionCounts[at, default: 0] += 1
    if app != nil {
      resolved += 1
    } else {
      missing += 1
      if hasDest && !hasDestPage { hasDestinationButUnresolved += 1 }
      if missingSamples.count < 25 {
        missingSamples.append(
          "[L\(level)] '\(label)' | dest=\(hasDest) destPage=\(hasDestPage) action=\(at)")
      }
    }
    walk(child, level: level + 1)
  }
}
walk(root, level: 0)

print("---- summary ----")
print("total outline nodes : \(total)")
print("app-resolved (shown): \(resolved)")
print("app-missing (dropped): \(missing)")
print("destination!=nil but page==nil: \(hasDestinationButUnresolved)")
print("action types: \(actionCounts)")
print("---- dropped samples ----")
for s in missingSamples { print(s) }
