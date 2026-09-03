import Foundation
import PDFKit

struct ExtractedLine: Codable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: extract_pdf_lines.swift <pdf>\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let document = PDFDocument(url: url),
      let page = document.page(at: 0),
      let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else {
    FileHandle.standardError.write(Data("unable to read first PDF page\n".utf8))
    exit(1)
}

let lines = selection.selectionsByLine().compactMap { line -> ExtractedLine? in
    let text = (line.string ?? "")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let bounds = line.bounds(for: page)
    return ExtractedLine(
        text: text,
        x: bounds.minX,
        y: bounds.minY,
        width: bounds.width,
        height: bounds.height
    )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(lines)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
