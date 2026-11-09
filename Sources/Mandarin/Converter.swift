import AppKit
import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

struct Outcome {
    var outputs: [URL]
    var title: String
    var detail: String = ""
}

enum Converter {
    @MainActor static func run(_ item: WheelItem, urls: [URL], at point: NSPoint) {
        let kind = FileKind.of(urls[0])
        let files = urls.filter { FileKind.of($0) == kind }
        switch item.op {
        case .crop:
            Editors.crop(files[0])
            return
        case .frame:
            Editors.frame(files[0])
            return
        default:
            break
        }
        HUD.shared.working(item.progress, at: NSPoint(x: point.x, y: point.y - 120))
        Task.detached {
            do {
                let result = try await perform(item.op, kind: kind, files: files)
                await MainActor.run { HUD.shared.done(result.title, detail: result.detail, outputs: result.outputs) }
            } catch {
                await MainActor.run { HUD.shared.error(error.localizedDescription) }
            }
        }
    }

    static func perform(_ op: Op, kind: FileKind, files: [URL]) async throws -> Outcome {
        let inputBytes = files.reduce(Int64(0)) { $0 + Paths.size($1) }

        func savedOutcome(_ outs: [URL], _ title: String) -> Outcome {
            let outBytes = outs.reduce(Int64(0)) { $0 + Paths.size($1) }
            let pct = inputBytes > 0 ? Int((1 - Double(outBytes) / Double(inputBytes)) * 100) : 0
            return Outcome(outputs: outs, title: title, detail: "\(formatBytes(inputBytes)) → \(formatBytes(outBytes))" + (pct > 0 ? " (−\(pct)%)" : ""))
        }

        func many(_ outs: [URL], _ verb: String) -> Outcome {
            let name = outs.count == 1 ? outs[0].lastPathComponent : plural(outs.count, "файл", "файла", "файлов")
            return Outcome(outputs: outs, title: verb, detail: name)
        }

        switch (kind, op) {
        // MARK: Images
        case (.image, .convert("pdf")):
            let out = try Img.toPDF(files)
            return many([out], "PDF готов")
        case (.image, .convert(let ext)):
            let outs = try files.map { try Img.convert($0, to: ext) }
            return many(outs, "Готово: \(ext.uppercased())")
        case (.image, .compress):
            return savedOutcome(try files.map(Img.compress), "Сжато")
        case (.image, .resize):
            let outs = try files.map { u in
                try Img.transform(u, suffix: " (½)") { Img.scaled($0, by: 0.5) }
            }
            return many(outs, "Уменьшено в 2 раза")
        case (.image, .rotate):
            return many(try files.map { try Img.transform($0, suffix: " (повёрнуто)", Img.rotated) }, "Повёрнуто")
        case (.image, .grayscale):
            return many(try files.map { try Img.transform($0, suffix: " (ч-б)", Img.mono) }, "Чёрно-белое готово")
        case (.image, .removeBackground):
            return many(try files.map(Img.removeBackground), "Фон убран")
        case (.image, .ocr):
            var texts: [String] = []
            for u in files { texts.append(try OCR.text(in: Img.load(u))) }
            return await copyText(texts.joined(separator: "\n\n"))

        // MARK: PDF
        case (.pdf, .convert(let ext)) where ext == "jpg" || ext == "png":
            var outs: [URL] = []
            for u in files { outs += try Pdf.toImages(u, ext: ext) }
            return many(outs, "Готово: \(ext.uppercased())")
        case (.pdf, .convert(let ext)):
            var outs: [URL] = []
            for u in files {
                let attr = UncheckedBox(value: try await Pdf.attributedText(u))
                let out = Paths.output(for: u, ext: ext)
                try await MainActor.run { try Doc.write(attr.value, to: out, ext: ext) }
                outs.append(out)
            }
            return many(outs, "Готово: \(ext.uppercased())")
        case (.pdf, .compress):
            return savedOutcome(try files.map(Pdf.compress), "PDF сжат")
        case (.pdf, .split):
            var outs: [URL] = []
            for u in files { outs.append(try Pdf.split(u)) }
            return many(outs, "Страницы разделены")
        case (.pdf, .rotate):
            return many(try files.map(Pdf.rotate), "Повёрнуто")
        case (.pdf, .merge):
            return many([try Pdf.merge(files)], "PDF объединены")
        case (.pdf, .ocr):
            var texts: [String] = []
            for u in files { texts.append(try await Pdf.plainText(u)) }
            return await copyText(texts.joined(separator: "\n\n"))

        // MARK: Documents
        case (.document, .convert(let ext)):
            var outs: [URL] = []
            for u in files {
                let out = Paths.output(for: u, ext: ext)
                try await MainActor.run {
                    let attr = try Doc.read(u)
                    try Doc.write(attr, to: out, ext: ext)
                }
                outs.append(out)
            }
            return many(outs, "Готово: \(ext.uppercased())")

        // MARK: Video / audio
        case (.video, .convert(let ext)), (.audio, .convert(let ext)):
            var outs: [URL] = []
            for u in files { outs.append(try await Media.convert(u, to: ext)) }
            return many(outs, "Готово: \(ext.uppercased())")
        case (.video, .compress):
            var outs: [URL] = []
            for u in files { outs.append(try await Media.compress(u)) }
            return savedOutcome(outs, "Видео сжато")
        case (.video, .mute):
            var outs: [URL] = []
            for u in files { outs.append(try await Media.mute(u)) }
            return many(outs, "Звук убран")
        case (.video, .frameGrab):
            var outs: [URL] = []
            for u in files { outs.append(try await Media.frame(u)) }
            return many(outs, "Кадр сохранён")

        default:
            throw ConvError("Это действие не подходит для такого файла")
        }
    }

