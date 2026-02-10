import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sheet view for previewing and sharing a captured snapshot.
struct SnapshotPreviewSheet: View {
    let image: NSImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Snapshot")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 4)

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8)

            // Image info
            HStack(spacing: 24) {
                Label(
                    "\(Int(image.size.width)) x \(Int(image.size.height))",
                    systemImage: "rectangle.dashed"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let jpegData = image.jpegData {
                    Label(
                        formatBytes(jpegData.count),
                        systemImage: "doc"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                // Save to file
                Button {
                    saveToFile()
                } label: {
                    Label("Save to File…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Copy to clipboard
                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 400)
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "snapshot.jpg"
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.url, let data = image.jpegData {
                try? data.write(to: url)
            }
        }
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1_048_576 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
    }
}

// MARK: - NSImage JPEG helper

extension NSImage {
    var jpegData: Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}
