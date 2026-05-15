import SwiftUI
import VisionKit
import PhotosUI

// MARK: - Camera Document Scanner (VisionKit)

/// Wraps Apple's VNDocumentCameraViewController for SwiftUI
struct DocumentCameraView: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for i in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: i))
            }
            controller.dismiss(animated: true) {
                self.onScan(images)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) {
                self.onCancel()
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            print("🔴 Scanner error: \(error.localizedDescription)")
            controller.dismiss(animated: true) {
                self.onCancel()
            }
        }
    }
}

// MARK: - Photo Picker (PHPicker)

/// Wraps PHPickerViewController for selecting images from Photos
struct PhotoPickerView: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                onCancel()
                return
            }

            provider.loadObject(ofClass: UIImage.self) { image, error in
                DispatchQueue.main.async {
                    if let image = image as? UIImage {
                        self.onPick(image)
                    } else {
                        self.onCancel()
                    }
                }
            }
        }
    }
}

// MARK: - File Document Picker

/// A document the user imported from Files. Carries both the UIImage we
/// show in the review screen AND the original file bytes, so PDFs land
/// in Supabase Storage as actual PDFs (not flattened JPEGs).
struct PickedDocument {
    let image: UIImage
    let originalData: Data?
    let mimeType: String?
}

/// Wraps UIDocumentPickerViewController for importing PDFs and images from Files.
struct FilePickerView: UIViewControllerRepresentable {
    let onPick: (PickedDocument) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .image, .pdf, .jpeg, .png, .heic
        ])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (PickedDocument) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (PickedDocument) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }

            guard url.startAccessingSecurityScopedResource() else {
                onCancel()
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? Data(contentsOf: url) else {
                onCancel()
                return
            }

            let ext = url.pathExtension.lowercased()

            // PDF → render first page for AI preview, keep original bytes.
            if ext == "pdf" {
                if let pdfImage = Self.renderPDFFirstPage(url: url) {
                    onPick(PickedDocument(
                        image: pdfImage,
                        originalData: data,
                        mimeType: "application/pdf"
                    ))
                } else {
                    onCancel()
                }
                return
            }

            // Image format
            if let image = UIImage(data: data) {
                onPick(PickedDocument(
                    image: image,
                    originalData: data,
                    mimeType: Self.mime(for: ext)
                ))
            } else {
                onCancel()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }

        private static func renderPDFFirstPage(url: URL) -> UIImage? {
            guard let document = CGPDFDocument(url as CFURL),
                  let page = document.page(at: 1) else { return nil }

            let pageRect = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 2.0
            let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                ctx.cgContext.drawPDFPage(page)
            }
            return image
        }

        private static func mime(for ext: String) -> String {
            switch ext {
            case "png": return "image/png"
            case "heic", "heif": return "image/heic"
            case "jpg", "jpeg": return "image/jpeg"
            default: return "application/octet-stream"
            }
        }
    }
}
