import AppKit
import SwiftUI

/// Everything the pill draws, as a value: Voice Ask and Dictation publish through the same panel.
struct SpeechVoicePillModel {
    var title: String
    var detail: String
    var level: Float
    var isListening: Bool
    var onCancel: @MainActor () -> Void
}

@MainActor
final class SpeechVoicePillController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<SpeechVoicePill>?
    private var model: SpeechVoicePillModel?

    func show(_ model: SpeechVoicePillModel) {
        self.model = model
        if panel == nil { panel = makePanel() }
        render()
    }

    /// Title, transcript and level all move while a session runs, so the same panel redraws.
    func update(_ model: SpeechVoicePillModel) {
        guard panel != nil else { return }
        self.model = model
        render()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hosting = nil
        model = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 62),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        return panel
    }

    private func render() {
        guard let panel, let model else { return }
        if let hosting {
            hosting.rootView = SpeechVoicePill(model: model)
        } else {
            let hosting = NSHostingView(rootView: SpeechVoicePill(model: model))
            self.hosting = hosting
            panel.contentView = hosting
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.maxY - panel.frame.height - 24))
        }
        panel.orderFrontRegardless()
    }
}

struct SpeechVoicePill: View {
    let model: SpeechVoicePillModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isListening ? "waveform" : "mic.fill")
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !model.detail.isEmpty {
                    Text(model.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    GeometryReader { geo in
                        Capsule().fill(.secondary.opacity(0.55))
                            .frame(width: max(6, geo.size.width * CGFloat(model.level)), height: 3)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 8)
                }
            }
            Spacer(minLength: 0)
            Button { model.onCancel() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, 14)
        .frame(width: 320, height: 60)
        .modifier(SpeechVoiceGlass())
    }
}

struct SpeechVoiceGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
