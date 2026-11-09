import AppKit
import SwiftUI

@MainActor
enum Editors {
    private static var windows: [NSWindow] = []

    @MainActor final class Closer {
        weak var window: NSWindow?
        func close() { window?.close() }
    }

    private static func open<V: View>(_ title: String, size: NSSize, build: (Closer) -> V) {
        let closer = Closer()
        let hosting = NSHostingController(rootView: build(closer))
        hosting.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .aqua)
        w.contentViewController = hosting
        w.setContentSize(size)
        w.minSize = NSSize(width: 560, height: 420)
        w.center()
        closer.window = w
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { $0 === w } }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private static func fitWindow(for img: CGImage, extraWidth: CGFloat, extraHeight: CGFloat) -> NSSize {
        let maxW: CGFloat = 820, maxH: CGFloat = 600
        let k = min(maxW / CGFloat(img.width), maxH / CGFloat(img.height), 1)
        return NSSize(width: max(560, CGFloat(img.width) * k + extraWidth), height: max(460, CGFloat(img.height) * k + extraHeight))
    }

    static func crop(_ url: URL) {
        guard let img = try? Img.load(url) else { HUD.shared.error("Не удалось открыть изображение"); return }
        open("Обрезка — \(url.lastPathComponent)", size: fitWindow(for: img, extraWidth: 60, extraHeight: 130)) { closer in
            CropEditor(image: img, source: url, close: closer.close)
        }
    }

    static func frame(_ url: URL) {
        guard let img = try? Img.load(url) else { HUD.shared.error("Не удалось открыть изображение"); return }
        open("Фон — \(url.lastPathComponent)", size: fitWindow(for: img, extraWidth: 330, extraHeight: 120)) { closer in
            FrameEditor(image: img, source: url, close: closer.close)
        }
    }
}

// MARK: - Shared styling

struct TangerineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(LinearGradient(colors: [.tangerineLight, .tangerine], startPoint: .top, endPoint: .bottom)))
            .shadow(color: .tangerine.opacity(0.35), radius: 6, y: 3)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SoftButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.cocoa)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.5 : 0.75)))
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? .white : Color.cocoa)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? AnyShapeStyle(Color.tangerine) : AnyShapeStyle(Color.white.opacity(0.7))))
        }
        .buttonStyle(.plain)
    }
}

struct PeachBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(hex: 0xFFF3E8), Color(hex: 0xFFDCC2)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

private func fit(_ size: CGSize, in box: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
    let k = min(box.width / size.width, box.height / size.height)
    return CGSize(width: size.width * k, height: size.height * k)
}

@MainActor
private func saveAndReport(_ img: CGImage, source: URL, suffix: String, ext: String, title: String) -> Bool {
    let out = Paths.output(for: source, suffix: suffix, ext: ext)
    do {
        try Img.write(img, to: out)
        HUD.shared.done(title, detail: out.lastPathComponent, outputs: [out])
        return true
    } catch {
        HUD.shared.error(error.localizedDescription)
        return false
    }
}

// MARK: - Crop

struct CropEditor: View {
    let image: CGImage
    let source: URL
    let close: () -> Void