    private static func copyText(_ text: String) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Outcome(outputs: [], title: "Текст не найден") }
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
        }
        let preview = trimmed.prefix(80).replacingOccurrences(of: "\n", with: " ")
        return Outcome(outputs: [], title: "Текст скопирован", detail: "«\(preview)\(trimmed.count > 80 ? "…" : "")»")
    }
}

// MARK: - Paths

enum Paths {
    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func directory(for src: URL) -> URL {
        let dir = src.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func output(for src: URL, suffix: String = "", ext: String) -> URL {
        unique(in: directory(for: src), base: src.deletingPathExtension().lastPathComponent + suffix, ext: ext)
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    static func ensureSmaller(_ out: URL, than src: URL) throws {
        if size(out) >= size(src) {
            try? FileManager.default.removeItem(at: out)
            throw ConvError("\(src.lastPathComponent) уже хорошо сжат — меньше не получится")
        }
    }

    static func folder(for src: URL, name: String) throws -> URL {
        let dir = directory(for: src)
        var url = dir.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Images

enum Img {
    static let ciContext = CIContext()

    static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConvError("Не удалось открыть изображение") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConvError("Не удалось прочитать изображение")
        }
        return img
    }

    static func writableExt(for src: URL) -> String {
        let e = WheelItem.normalized(src.pathExtension)
        return ["jpg", "png", "heic", "tiff"].contains(e) ? e : "png"
    }

    static func write(_ img: CGImage, to url: URL, quality: Double = 0.9) throws {
        let type: UTType
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": type = .jpeg
        case "heic": type = .heic
        case "tiff": type = .tiff
        default: type = .png
        }
        let image = type == .jpeg ? flattened(img) : img
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvError("Не удалось создать файл \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw ConvError("Не удалось сохранить \(url.lastPathComponent)") }
    }

    static func context(_ w: Int, _ h: Int, alpha: Bool = true) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    static func flattened(_ img: CGImage) -> CGImage {
        guard let ctx = context(img.width, img.height, alpha: false) else { return img }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func scaled(_ img: CGImage, by f: CGFloat) -> CGImage {
        let w = max(1, Int(CGFloat(img.width) * f)), h = max(1, Int(CGFloat(img.height) * f))
        guard let ctx = context(w, h) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func rotated(_ img: CGImage) -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = context(h, w) else { return img }
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func mono(_ img: CGImage) -> CGImage {
        let ci = CIImage(cgImage: img).applyingFilter("CIPhotoEffectMono")
        return ciContext.createCGImage(ci, from: ci.extent) ?? img
    }

    static func convert(_ url: URL, to ext: String) throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        try write(load(url), to: out, quality: 0.92)
        return out
    }

    static func transform(_ url: URL, suffix: String, _ f: (CGImage) throws -> CGImage) throws -> URL {
        let out = Paths.output(for: url, suffix: suffix, ext: writableExt(for: url))
        try write(f(load(url)), to: out)
        return out
    }

    static func compress(_ url: URL) throws -> URL {
        var img = try load(url)
        let maxSide = max(img.width, img.height)
        if maxSide > 2560 { img = scaled(img, by: 2560 / CGFloat(maxSide)) }
        let alpha = usesAlpha(img)
        if alpha, max(img.width, img.height) > 1600 { img = scaled(img, by: 1600 / CGFloat(max(img.width, img.height))) }
        let out = Paths.output(for: url, suffix: " (сжато)", ext: alpha ? "png" : "jpg")
        try write(img, to: out, quality: 0.62)
        try Paths.ensureSmaller(out, than: url)
        return out
    }

    static func usesAlpha(_ img: CGImage) -> Bool {
        guard hasAlpha(img), let ctx = context(img.width, img.height) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let data = ctx.data else { return true }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * img.height)
        for y in 0..<img.height {
            let row = bytes + y * ctx.bytesPerRow
            for x in 0..<img.width where row[x * 4 + 3] < 250 { return true }
        }
        return false
    }

    static func removeBackground(_ url: URL) throws -> URL {
        let img = try load(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
            throw ConvError("Не нашёл объект на фото")
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ConvError("Не удалось обработать изображение")
        }
        let out = Paths.output(for: url, suffix: " (без фона)", ext: "png")
        try write(cg, to: out)
        return out
    }

    static func toPDF(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for u in urls {
            let cg = try load(u)
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let k = min(1, 842 / max(w, h))
            let ns = NSImage(cgImage: cg, size: NSSize(width: w * k, height: h * k))
            if let page = PDFPage(image: ns) { doc.insert(page, at: doc.pageCount) }
        }
        guard doc.pageCount > 0 else { throw ConvError("Не удалось собрать PDF") }
        let out = Paths.output(for: urls[0], suffix: urls.count > 1 ? " и ещё \(urls.count - 1)" : "", ext: "pdf")
        guard doc.write(to: out) else { throw ConvError("Не удалось сохранить PDF") }
        return out
    }
}

// MARK: - OCR

enum OCR {
    static func text(in img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        req.recognitionLanguages = ["ru-RU", "en-US", "uk-UA"]
        try VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

// MARK: - PDF

enum Pdf {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConvError("Не удалось открыть PDF") }
        if doc.isLocked { throw ConvError("PDF защищён паролем") }
        return doc
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2.5) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = NSSize(width: (rotated ? box.height : box.width) * scale, height: (rotated ? box.width : box.height) * scale)
        guard let ctx = Img.context(Int(size.width), Int(size.height), alpha: false) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    static func toImages(_ url: URL, ext: String) throws -> [URL] {
        let doc = try open(url)
        if doc.pageCount == 1, let page = doc.page(at: 0), let img = render(page) {
            let out = Paths.output(for: url, ext: ext)
            try Img.write(img, to: out, quality: 0.9)
            return [out]
        }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = try Paths.folder(for: url, name: "\(base) (\(ext.uppercased()))")
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let img = render(page) else { continue }
            try Img.write(img, to: folder.appendingPathComponent("\(base)-\(i + 1).\(ext)"), quality: 0.9)
        }
        return [folder]
    }

    static func plainText(_ url: URL) async throws -> String {
        let doc = try open(url)
        if let s = doc.string, s.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { return s }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let img = render(page, scale: 2) {
                parts.append(try OCR.text(in: img))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    static func attributedText(_ url: URL) async throws -> NSAttributedString {
        let doc = try open(url)
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let a = doc.page(at: i)?.attributedString {
                if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
                result.append(a)
            }
        }
        if result.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { return result }
        let text = try await plainText(url)
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    }

    static func compress(_ url: URL) throws -> URL {
        let doc = try open(url)
        let out = Paths.output(for: url, suffix: " (сжато)", ext: "pdf")
        let ok = doc.write(to: out, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        guard ok else { throw ConvError("Не удалось сжать PDF") }
        try Paths.ensureSmaller(out, than: url)
        return out
    }

    static func split(_ url: URL) throws -> URL {
        let doc = try open(url)
        let base = url.deletingPathExtension().lastPathComponent
        let folder = try Paths.folder(for: url, name: "\(base) (страницы)")
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: folder.appendingPathComponent("\(base)-\(i + 1).pdf"))
        }
        return folder
    }

    static func rotate(_ url: URL) throws -> URL {
        let doc = try open(url)
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 }
        }
        let out = Paths.output(for: url, suffix: " (повёрнуто)", ext: "pdf")
        guard doc.write(to: out) else { throw ConvError("Не удалось сохранить PDF") }
        return out
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let result = PDFDocument()
        for u in urls {
            let doc = try open(u)
            for i in 0..<doc.pageCount {
                if let p = doc.page(at: i)?.copy() as? PDFPage { result.insert(p, at: result.pageCount) }
            }
        }
        let out = Paths.output(for: urls[0], suffix: " (объединено)", ext: "pdf")
        guard result.write(to: out) else { throw ConvError("Не удалось сохранить PDF") }
        return out
    }
}

