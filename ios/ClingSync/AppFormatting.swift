import Foundation

let fileSizeFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.formattingContext = .standalone
    formatter.isAdaptive = true
    return formatter
}()
