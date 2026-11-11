import AppKit
import Vision

/// «Текст со снимка экрана» (замена TextSniper): выделяешь область, текст распознаётся и уходит в буфер.
/// Распознавание идёт на устройстве через Vision (ru + en), QR и штрихкоды тоже распознаются.
@MainActor
final class TextCapture {
    private let settings: AppSettings
    private var running = false
    /// Модель Vision готова. Первое «точное» распознавание в новой сборке компилирует модель ~30 с.
    private var warm = false
    private var warmingUp = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Прогрев модели в фоне при запуске, чтобы первый ⌘⇧2 срабатывал сразу.
    func warmUp() {
        guard !warm, !warmingUp else { return }
        warmingUp = true
        Task {
            let started = Date()
            await Task.detached(priority: .utility) { OCR.warmUp() }.value
            warm = true
            warmingUp = false
            Log.info(String(format: "OCR прогрет за %.1f с", Date().timeIntervalSince(started)))
        }
    }

    func start() {
        guard !running else {
            Toast.show("Ещё распознаю предыдущий снимок…", systemImage: "hourglass", color: .orange)
            return
        }

        // Без доступа к «Записи экрана» screencapture увидит только обои, а не окна.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            Toast.show("Нужен доступ к записи экрана",
                       subtitle: "Включи Beacon Hub в Настройки → Конфиденциальность → Запись экрана и перезапусти приложение",
                       systemImage: "exclamationmark.triangle.fill", color: .orange, duration: 5)
            return
        }

        running = true
        let joinLines = settings.ocrJoinLines
        Task {
            defer { running = false }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("beaconhub-capture-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }

            // -i: интерактивное выделение области (Esc отменяет), -x: без звука.
            _ = try? await Shell.run("/usr/sbin/screencapture", ["-i", "-x", file.path], timeout: 300)
            guard FileManager.default.fileExists(atPath: file.path) else { return } // отмена

            if warm {
                Toast.show("Распознаю…", systemImage: "text.viewfinder", color: .blue, duration: 30)
            } else {
                Toast.show("Готовлю распознавание…", subtitle: "Только в первый раз после установки, до 30 секунд",
                           systemImage: "hourglass", color: .orange, duration: 60)
            }

            let result = await Task.detached(priority: .userInitiated) {
                OCR.recognize(fileURL: file, joinLines: joinLines)
            }.value
            warm = true

            if let code = result.barcodes.first {
                copy(code)
                Toast.show("QR-код скопирован", subtitle: code, systemImage: "qrcode")
            } else if !result.text.isEmpty {
                copy(result.text)
                let lines = result.text.split(separator: "\n").count
                Toast.show(lines > 1 ? "Скопировано строк: \(lines)" : "Текст скопирован",
                           subtitle: result.text.replacingOccurrences(of: "\n", with: " "),
                           systemImage: "text.viewfinder")
            } else {
                Toast.show("Текст не найден", subtitle: "Попробуй выделить область крупнее",
                           systemImage: "text.viewfinder", color: .orange)
            }
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

enum OCR {
    struct Result {
        var text: String
        var barcodes: [String]
    }

    static func recognize(fileURL: URL, joinLines: Bool) -> Result {
        guard let image = NSImage(contentsOf: fileURL),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Result(text: "", barcodes: [])
        }
        return recognize(cgImage: cg, joinLines: joinLines)
    }

    /// Распознаёт маленькую картинку с текстом, чтобы система скомпилировала и закэшировала модель.
    static func warmUp() {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 60, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 60).fill()
        ("Beacon Hub Привет" as NSString).draw(at: NSPoint(x: 10, y: 15),
                                                 withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
        NSGraphicsContext.restoreGraphicsState()
        if let cg = rep.cgImage { _ = recognize(cgImage: cg, joinLines: false) }
    }

    static func recognize(cgImage cg: CGImage, joinLines: Bool) -> Result {

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = ["ru-RU", "en-US"]

        let barcodeRequest = VNDetectBarcodesRequest()

        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([textRequest, barcodeRequest])
        } catch {
            Log.info("OCR: \(error.localizedDescription)")
            return Result(text: "", barcodes: [])
        }

        let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let barcodes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue).filter { !$0.isEmpty }
        let text = joinLines ? lines.joined(separator: " ") : lines.joined(separator: "\n")
        return Result(text: text.trimmingCharacters(in: .whitespacesAndNewlines), barcodes: barcodes)
    }
}