// MARK: - Documents

@MainActor
enum Doc {
    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ["txt", "md", "markdown", "text"].contains(ext) {
            let s = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .windowsCP1251)
            return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    static func write(_ attr: NSAttributedString, to url: URL, ext: String) throws {
        let range = NSRange(location: 0, length: attr.length)
        switch ext {
        case "pdf":
            try pdf(attr, to: url)
        case "txt":
            try attr.string.write(to: url, atomically: true, encoding: .utf8)
        case "docx":
            try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        case "rtf":
            try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        case "html":
            try attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                           .characterEncoding: String.Encoding.utf8.rawValue]).write(to: url)
        default:
            throw ConvError("Формат \(ext.uppercased()) не поддерживается")
        }
    }

    static func pdf(_ attr: NSAttributedString, to url: URL) throws {
        let paper = NSSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: url,
        ])
        info.paperSize = paper
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = paper.width - margin * 2
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: paper.height - margin * 2))
        tv.appearance = NSAppearance(named: .aqua)
        tv.backgroundColor = .white
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = .zero
        tv.textStorage?.setAttributedString(attr)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw ConvError("Не удалось создать PDF") }
    }
}

// MARK: - Video & audio

enum Media {
    static let ffmpeg: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static func ff(_ args: [String]) async throws {
        guard let ffmpeg else { throw ConvError("Для этого нужен ffmpeg (brew install ffmpeg)") }
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }

