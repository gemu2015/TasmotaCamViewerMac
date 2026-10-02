import SwiftUI
import AppKit

/// Shown after a recording was finished: file name and "Show in Finder" (~/Movies/TasmotaCam).
struct RecordingSavedBanner: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording saved").font(.subheadline.bold())
                Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
    }
}
