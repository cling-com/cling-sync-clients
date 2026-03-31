import Photos
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
    case done
}

final class MediaFile: ObservableObject, Identifiable {
    let id: String
    let name: String
    let size: Int64
    let modificationDate: Date
    let asset: PHAsset?
    let resource: PHAssetResource?
    let localFileURL: URL?
    @Published var uploadState: FileStatus = .none
    @Published var revisionEntry: String?

    var syncedRecord: SyncedFileRecord {
        SyncedFileRecord(name: name, size: size, modificationDate: modificationDate)
    }

    init(name: String, size: Int64, asset: PHAsset, resource: PHAssetResource, modificationDate: Date) {
        self.id = asset.localIdentifier + ":" + resource.originalFilename
        self.name = name
        self.size = size
        self.modificationDate = modificationDate
        self.asset = asset
        self.resource = resource
        self.localFileURL = nil
    }

    init(localFileURL: URL, size: Int64, modificationDate: Date) {
        self.id = localFileURL.lastPathComponent
        self.name = localFileURL.lastPathComponent
        self.size = size
        self.modificationDate = modificationDate
        self.asset = nil
        self.resource = nil
        self.localFileURL = localFileURL
    }
}

struct MediaFileView: View {
    @State private var thumbnail: UIImage?
    @ObservedObject var file: MediaFile
    let isSelected: Bool

    private var uploadStateText: String {
        switch file.uploadState {
        case .none: return ""
        case .checking: return "Scanning"
        case .new: return "New"
        case .exists: return ""
        case .waiting: return "Waiting"
        case .sending: return "Sending"
        case .sentWaitingCommit: return "Processing"
        case .done: return "Done"
        }
    }

    private var uploadStateColor: Color {
        switch file.uploadState {
        case .none: return .clear
        case .checking: return .secondary
        case .new: return .blue
        case .exists: return .green
        case .waiting: return .secondary
        case .sending: return .blue
        case .sentWaitingCommit: return .secondary
        case .done: return .green
        }
    }

    var body: some View {
        HStack {
            if let thumbnail = thumbnail {
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

                    if !uploadStateText.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(uploadStateText)
                            .font(.caption)
                            .foregroundColor(uploadStateColor)
                    }
                }
            }
            Spacer()
            switch file.uploadState {
            case .checking, .sending, .sentWaitingCommit:
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
        .contentShape(Rectangle())
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard let asset = file.asset else {
            return
        }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast

        manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 120, height: 120),
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            if let error = info?[PHImageErrorKey] as? Error {
                print("Image request failed with error: \(error)")
            }
            if let image = image {
                self.thumbnail = image
            }
        }
    }
}
