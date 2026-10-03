import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

struct ChatImage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let jpeg: Data
    let width: Int
    let height: Int
    static func prepare(_ data: Data) throws -> Self {
        guard data.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 50_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { throw ChatImageError.invalid }
        // Re-encode pixels only: no source location, camera, filename or EXIF fields.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ChatImageError.invalid }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 2_000_000 else { throw ChatImageError.invalid }
        return .init(jpeg: output as Data, width: image.width, height: image.height)
    }
    func validate() throws {
        guard jpeg.count <= 2_000_000, width > 0, height > 0, width <= 2048, height <= 2048,
              let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == width, props[kCGImagePropertyPixelHeight] as? Int == height else { throw ChatImageError.invalid }
    }
}
enum ChatImageError: LocalizedError {
    case invalid, unsupported, limit
    var errorDescription: String? { switch self {
    case .invalid: "Choose a single still image under 20 MB and 50 megapixels. Prepared images must fit within 2 MB."
    case .unsupported: "Select a model connection configured to accept images. Apple’s current local chat model is text-only."
    case .limit: "Use up to four images per message and 8 MB of images per conversation. Start a new conversation to add more."
    } }
}
struct ChatImageThumbnail: View {
    let image: ChatImage
    var body: some View {
        Group {
            #if os(macOS)
            if let value = NSImage(data: image.jpeg) { Image(nsImage: value).resizable().scaledToFit() }
            #else
            if let value = UIImage(data: image.jpeg) { Image(uiImage: value).resizable().scaledToFit() }
            #endif
        }.frame(width: 76, height: 76).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9)).clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityLabel("Attached image")
    }
}
struct ChatAttachmentTray: View {
    @Environment(AppStore.self) private var store
    @Binding var images: [ChatImage]
    var showAttachButton = true
    var request = 0
    @State private var importing = false
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    @State private var epoch = UUID()
    var body: some View {
        HStack(spacing: 8) {
            if showAttachButton { Button {
                guard store.modelRoute == .api, store.activeAPIProfile?.supportsImages == true else { store.error = ChatImageError.unsupported.localizedDescription; return }
                importing = true
            } label: { Image(systemName: "paperclip").frame(width: 32, height: 30) }.buttonStyle(.plain).accessibilityLabel("Attach images").accessibilityIdentifier("attachImages").disabled(loading || images.count >= 4 || store.isThinking) }
            if loading { KemoOrb(size: 18) }
            ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(images) { image in
                ChatImageThumbnail(image: image).overlay(alignment: .topTrailing) {
                    Button { images.removeAll { $0.id == image.id } } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7)) }.buttonStyle(.plain).accessibilityLabel("Remove image")
                }
            } } }.frame(height: images.isEmpty ? 0 : 76)
            if images.isEmpty && showAttachButton { Text("Add an image").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .onChange(of: request) {
            guard !loading, images.count < 4, !store.isThinking else { return }
            guard store.modelRoute == .api, store.activeAPIProfile?.supportsImages == true else { store.error = ChatImageError.unsupported.localizedDescription; return }
            importing = true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            guard urls.count + images.count <= 4 else { store.error = ChatImageError.limit.localizedDescription; return }
            let profile = store.activeAPIProfile; let token = UUID(); epoch = token; loading = true
            task = Task {
                do {
                    let added = try await Task.detached(priority: .userInitiated) {
                        try urls.map { url in
                            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                            let data = try handle.read(upToCount: 20_000_001) ?? Data()
                            return try ChatImage.prepare(data)
                        }
                    }.value
                    guard token == epoch, !Task.isCancelled, store.modelRoute == .api, profile == store.activeAPIProfile, profile?.supportsImages == true else { return }
                    images += added; loading = false
                } catch { guard token == epoch else { return }; store.error = error.localizedDescription; loading = false }
            }
        }
        .onChange(of: store.conversationRevision) { clear() }
        .onChange(of: store.state.selectedAPIProfile) { clear() }
        .onChange(of: store.modelRoute) { clear() }
        .onDisappear { clear() }
    }
    private func clear() { epoch = UUID(); task?.cancel(); images = []; loading = false }
}
