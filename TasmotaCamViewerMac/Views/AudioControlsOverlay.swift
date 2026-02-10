import SwiftUI
import AppKit

/// Floating overlay with push-to-talk button, listen toggle, mute controls, and volume slider.
struct AudioControlsOverlay: View {
    @Bindable var audio: AudioBridge

    @State private var isTalking = false

    var body: some View {
        VStack(spacing: 10) {
            // Main controls row
            HStack(spacing: 20) {
                // Listen toggle
                Button {
                    if audio.state == .listening {
                        audio.stopAudio()
                    } else {
                        audio.startListening()
                    }
                } label: {
                    Image(systemName: audio.state == .listening ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .imageScale(.large)
                        .foregroundStyle(audio.state == .listening ? .green : .secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                // Mic mute
                Button {
                    audio.isMicMuted.toggle()
                } label: {
                    Image(systemName: audio.isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .imageScale(.large)
                        .foregroundStyle(audio.isMicMuted ? .red : .secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                // Push-to-talk button
                pttButton

                // Speaker mute
                Button {
                    audio.isSpeakerMuted.toggle()
                } label: {
                    Image(systemName: audio.isSpeakerMuted ? "speaker.slash.fill" : "speaker.fill")
                        .imageScale(.large)
                        .foregroundStyle(audio.isSpeakerMuted ? .red : .secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                // State indicator
                Text(audio.state.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60)
            }

            // Volume slider row
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $audio.speakerVolume, in: 1...10, step: 0.5)
                    .tint(.blue)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(format: "%.0f%%", audio.speakerVolume * 10))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
            }
            .padding(.horizontal, 4)

            // Auto-listen toggle
            Toggle("Auto-listen on connect", isOn: $audio.autoListen)
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(.green)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Large push-to-talk button using NSView mouse tracking for reliable press/release on macOS.
    private var pttButton: some View {
        PressAndReleaseView(
            onPress: {
                guard !isTalking else { return }
                isTalking = true
                audio.startTalking()
            },
            onRelease: {
                isTalking = false
                audio.startListening()
            }
        ) {
            Circle()
                .fill(isTalking ? Color.red : Color.blue.opacity(0.8))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: isTalking ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .shadow(color: isTalking ? .red.opacity(0.4) : .clear, radius: 8)
                .scaleEffect(isTalking ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isTalking)
        }
    }
}

// MARK: - macOS Press-and-Release View

/// Wraps an NSView to detect mouse-down and mouse-up reliably on macOS.
struct PressAndReleaseView<Content: View>: NSViewRepresentable {
    let onPress: () -> Void
    let onRelease: () -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> PressTrackingNSView {
        let view = PressTrackingNSView()
        view.onPress = onPress
        view.onRelease = onRelease

        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        return view
    }

    func updateNSView(_ nsView: PressTrackingNSView, context: Context) {
        nsView.onPress = onPress
        nsView.onRelease = onRelease

        if let hostingView = nsView.subviews.first as? NSHostingView<Content> {
            hostingView.rootView = content()
        }
    }
}

/// NSView that tracks mouseDown / mouseUp events.
final class PressTrackingNSView: NSView {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func mouseUp(with event: NSEvent) {
        onRelease?()
    }
}
