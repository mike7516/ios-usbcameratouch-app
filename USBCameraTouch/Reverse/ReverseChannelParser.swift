import Foundation

/// Parses the 8808 reverse channel: interleaved ACK bytes and `'TC'` touch packets.
///
/// `'TC'` packet (8808 → App, little-endian coords):
///   0x54 0x43 | count(0-2) | per-contact 6B: touchId(1) + x(2 LE) + y(2 LE) + tip(1)
///
/// Any byte that is **not** part of a valid `'TC'` packet is treated as one ACK
/// (the device sends one ACK per processed frame). The exact ACK byte value is
/// irrelevant as long as it does not form a valid `'TC'` packet — the device
/// should avoid `0x54` for ACK (see SPEC §12.2). Handles split/coalesced reads.
final class ReverseChannelParser {
    struct Contact {
        let touchId: UInt8
        let x: UInt16          // 640×1136 panel coordinate (little-endian on wire)
        let y: UInt16
        let tipDown: Bool      // tip_switch: true = down, false = released
    }

    /// One ACK consumed. Wire it to `FrameStreamSender.ackReceived()`.
    var onAck: (() -> Void)?
    /// A `'TC'` touch event (0..2 contacts). Wire it to `TouchController.handle`.
    var onTouch: (([Contact]) -> Void)?

    private var buf = [UInt8]()

    private static let magic0: UInt8 = 0x54   // 'T'
    private static let magic1: UInt8 = 0x43   // 'C'
    private static let maxContacts = 2

    /// Feed raw reverse-channel bytes (called on the transport/sender queue).
    func feed(_ data: Data) {
        buf.append(contentsOf: data)
        drain()
    }

    private func drain() {
        var i = 0

        while i < buf.count {
            let b = buf[i]

            // Not a possible 'TC' start → one ACK byte.
            if b != Self.magic0 {
                onAck?()
                i += 1
                continue
            }

            // b == 0x54: need magic(2)+count(1) = 3 bytes to decide.
            if i + 2 >= buf.count {
                break   // wait for more (possible half packet at tail)
            }
            // Second magic byte must be 0x43, else this 0x54 is just an ACK byte.
            if buf[i + 1] != Self.magic1 {
                onAck?()
                i += 1
                continue
            }

            let count = Int(buf[i + 2])
            if count > Self.maxContacts {
                // Illegal count → not a real 'TC' start; treat 0x54 as an ACK.
                onAck?()
                i += 1
                continue
            }

            let packetLen = 3 + count * 6
            if i + packetLen > buf.count {
                break   // full packet not arrived yet
            }

            var contacts = [Contact]()
            contacts.reserveCapacity(count)
            var p = i + 3
            for _ in 0..<count {
                let id = buf[p]
                let x = UInt16(buf[p + 1]) | (UInt16(buf[p + 2]) << 8)   // LE
                let y = UInt16(buf[p + 3]) | (UInt16(buf[p + 4]) << 8)   // LE
                let tip = buf[p + 5] != 0
                contacts.append(Contact(touchId: id, x: x, y: y, tipDown: tip))
                p += 6
            }
            onTouch?(contacts)
            i += packetLen
        }

        if i > 0 {
            buf.removeFirst(i)
        }
    }
}