    @State private var rect = CGRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88)
    @State private var startRect: CGRect?
    @State private var ratio: CGFloat?

    private var imgSize: CGSize { CGSize(width: image.width, height: image.height) }
    private let ratios: [(String, CGFloat?)] = [("Свободно", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:5", 0.8)]

    private var pixelRect: CGRect {
        CGRect(x: (rect.minX * imgSize.width).rounded(), y: (rect.minY * imgSize.height).rounded(),
               width: (rect.width * imgSize.width).rounded(), height: (rect.height * imgSize.height).rounded())
    }

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                let s = fit(imgSize, in: geo.size)
                let box = CGRect(x: rect.minX * s.width, y: rect.minY * s.height, width: rect.width * s.width, height: rect.height * s.height)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: s.width, height: s.height)
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: s))
                        p.addRect(box)
                    }
                    .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    Path { p in
                        for k in 1...2 {
                            let x = box.minX + box.width * CGFloat(k) / 3
                            let y = box.minY + box.height * CGFloat(k) / 3
                            p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                            p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    .allowsHitTesting(false)

                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .background(Color.white.opacity(0.001))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .gesture(moveGesture(s))

                    ForEach(0..<4, id: \.self) { corner in
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().strokeBorder(Color.tangerine, lineWidth: 3))
                            .frame(width: 18, height: 18)
                            .shadow(radius: 2)
                            .position(x: corner % 2 == 0 ? box.minX : box.maxX, y: corner < 2 ? box.minY : box.maxY)
                            .gesture(cornerGesture(corner, s))
                    }
                }
                .frame(width: s.width, height: s.height)
                .coordinateSpace(name: "crop")
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(.top, 18)

            HStack(spacing: 6) {
                ForEach(ratios.indices, id: \.self) { i in
                    Chip(title: ratios[i].0, selected: ratio == ratios[i].1) { apply(ratios[i].1) }
                }
                Spacer()
                Text("\(Int(pixelRect.width)) × \(Int(pixelRect.height))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.cocoa.opacity(0.7))
            }
            HStack {
                Spacer()
                Button("Отмена", action: close).buttonStyle(SoftButton()).keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save).buttonStyle(TangerineButton()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .background(PeachBackground())
    }

    private func normalizedRatio(_ r: CGFloat) -> CGFloat { r * imgSize.height / imgSize.width }

    private func apply(_ r: CGFloat?) {
        ratio = r
        guard let r else { return }
        let rn = normalizedRatio(r)
        var w: CGFloat = 0.9, h = 0.9 / rn
        if h > 0.9 { h = 0.9; w = 0.9 * rn }
        withAnimation(.spring(duration: 0.25)) {
            rect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        }
    }

    private func moveGesture(_ s: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { v in
                let start = startRect ?? rect
                if startRect == nil { startRect = rect }
                var r = start.offsetBy(dx: v.translation.width / s.width, dy: v.translation.height / s.height)
                r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
                r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
                rect = r
            }
            .onEnded { _ in startRect = nil }
    }

    private func cornerGesture(_ corner: Int, _ s: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { v in
                let start = startRect ?? rect
                if startRect == nil { startRect = rect }
                let opp = CGPoint(x: corner % 2 == 0 ? start.maxX : start.minX, y: corner < 2 ? start.maxY : start.minY)
                let p = CGPoint(x: min(max(v.location.x / s.width, 0), 1), y: min(max(v.location.y / s.height, 0), 1))
                let left = p.x < opp.x, up = p.y < opp.y
                let maxW = left ? opp.x : 1 - opp.x
                let maxH = up ? opp.y : 1 - opp.y
                var w = max(abs(p.x - opp.x), 0.03)
                var h = max(abs(p.y - opp.y), 0.03)
                if let ratio {
                    let rn = normalizedRatio(ratio)
                    h = w / rn
                    if h > maxH { h = maxH; w = h * rn }
                    if w > maxW { w = maxW; h = w / rn }
                } else {
                    w = min(w, maxW); h = min(h, maxH)
                }
                rect = CGRect(x: left ? opp.x - w : opp.x, y: up ? opp.y - h : opp.y, width: w, height: h)
            }
            .onEnded { _ in startRect = nil }
    }

    private func save() {
        guard let cropped = image.cropping(to: pixelRect) else { return }
        if saveAndReport(cropped, source: source, suffix: " (обрезка)", ext: Img.writableExt(for: source), title: "Обрезано") {
            close()
        }
    }
}

// MARK: - Background / frame

struct FrameSettings {
    var background = 0
    var padding: Double = 0.1
    var radius: Double = 0.03
    var shadow: Double = 0.6
    var ratio = 0
}

enum Backdrops {
    static let all: [[Color]] = [
        [Color(hex: 0xFFB35C), Color(hex: 0xF5662E), Color(hex: 0xE23B5B)],
        [Color(hex: 0xFF9A44), Color(hex: 0xFC6076)],
        [Color(hex: 0xFFD3A5), Color(hex: 0xFD6585)],
        [Color(hex: 0xF6D365), Color(hex: 0xFDA085)],
        [Color(hex: 0xA18CD1), Color(hex: 0xFBC2EB)],
        [Color(hex: 0xF97316), Color(hex: 0xEC4899), Color(hex: 0x8B5CF6)],
        [Color(hex: 0x667EEA), Color(hex: 0x764BA2)],
        [Color(hex: 0x2193B0), Color(hex: 0x6DD5ED)],
        [Color(hex: 0x43E97B), Color(hex: 0x38F9D7)],
        [Color(hex: 0x0F2027), Color(hex: 0x2C5364)],
        [Color(hex: 0xFFFFFF)],
        [Color(hex: 0xFFF1E4)],
        [Color(hex: 0xE9E9EE)],
        [Color(hex: 0x1C1C1E)],
        [Color(hex: 0xF5662E)],
    ]

