import SwiftUI
import ReplayKit

struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(
        context: Context
    ) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 56,
                height: 56
            )
        )

        picker.preferredExtension =
            RuntimeConstants.broadcastExtensionBundleID

        picker.showsMicrophoneButton = false

        return picker
    }

    func updateUIView(
        _ uiView: RPSystemBroadcastPickerView,
        context: Context
    ) {
        uiView.preferredExtension =
            RuntimeConstants.broadcastExtensionBundleID
    }
}
