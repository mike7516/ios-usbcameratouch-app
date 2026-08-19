import Foundation

/// Reads JPEG SOF sampling factors and reports the actual chroma layout
/// produced by the iOS native JPEG encoder.
///
/// Typical results:
/// - 4:2:0
/// - 4:2:2
/// - 4:4:4
/// - 4:4:0
/// - Native / Unknown
enum JPEGSamplingInspector {
    static func describe(_ data: Data) -> String {
        let bytes = [UInt8](data)

        guard
            bytes.count >= 4,
            bytes[0] == 0xFF,
            bytes[1] == 0xD8
        else {
            return "Native / Unknown"
        }

        var i = 2

        while i + 3 < bytes.count {
            while i < bytes.count,
                  bytes[i] != 0xFF {
                i += 1
            }

            guard i < bytes.count else {
                break
            }

            while i < bytes.count,
                  bytes[i] == 0xFF {
                i += 1
            }

            guard i < bytes.count else {
                break
            }

            let marker = bytes[i]
            i += 1

            // Standalone markers.
            if marker == 0xD8 ||
                marker == 0xD9 ||
                marker == 0x01 ||
                (0xD0...0xD7).contains(marker) {
                continue
            }

            guard i + 1 < bytes.count else {
                break
            }

            let segmentLength =
                (Int(bytes[i]) << 8) |
                Int(bytes[i + 1])

            guard
                segmentLength >= 2,
                i + segmentLength <= bytes.count
            else {
                break
            }

            if isSOF(marker) {
                // segment layout after 2-byte length:
                // precision(1), height(2), width(2), components(1),
                // then 3 bytes/component: id, sampling, table.
                let payload = i + 2

                guard payload + 6 <= bytes.count else {
                    return "Native / Unknown"
                }

                let componentCount =
                    Int(bytes[payload + 5])

                guard componentCount >= 3 else {
                    return "Native / Gray"
                }

                let firstComponent =
                    payload + 6

                guard firstComponent + 2 < bytes.count else {
                    return "Native / Unknown"
                }

                let ySampling =
                    bytes[firstComponent + 1]

                let h =
                    Int(ySampling >> 4)

                let v =
                    Int(ySampling & 0x0F)

                switch (h, v) {
                case (2, 2):
                    return "Native / 4:2:0"

                case (2, 1):
                    return "Native / 4:2:2"

                case (1, 1):
                    return "Native / 4:4:4"

                case (1, 2):
                    return "Native / 4:4:0"

                default:
                    return "Native / H\(h)V\(v)"
                }
            }

            i += segmentLength
        }

        return "Native / Unknown"
    }

    private static func isSOF(
        _ marker: UInt8
    ) -> Bool {
        switch marker {
        case 0xC0, 0xC1, 0xC2, 0xC3,
             0xC5, 0xC6, 0xC7,
             0xC9, 0xCA, 0xCB,
             0xCD, 0xCE, 0xCF:
            return true

        default:
            return false
        }
    }
}