    @ViewBuilder static func fill(_ i: Int) -> some View {
        let colors = all[i]
        if colors.count == 1 {
            colors[0]
        } else {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct FramedCanvas: View {
    let image: CGImage
    let settings: FrameSettings
    let scale: CGFloat

    static let ratios: [(String, CGFloat?)] = [("Авто", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:5", 0.8)]

    static func canvasSize(_ img: CGImage, _ s: FrameSettings) -> CGSize {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let pad = s.padding * max(w, h)
        var cw = w + pad * 2, ch = h + pad * 2
        if let r = ratios[s.ratio].1 {
            if cw / ch < r { cw = ch * r } else { ch = cw / r }
        }
        return CGSize(width: cw, height: ch)
    }

    var body: some View {
        let size = Self.canvasSize(image, settings)
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        let side = max(w, h)
        ZStack {
            Backdrops.fill(settings.background)
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: settings.radius * side, style: .continuous))
                .shadow(color: .black.opacity(0.4 * settings.shadow), radius: settings.shadow * 0.035 * side, y: settings.shadow * 0.02 * side)
        }
        .frame(width: size.width * scale, height: size.height * scale)
        .clipped()
    }
}

struct FrameEditor: View {
    let image: CGImage
    let source: URL
    let close: () -> Void
    @State private var s = FrameSettings()

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let canvas = FramedCanvas.canvasSize(image, s)
                let shown = fit(canvas, in: CGSize(width: geo.size.width - 40, height: geo.size.height - 40))
                FramedCanvas(image: image, settings: s, scale: canvas.width > 0 ? shown.width / canvas.width : 1)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .animation(.easeOut(duration: 0.15), value: s.ratio)
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 16) {
                section("Фон") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 9), count: 5), spacing: 9) {
                        ForEach(Backdrops.all.indices, id: \.self) { i in
                            Backdrops.fill(i)
                                .frame(width: 30, height: 30)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                                .overlay(Circle().strokeBorder(Color.tangerine, lineWidth: s.background == i ? 3 : 0).padding(-4))
                                .onTapGesture { s.background = i }
                        }
                    }
                }
                section("Отступ") { Slider(value: $s.padding, in: 0...0.3).tint(.tangerine) }
                section("Скругление") { Slider(value: $s.radius, in: 0...0.12).tint(.tangerine) }
                section("Тень") { Slider(value: $s.shadow, in: 0...1).tint(.tangerine) }
                section("Формат") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(FramedCanvas.ratios.indices, id: \.self) { i in
                            Chip(title: FramedCanvas.ratios[i].0, selected: s.ratio == i) { s.ratio = i }
                        }
                    }
                }
                Spacer()
                HStack {
                    Button("Копировать", action: copy).buttonStyle(SoftButton())
                    Spacer()
                    Button("Сохранить", action: save).buttonStyle(TangerineButton()).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .padding(.top, 20)
            .frame(width: 270)
            .background(Color.white.opacity(0.35))
        }
        .background(PeachBackground())
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.cocoa)
            content()
        }
    }

    private func render() -> CGImage? {
        let canvas = FramedCanvas.canvasSize(image, s)
        let k = min(1, 6000 / max(canvas.width, canvas.height))
        let renderer = ImageRenderer(content: FramedCanvas(image: image, settings: s, scale: k))
        renderer.scale = 1
        return renderer.cgImage
    }

    private func save() {
        guard let img = render() else { HUD.shared.error("Не удалось отрисовать картинку"); return }
        if saveAndReport(img, source: source, suffix: " (с фоном)", ext: "png", title: "Сохранено") { close() }
    }

    private func copy() {
        guard let img = render() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        HUD.shared.done("Скопировано", detail: "Вставьте куда угодно ⌘V", outputs: [])
    }
}
