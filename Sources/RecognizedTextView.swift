import SwiftUI
import AppKit
import VisionKit

@MainActor final class RecognizedTextSession: ObservableObject {
    typealias Worker = @Sendable (PreviewContent, TextRecognitionCancellation, @Sendable (Int, Int) -> Void) throws -> RecognizedDocument
    @Published private(set) var visible = false
    @Published private(set) var running = false
    @Published private(set) var result: RecognizedDocument?
    @Published private(set) var error: String?
    @Published private(set) var progress = ""
    @Published private(set) var imageAnalysis: ImageAnalysis?
    private static let analyzer = ImageAnalyzer()
    private var imageTask: Task<Void, Never>?
    private var token = UUID()
    private var task: Task<RecognizedDocument, Error>?
    private var cancellation: TextRecognitionCancellation?
    func toggle(_ content: PreviewContent) {
        if visible {
            clear()
        } else if ImageAnalyzer.isSupported,
                  (content.item.name as NSString).pathExtension.lowercased() != "pdf",
                  let image = NSImage(data: content.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            startImageSelection(image)
        } else {
            start(content)
        }
    }
    private func startImageSelection(_ image: CGImage) {
        clear()
        visible = true
        running = true
        progress = "Recognizing text…"
        let current = token
        imageTask = Task { [weak self] in
            do {
                let analysis = try await Self.analyzer.analyze(image, orientation: .up, configuration: .init(.text))
                guard let self, self.token == current, !Task.isCancelled else { return }
                if analysis.hasResults(for: .text) { self.imageAnalysis = analysis }
                self.running = false
                self.progress = ""
                self.imageTask = nil
            } catch {
                guard let self, self.token == current, !Task.isCancelled else { return }
                self.error = "Text recognition could not finish. Try again."
                self.running = false
                self.progress = ""
                self.imageTask = nil
            }
        }
    }
    func start(_ content: PreviewContent, worker: @escaping Worker = { try TextRecognition.recognize($0, cancellation: $1, progress: $2) }) {
        clear(); visible = true; running = true; progress = "Recognizing text…"
        let current = token
        let control = TextRecognitionCancellation(); cancellation = control
        let job = Task.detached(priority: .userInitiated) {
            try await withTaskCancellationHandler {
                try worker(content, control) { page, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.token == current, self.running else { return }
                        self.progress = total == 1 ? "Recognizing text…" : "Recognizing page \(page) of \(total)…"
                    }
                }
            } onCancel: { control.cancel() }
        }
        task = job
        Task { [weak self] in
            do {
                let value = try await job.value
                guard let self, self.token == current else { return }
                self.result = value; self.running = false; self.progress = ""; self.task = nil; self.cancellation = nil
            } catch {
                guard let self, self.token == current else { return }
                self.running = false; self.progress = ""; self.task = nil; self.cancellation = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func clear() {
        imageTask?.cancel(); imageTask = nil; imageAnalysis = nil
        token = UUID(); cancellation?.cancel(); cancellation = nil; task?.cancel(); task = nil
        visible = false; running = false; result = nil; error = nil; progress = ""
    }
    @discardableResult func copy(to pasteboard: NSPasteboard) -> Bool {
        guard visible, let result, !result.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(result.text, forType: .string)
    }
}

struct RecognizedTextButton: View {
    @ObservedObject var session: RecognizedTextSession
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label("Text", systemImage: "text.viewfinder") }
            .buttonStyle(HarborButtonStyle(primary: session.visible, compact: true))
            .disabled(!enabled).accessibilityLabel("Recognize text (OCR)")
            .help("Recognize selectable text from this image or PDF on your Mac")
    }
}

struct RecognizedTextPanel: View {
    @ObservedObject var session: RecognizedTextSession
    let compact: Bool
    private typealias D = HarborDesign
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Recognized text").font(D.font(compact ? 11 : 13, .semibold))
                Spacer()
                if let result = session.result, !result.isEmpty {
                    Button { session.copy(to: .general) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(HarborButtonStyle(compact: true)).help("Copy recognized text to the clipboard")
                }
                Button(session.running ? "Cancel" : "Back") { session.clear() }.buttonStyle(.plain).font(D.font(11))
            }.padding(compact ? 12 : 18)
            Divider()
            Group {
                if session.running {
                    VStack(spacing: 12) { ProgressView(); Text(session.progress).font(D.font(12)).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = session.error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 24)).foregroundStyle(.secondary)
                        Text(error).font(D.font(12)).multilineTextAlignment(.center)
                        Text("Choose Back to return to the file, then Text to try again.").font(D.font(11)).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result = session.result, !result.isEmpty {
                    ScrollView {
                        Text(result.text).font(D.font(compact ? 12 : 14)).textSelection(.enabled).lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(compact ? 14 : 24)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.viewfinder").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("No readable text found").font(D.font(13, .medium))
                        Text("Try a clearer image or a higher-resolution scan.").font(D.font(11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if !compact {
                Divider()
                Text("Recognized on this Mac · Check the result for mistakes · Text clears when this preview closes or locks")
                    .font(D.font(10)).foregroundStyle(.secondary).padding(14)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(D.canvas)
    }
}

struct OCRPreviewDocument: View {
    let content: PreviewContent
    @Binding var zoom: Double
    @ObservedObject var textSession: RecognizedTextSession
    var compact = false
    var body: some View {
        if let analysis = textSession.imageAnalysis {
            VStack(spacing: 0) {
                QuickViewDocument(content: content, zoom: $zoom, imageAnalysis: analysis)
                Text("Select text on the image, then press ⌘C to copy")
                    .font(HarborDesign.font(11)).foregroundStyle(.secondary).padding(10)
            }
        } else if textSession.visible {
            RecognizedTextPanel(session: textSession, compact: compact)
        } else {
            QuickViewDocument(content: content, zoom: $zoom)
        }
    }
}
