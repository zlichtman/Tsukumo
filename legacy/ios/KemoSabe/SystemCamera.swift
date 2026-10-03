#if os(iOS)
import SwiftUI
import UIKit

/// A photo from the camera: its JPEG and when it was taken.
struct CameraPhoto: Sendable {
    let jpeg: Data
    let taken: Date?
}

/// The system camera, for the profile's Add, the composer's +, and Docs and Journal. KemoSabe has no
/// capture pipeline or filters of its own: the film camera was removed after its live filter
/// preview crashed on device (build 56, `setDeliversPreviewSizedOutputBuffers:`).
struct CameraSheet: View {
    let finish: (CameraPhoto) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            SystemCamera(finish: finish, close: { dismiss() }).ignoresSafeArea()
        } else {
            // The Simulator and some iPads have no camera.
            VStack(spacing: 16) {
                Image(systemName: "camera").font(.largeTitle).foregroundStyle(.secondary)
                Text("No camera here").font(KemoType.font(.headline)).accessibilityIdentifier("cameraUnavailable")
                Button("Close") { dismiss() }.buttonStyle(.bordered).accessibilityIdentifier("cameraClose")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SystemCamera: UIViewControllerRepresentable {
    let finish: (CameraPhoto) -> Void
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SystemCamera
        init(_ parent: SystemCamera) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // `jpegData` bakes in the orientation, so the photo is upright everywhere it goes.
            if let image = info[.originalImage] as? UIImage, let jpeg = image.jpegData(compressionQuality: 0.9) {
                parent.finish(CameraPhoto(jpeg: jpeg, taken: Date()))
            }
            parent.close()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.close() }
    }
}
#endif
