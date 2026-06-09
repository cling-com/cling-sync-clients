import SwiftUI

// The bottom-bar upload status, a pure projection of the store's upload state.
// In progress: current file + linear progress + Abort (disabled while committing).
// Finished: a success/failed/aborted banner with OK.
struct UploadProgress: View {
    let currentFile: String?
    let uploadedBytes: Int64
    let totalBytes: Int64
    let outcome: UploadOutcome?
    let onAbort: () -> Void
    let onDismiss: () -> Void

    private var isCommitting: Bool { currentFile == "Committing changes..." }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let outcome {
                outcomeView(outcome)
            } else {
                progressView
            }
        }
        .padding()
        .background(.regularMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private func outcomeView(_ outcome: UploadOutcome) -> some View {
        HStack {
            switch outcome {
            case .succeeded(let fileCount, let bytes):
                let fileText = fileCount == 1 ? "file" : "files"
                let sizeText = fileSizeFormatter.string(fromByteCount: bytes)
                Text("Success! \(fileCount) \(fileText) uploaded (\(sizeText))")
            case .failed(let message):
                Text("Upload failed: \(message)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            case .aborted:
                Text("Aborted!")
            }
            Spacer()
            Button("OK", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isCommitting {
                Text("Committing...")
            } else if let currentFile {
                Text(currentFile)
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Text("Preparing")
                    .font(.caption)
            }

            ProgressView(value: Double(uploadedBytes), total: Double(max(totalBytes, 1)))
                .progressViewStyle(.linear)

            HStack {
                Text("\(uploadedBytes * 100 / max(totalBytes, 1))% uploaded")
                    .font(.subheadline)
                Spacer()
                Button("Abort", action: onAbort)
                    .disabled(isCommitting)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }
}
