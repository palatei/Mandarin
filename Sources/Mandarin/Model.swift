import Foundation
import UniformTypeIdentifiers

struct ConvError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

enum FileKind: Equatable {
    case image, pdf, document, video, audio, unknown

    static let documentExts: Set<String> = ["docx", "doc", "rtf", "txt", "md", "markdown", "html", "htm", "odt", "text"]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if documentExts.contains(ext) { return .document }
        guard let t = UTType(filenameExtension: ext) else { return .unknown }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .text) { return .document }
        return .unknown
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .video: "film"
        case .audio: "waveform"
        case .unknown: "questionmark"
        }
    }
}

enum Op: Equatable {
    case convert(String)
    case compress, resize, removeBackground, crop, frame, rotate, grayscale, ocr
    case split, merge
    case mute, frameGrab
}

struct WheelItem {
    let title: String
    let symbol: String?
    let op: Op

    var progress: String {
        switch op {
        case .convert(let e): "Конвертирую в \(e.uppercased())…"
        case .compress: "Сжимаю…"
        case .resize: "Уменьшаю…"
        case .removeBackground: "Убираю фон…"
        case .rotate: "Поворачиваю…"
        case .grayscale: "Делаю чёрно-белым…"
        case .ocr: "Распознаю текст…"
        case .split: "Разделяю страницы…"
        case .merge: "Объединяю…"
        case .mute: "Убираю звук…"
        case .frameGrab: "Сохраняю кадр…"
        case .crop, .frame: "Открываю редактор…"
        }
    }

    static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": "jpg"
        case "tif": "tiff"
        case "htm": "html"
        case "aif": "aiff"
        case "markdown": "md"
        default: ext.lowercased()
        }
    }

    static func rings(for urls: [URL]) -> (inner: [WheelItem], outer: [WheelItem]) {
        guard let first = urls.first else { return ([], []) }
        let kind = FileKind.of(first)
        let src = normalized(first.pathExtension)
        let ff = Media.ffmpeg != nil
        let sameKindCount = urls.filter { FileKind.of($0) == kind }.count

        func formats(_ list: [String]) -> [WheelItem] {
            list.filter { $0 != src }.map { WheelItem(title: $0.uppercased(), symbol: nil, op: .convert($0)) }
        }

        switch kind {
        case .image:
            return (formats(["jpg", "png", "heic", "pdf", "tiff"]), [
                WheelItem(title: "Сжать", symbol: "arrow.down.right.and.arrow.up.left", op: .compress),
                WheelItem(title: "½ размер", symbol: "aspectratio", op: .resize),
                WheelItem(title: "Без фона", symbol: "wand.and.stars", op: .removeBackground),
                WheelItem(title: "Обрезать", symbol: "crop", op: .crop),
                WheelItem(title: "Фон", symbol: "photo.artframe", op: .frame),
                WheelItem(title: "Повернуть", symbol: "rotate.right", op: .rotate),
                WheelItem(title: "Ч/Б", symbol: "circle.lefthalf.filled", op: .grayscale),
                WheelItem(title: "Текст", symbol: "text.viewfinder", op: .ocr),
            ])
        case .pdf:
            var outer = [
                WheelItem(title: "Сжать", symbol: "arrow.down.right.and.arrow.up.left", op: .compress),
                WheelItem(title: "Разделить", symbol: "square.split.2x1", op: .split),
                WheelItem(title: "Повернуть", symbol: "rotate.right", op: .rotate),
                WheelItem(title: "Текст", symbol: "text.viewfinder", op: .ocr),
            ]
            if sameKindCount > 1 {
                outer.insert(WheelItem(title: "Объединить", symbol: "square.stack.3d.up", op: .merge), at: 0)
            }
            return (formats(["docx", "txt", "rtf", "jpg", "png"]), outer)
        case .document:
            return (formats(["pdf", "docx", "txt", "rtf", "html"]), [])
        case .video:
            let list = ff ? ["mp4", "mov", "gif", "mp3", "m4a"] : ["mp4", "mov", "m4a"]
            var outer = [
                WheelItem(title: "Сжать", symbol: "arrow.down.right.and.arrow.up.left", op: .compress),
                WheelItem(title: "Кадр", symbol: "photo", op: .frameGrab),
            ]
            if ff { outer.insert(WheelItem(title: "Без звука", symbol: "speaker.slash", op: .mute), at: 1) }
            return (formats(list), outer)
        case .audio:
            return (formats(ff ? ["mp3", "m4a", "wav", "aiff", "flac"] : ["m4a", "wav", "aiff", "flac"]), [])
        case .unknown:
            return ([], [])
        }
    }
}