    private static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        guard ffmpeg != nil else {
            try await nativeConvert(url, to: ext, out: out)
            return out
        }
        let input = ["-i", url.path]
        switch ext {
        case "mp4", "mov":
            do {
                try await ff(input + ["-c", "copy"] + (ext == "mp4" ? ["-movflags", "+faststart"] : []) + [out.path])
            } catch {
                try await ff(input + ["-vf", evenScale, "-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p",
                                      "-c:a", "aac", "-b:a", "160k"] + (ext == "mp4" ? ["-movflags", "+faststart"] : []) + [out.path])
            }
        case "gif":
            try await ff(input + ["-vf", "fps=12,scale='min(540,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0", out.path])
        case "mp3":
            try await ff(input + ["-vn", "-c:a", "libmp3lame", "-q:a", "2", out.path])
        case "m4a":
            try await ff(input + ["-vn", "-c:a", "aac", "-b:a", "192k", out.path])
        case "wav":
            try await ff(input + ["-vn", "-c:a", "pcm_s16le", out.path])
        case "aiff":
            try await ff(input + ["-vn", "-c:a", "pcm_s16be", out.path])
        case "flac":
            try await ff(input + ["-vn", "-c:a", "flac", out.path])
        default:
            throw ConvError("Формат \(ext.uppercased()) не поддерживается")
        }
        return out
    }

    private static func nativeConvert(_ url: URL, to ext: String, out: URL) async throws {
        switch (FileKind.of(url), ext) {
        case (.video, "mp4"): try await export(url, preset: AVAssetExportPresetHighestQuality, type: .mp4, out: out)
        case (.video, "mov"): try await export(url, preset: AVAssetExportPresetHighestQuality, type: .mov, out: out)
        case (_, "m4a") where FileKind.of(url) == .video: try await export(url, preset: AVAssetExportPresetAppleM4A, type: .m4a, out: out)
        case (.audio, "m4a"): try await Shell.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "192000", url.path, out.path])
        case (.audio, "wav"): try await Shell.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16", url.path, out.path])
        case (.audio, "aiff"): try await Shell.run("/usr/bin/afconvert", ["-f", "AIFF", "-d", "BEI16", url.path, out.path])
        case (.audio, "flac"): try await Shell.run("/usr/bin/afconvert", ["-f", "flac", "-d", "flac", url.path, out.path])
        default: throw ConvError("Для этого нужен ffmpeg (brew install ffmpeg)")
        }
    }

    private static func export(_ url: URL, preset: String, type: AVFileType, out: URL) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: preset) else {
            throw ConvError("Не удалось подготовить конвертацию")
        }
        try await session.export(to: out, as: type)
    }

    static func compress(_ url: URL) async throws -> URL {
        let out = Paths.output(for: url, suffix: " (сжато)", ext: "mp4")
        if ffmpeg != nil {
            try await ff(["-i", url.path, "-vf", "scale='min(1280,iw)':-2", "-c:v", "libx264", "-preset", "veryfast", "-crf", "28",
                          "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", out.path])
        } else {
            try await export(url, preset: AVAssetExportPreset1280x720, type: .mp4, out: out)
        }
        try Paths.ensureSmaller(out, than: url)
        return out
    }

    static func mute(_ url: URL) async throws -> URL {
        let out = Paths.output(for: url, suffix: " (без звука)", ext: WheelItem.normalized(url.pathExtension))
        try await ff(["-i", url.path, "-c:v", "copy", "-an", out.path])
        return out
    }

    static func frame(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = CMTime(seconds: min(1, max(0, duration / 2)), preferredTimescale: 600)
        let (img, _) = try await gen.image(at: t)
        let out = Paths.output(for: url, suffix: " (кадр)", ext: "jpg")
        try Img.write(img, to: out)
        return out
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

enum Shell {
    static func run(_ exe: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            let stderr = LockedData()
            errPipe.fileHandleForReading.readabilityHandler = { h in stderr.append(h.availableData) }
            p.terminationHandler = { proc in
                errPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let msg = String(data: stderr.data, encoding: .utf8)?
                        .split(separator: "\n").last.map(String.init) ?? "ошибка \(proc.terminationStatus)"
                    cont.resume(throwing: ConvError(msg))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
