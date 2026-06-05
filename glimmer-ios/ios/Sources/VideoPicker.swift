import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 录制(.camera) 或 选择视频文件(.photoLibrary)。不限制时长。
struct VideoPicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onComplete: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = sourceType
        p.mediaTypes = [UTType.movie.identifier]
        p.videoQuality = .typeHigh
        p.allowsEditing = false         // 不强制裁剪，原样使用
        if sourceType == .camera {
            p.cameraCaptureMode = .video
        }
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onComplete: (URL?) -> Void
        init(_ onComplete: @escaping (URL?) -> Void) { self.onComplete = onComplete }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let url = (info[.mediaURL] as? URL)
            picker.dismiss(animated: true) { self.onComplete(url) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { self.onComplete(nil) }
        }
    }
}
