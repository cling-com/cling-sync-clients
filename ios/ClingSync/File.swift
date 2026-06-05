import SwiftUI
import UIKit

enum FileStatus: Equatable {
    case none
    case checking
    case new
    case exists(repoPath: String)
    case waiting
    case sending
    case sentWaitingCommit
    case committing
    case done
    case failed(message: String)
    case aborted
}

struct MediaFileView: View {
    let file: SourceFile
    let status: FileStatus?
    let isSelected: Bool
    let loadThumbnail: () async -> UIImage?

    @State private var thumbnail: UIImage?

    private var statusText: String {
        guard let status else { return "" }
        switch status {
        case .checking: return "Scanning"
        case .new: return "New"
        case .waiting: return "Waiting"
        case .sending: return "Sending"
        case .sentWaitingCommit, .committing: return "Processing"
        case .done: return "Done"
        case .failed: return "Failed"
        case .aborted: return "Aborted"
        case .exists, .none: return ""
        }
    }

    private var statusColor: Color {
        guard let status else { return .clear }
        switch status {
        case .new, .sending: return .blue
        case .exists, .done: return .green
        case .failed: return .red
        case .aborted: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        HStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading) {
                Text(file.name)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(fileSizeFormatter.string(fromByteCount: file.size))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !statusText.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(statusColor)
                    }
                }
            }
            Spacer()
            statusIcon
        }
        .contentShape(Rectangle())
        .task {
            if thumbnail == nil {
                thumbnail = await loadThumbnail()
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .checking, .sending, .sentWaitingCommit, .committing:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
        case .done, .exists:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        default:
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
    }
}
