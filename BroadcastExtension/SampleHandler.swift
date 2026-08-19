import ReplayKit
import CoreMedia

final class SampleHandler: RPBroadcastSampleHandler {
    private let controller = BroadcastStreamController()

    override func broadcastStarted(
        withSetupInfo setupInfo: [String : NSObject]?
    ) {
        controller.start(
            config: RuntimeBridge.readConfig()
        )
    }

    override func broadcastPaused() {
        // ReplayKit pauses sample delivery.
    }

    override func broadcastResumed() {
        // No special action required.
    }

    override func broadcastFinished() {
        controller.stop()
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        switch sampleBufferType {
        case .video:
            controller.submit(sampleBuffer)

        case .audioApp:
            break

        case .audioMic:
            break

        @unknown default:
            break
        }
    }
}
