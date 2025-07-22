import SwiftUI

struct UploadProgress: View {
    @ObservedObject var uploader: Uploader
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch uploader.state {
            case .preparing:
                HStack {
                    Text(uploader.state == .preparing ? "Preparing" : "Aborted!")
                    Spacer()
                    Button("Abort", action: uploader.abort)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            case .aborted:
                HStack {
                    Text(uploader.state == .preparing ? "Preparing" : "Aborted!")
                    Spacer()
                    Button("OK") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .error:
                VStack(alignment: .leading, spacing: 8) {
                    Text(uploader.errorMessage)
                        .lineLimit(10)
                    HStack {
                        Spacer()
                        Button("OK") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .sending, .committing:
                VStack(alignment: .leading, spacing: 4) {
                    if let file = uploader.currentlySending {
                        HStack {
                            Text(file.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(fileSizeFormatter.string(fromByteCount: file.size))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Committing...")
                    }

                    ProgressView(
                        value: Double(uploader.uploadedBytes),
                        total: Double(uploader.totalBytes)
                    )
                    .progressViewStyle(.linear)
                }

                HStack {
                    let percentage = uploader.uploadedBytes * 100 / max(uploader.totalBytes, 1)
                    Text("\(percentage)% uploaded")
                        .font(.subheadline)

                    Spacer()

                    Button(action: uploader.abort) {
                        Text("Abort")
                    }
                    .disabled(uploader.state == .committing)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            case .done:
                HStack {
                    let fileCount = uploader.files.count
                    let fileText = fileCount > 1 ? "files" : "file"
                    let sizeText = fileSizeFormatter.string(fromByteCount: uploader.uploadedBytes)
                    Text("Success! \(fileCount) \(fileText) uploaded (\(sizeText))")
                    Spacer()
                    Button("OK") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
