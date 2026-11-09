import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
    static let tangerine = Color(hex: 0xF5662E)
    static let tangerineLight = Color(hex: 0xFF9E4D)
    static let cocoa = Color(hex: 0x73381A)
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return "\(n) \(one)" }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return "\(n) \(few)" }
    return "\(n) \(many)"
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}

final class HUDModel: ObservableObject {
    enum State { case working, done, error, info }
    @Published var title = ""
    @Published var detail = ""
    @Published var state: State = .working
    var onTap: (() -> Void)?
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    private var icon: String {
        switch model.state {
        case .working: "arrow.triangle.2.circlepath"
        case .done: "checkmark"
        case .error: "exclamationmark"
        case .info: "hand.draw"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: model.state == .error ? [Color(hex: 0xE5484D), Color(hex: 0xC4262B)] : [.tangerineLight, .tangerine],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cocoa)
                    .lineLimit(1)
                if model.state == .working {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.tangerine)
                        .controlSize(.small)
                } else if !model.detail.isEmpty {
                    Text(model.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.cocoa.opacity(0.75))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0xFFE3CC, opacity: 0.55)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.onTap?() }
        .environment(\.colorScheme, .light)
        .padding(16)
    }
}

@MainActor
final class HUD {
    static let shared = HUD()
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let host = NSHostingView(rootView: HUDView(model: model))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 352, height: max(size.height, 96))),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        host.frame = p.contentRect(forFrameRect: p.frame)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        return p
    }

    private func present(at point: NSPoint?) {
        let p = ensurePanel()
        hideWork?.cancel()
        let anchor = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        let size = p.frame.size
        var origin: NSPoint
        if point == nil {
            origin = NSPoint(x: vf.maxX - size.width - 8, y: vf.maxY - size.height - 4)
        } else {
            origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        }
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)
        if !p.isVisible { p.setFrameOrigin(origin) }
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                p.animator().alphaValue = 1
            }
        }
    }

    private func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func working(_ title: String, at point: NSPoint) {
        model.state = .working
        model.title = title
        model.detail = ""
        model.onTap = nil
        present(at: point)
    }

    func done(_ title: String, detail: String, outputs: [URL]) {
        model.state = .done
        model.title = title
        model.detail = outputs.isEmpty ? detail : (detail.isEmpty ? "Нажмите, чтобы показать в Finder" : detail + " · показать в Finder")
        model.onTap = outputs.isEmpty ? nil : { [weak self] in
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
            self?.hide(after: 0)
        }
        present(at: panel?.isVisible == true ? nil : NSEvent.mouseLocation)
        hide(after: 3.5)
    }

    func error(_ message: String) {
        model.state = .error
        model.title = "Не получилось"
        model.detail = message
        model.onTap = { [weak self] in self?.hide(after: 0) }
        present(at: panel?.isVisible == true ? nil : NSEvent.mouseLocation)
        hide(after: 5)
    }

    func info(_ title: String, detail: String) {
        model.state = .info
        model.title = title
        model.detail = detail
        model.onTap = { [weak self] in self?.hide(after: 0) }
        present(at: nil)
        hide(after: 6)
    }
}
