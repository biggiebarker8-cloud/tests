import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import LarkAISolutionsConsultant

struct PhotoInput: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $selection,
                     maxSelectionCount: max(1, 6 - viewModel.pendingPhotos.count),
                     matching: .images) {
            Image(systemName: "photo.on.rectangle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Attach photos for OpenAI")
        .disabled(viewModel.isLoading || viewModel.isPreparingPhotos || viewModel.pendingPhotos.count >= 6)
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            viewModel.isPreparingPhotos = true
            Task {
                defer {
                    selection = []
                    viewModel.isPreparingPhotos = false
                }
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                              let photo = await Self.prepare(data) else {
                            viewModel.errorMessage = "Couldn’t read this photo. Try selecting it again."
                            continue
                        }
                        if viewModel.usesOpenAI { viewModel.pendingPhotos.append(photo) }
                    } catch {
                        viewModel.errorMessage = "Couldn’t load this photo from your photo library."
                    }
                }
            }
        }
    }

    // Re-encode only the selected pixels. This accepts HEIC photos without transmitting camera metadata.
    private nonisolated static func prepare(_ data: Data) async -> ChatImageAttachment? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let jpeg = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { return nil }
        return ChatImageAttachment(mimeType: "image/jpeg", base64Data: (jpeg as Data).base64EncodedString())
    }
}

struct PhotoDraftStatus: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        if viewModel.isPreparingPhotos {
            ProgressView("Preparing photos…").controlSize(.small)
        } else if !viewModel.pendingPhotos.isEmpty {
            HStack {
                Text("Photos attached: \(viewModel.pendingPhotos.count)")
                Button("Remove photos") { viewModel.pendingPhotos.removeAll() }
            }.font(.footnote)
        }
    }
}
