import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

extension VaultStorage {
    func loadPreview(_ item: VaultItem, vaultID: UUID, key: SymmetricKey) async throws -> PreviewContent {
        guard let type = VaultVideoPreview.fileType(for: item.name) else {
            return PreviewContent(item: item, data: try preview(item, vaultID: vaultID, key: key))
        }
        let video = try VaultVideoPreview(item: item, source: object(vaultID, item.id), vaultID: vaultID, key: key, type: type)
        return try await withTaskCancellationHandler {
            guard try await video.asset.load(.isPlayable) else {
                throw VaultError.message("This video's format or codec cannot be played on this Mac.")
            }
            try Task.checkCancellation()
            return PreviewContent(item: item, data: Data(), video: video)
        } onCancel: {
            video.close()
        }
    }
}

final class VaultVideoPreview: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let queue = DispatchQueue(label: "HarborVault.video")
    private let type: UTType
    private var reader: VaultCrypto.ChunkReader?

    static func fileType(for name: String) -> UTType? {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension), type.conforms(to: .movie) else { return nil }
        return type
    }

    init(item: VaultItem, source: URL, vaultID: UUID, key: SymmetricKey, type: UTType) throws {
        self.type = type
        reader = try VaultCrypto.ChunkReader(source: source, key: key, vaultID: vaultID, fileID: item.id, expectedSize: item.size)
        let mediaURL = URL(string: "harbor-video://preview/\(item.id.uuidString)")!
            .appendingPathExtension(type.preferredFilenameExtension ?? "mov")
        asset = AVURLAsset(url: mediaURL)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func close() {
        asset.cancelLoading()
        queue.async { self.reader = nil }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let reader else {
            request.finishLoading(with: CancellationError())
            return true
        }
        if let info = request.contentInformationRequest {
            info.contentType = type.identifier
            info.contentLength = reader.length
            info.isByteRangeAccessSupported = true
        }
        load(request)
        return true
    }

    private func load(_ request: AVAssetResourceLoadingRequest) {
        guard !request.isCancelled, !request.isFinished else { return }
        guard let reader else { request.finishLoading(with: CancellationError()); return }
        guard let data = request.dataRequest else { request.finishLoading(); return }
        let offset = max(data.currentOffset, data.requestedOffset)
        let (end, overflow) = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
        let limit = data.requestsAllDataToEndOfResource || overflow ? reader.length : min(reader.length, end)
        guard offset < limit else { request.finishLoading(); return }
        do {
            let bytes = try reader.readBytes(at: offset, upTo: Int(min(limit - offset, Int64(VaultCrypto.chunkSize))))
            data.respond(with: bytes)
            if offset + Int64(bytes.count) == limit {
                request.finishLoading()
            } else {
                queue.async { [weak self] in self?.load(request) }
            }
        } catch {
            request.finishLoading(with: error)
        }
    }
}

struct VideoPreviewView: NSViewRepresentable {
    let video: VaultVideoPreview

    final class Coordinator {
        weak var video: VaultVideoPreview?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.video !== video else { return }
        view.player?.pause()
        let player = AVPlayer(playerItem: AVPlayerItem(asset: video.asset))
        player.allowsExternalPlayback = false
        view.player = player
        context.coordinator.video = video
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
    }
}
