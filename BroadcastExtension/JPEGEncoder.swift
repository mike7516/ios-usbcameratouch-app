import Foundation
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// iOS-native JPEG encoder.
///
/// Uses:
/// - Core Image for resize/render
/// - ImageIO / CGImageDestination for JPEG compression
///
/// No libjpeg-turbo, no bridging header, no C code.
///
/// Note:
/// Apple exposes JPEG compression quality, but this implementation does
/// not request a specific 4:2:0 / 4:2:2 chroma-subsampling mode.
/// The actual sampling is inspected after encoding by JPEGSamplingInspector.
final class JPEGEncoder {
    enum EncoderError: LocalizedError {
        case noImageBuffer
        case invalidTargetSize
        case createCGImageFailed
        case createDestinationFailed
        case finalizeFailed
        case invalidJPEG

        var errorDescription: String? {
            switch self {
            case .noImageBuffer:
                return "CMSampleBuffer has no CVPixelBuffer"
            case .invalidTargetSize:
                return "Invalid target width/height"
            case .createCGImageFailed:
                return "Core Image failed to create CGImage"
            case .createDestinationFailed:
                return "ImageIO failed to create JPEG destination"
            case .finalizeFailed:
                return "ImageIO failed to finalize JPEG"
            case .invalidJPEG:
                return "Encoded data is not a complete JPEG"
            }
        }
    }

    private let context = CIContext(
        options: [
            .cacheIntermediates: false
        ]
    )

    func encode(
        sampleBuffer: CMSampleBuffer,
        width: Int,
        height: Int,
        quality: Int
    ) throws -> Data {
        guard let pixelBuffer =
            CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            throw EncoderError.noImageBuffer
        }

        let source = CIImage(
            cvPixelBuffer: pixelBuffer
        )

        return try encode(
            image: source,
            width: width,
            height: height,
            quality: quality
        )
    }

    func encodeSolidColor(
        mode: ImageMode,
        width: Int,
        height: Int,
        quality: Int
    ) throws -> Data {
        let color: CIColor

        switch mode {
        case .red:
            color = CIColor(
                red: 1,
                green: 0,
                blue: 0,
                alpha: 1
            )

        case .green:
            color = CIColor(
                red: 0,
                green: 1,
                blue: 0,
                alpha: 1
            )

        case .blue:
            color = CIColor(
                red: 0,
                green: 0,
                blue: 1,
                alpha: 1
            )
        }

        guard width > 0, height > 0 else {
            throw EncoderError.invalidTargetSize
        }

        let rect = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )

        let image = CIImage(
            color: color
        )
        .cropped(to: rect)

        return try makeJPEG(
            image: image,
            rect: rect,
            quality: quality
        )
    }

    private func encode(
        image source: CIImage,
        width: Int,
        height: Int,
        quality: Int
    ) throws -> Data {
        guard width > 0, height > 0 else {
            throw EncoderError.invalidTargetSize
        }

        let sourceExtent = source.extent

        guard
            sourceExtent.width > 0,
            sourceExtent.height > 0,
            sourceExtent.width.isFinite,
            sourceExtent.height.isFinite
        else {
            throw EncoderError.invalidTargetSize
        }

        // Match the Python PIL resize(target_size) behavior:
        // stretch the source directly to the requested output size.
        let normalized = source.transformed(
            by: CGAffineTransform(
                translationX: -sourceExtent.minX,
                y: -sourceExtent.minY
            )
        )

        let scaleX =
            CGFloat(width) /
            sourceExtent.width

        let scaleY =
            CGFloat(height) /
            sourceExtent.height

        let resized = normalized.transformed(
            by: CGAffineTransform(
                scaleX: scaleX,
                y: scaleY
            )
        )

        let targetRect = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )

        return try makeJPEG(
            image: resized.cropped(
                to: targetRect
            ),
            rect: targetRect,
            quality: quality
        )
    }

    private func makeJPEG(
        image: CIImage,
        rect: CGRect,
        quality: Int
    ) throws -> Data {
        guard let cgImage = context.createCGImage(
            image,
            from: rect
        ) else {
            throw EncoderError.createCGImageFailed
        }

        let output = NSMutableData()

        guard let destination =
            CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw EncoderError.createDestinationFailed
        }

        let clamped =
            max(1, min(100, quality))

        let properties: CFDictionary = [
            kCGImageDestinationLossyCompressionQuality:
                Double(clamped) / 100.0
        ] as CFDictionary

        CGImageDestinationAddImage(
            destination,
            cgImage,
            properties
        )

        guard CGImageDestinationFinalize(
            destination
        ) else {
            throw EncoderError.finalizeFailed
        }

        let data = output as Data

        guard
            data.count >= 4,
            data[data.startIndex] == 0xFF,
            data[data.index(after: data.startIndex)] == 0xD8,
            data[data.index(data.endIndex, offsetBy: -2)] == 0xFF,
            data[data.index(before: data.endIndex)] == 0xD9
        else {
            throw EncoderError.invalidJPEG
        }

        return data
    }
}
