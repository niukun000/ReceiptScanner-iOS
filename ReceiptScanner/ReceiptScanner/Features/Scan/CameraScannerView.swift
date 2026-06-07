import SwiftUI
import UIKit
import VisionKit

#if os(iOS)
/// A SwiftUI wrapper for Apple's VisionKit Document Camera.
struct CameraScannerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var didFinishWithImage: (UIImage) -> Void
    var didFinishWithError: (Error) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scannerViewController = VNDocumentCameraViewController()
        scannerViewController.delegate = context.coordinator
        return scannerViewController
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: CameraScannerView

        init(parent: CameraScannerView) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            if scan.pageCount > 0 {
                let image = scan.imageOfPage(at: 0)
                parent.didFinishWithImage(image)
            }
            parent.isPresented = false
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.isPresented = false
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.didFinishWithError(error)
            parent.isPresented = false
        }
    }
}
#endif

