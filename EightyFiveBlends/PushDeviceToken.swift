//
//  PushDeviceToken.swift
//  EightyFiveBlends
//
//  An APNs device token in the single representation price-alerts-api accepts for iOS
//  (`register_device.device_token`): lowercase hexadecimal. The backend hashes the string it is
//  given (SHA-256) to de-duplicate a device's registrations, so the encoding must be identical on
//  every launch — upper- and lower-case hex of the same bytes would otherwise register as two
//  different devices. Pure Foundation, so it is directly unit-testable. See
//  EightyFiveBlendsTests/PushRegistrationTests.swift.
//
//  A device token identifies one app install on one device. It is never logged, and every
//  description/mirror path of this type is redacted so an accidental `print`, `dump`,
//  `String(describing:)` or string interpolation of a token — or of any value that contains one,
//  such as PushRegistrationState — can never put it in a log. The only way to read the hex is the
//  explicit `hexString` property, which is meant solely for the (future) registration request.
//

import Foundation

nonisolated struct PushDeviceToken: Equatable, Hashable, Sendable {
    /// Accepted size, in raw token bytes. These mirror price-alerts-api `register_device`, which
    /// rejects a `device_token` shorter than 16 or longer than 1024 characters (two hex characters
    /// per byte): a token outside this range could never be registered, so it is rejected here
    /// rather than sent. APNs documents tokens as variable-length, so nothing narrower than the
    /// backend's own bounds is assumed.
    static let minimumByteCount = 8
    static let maximumByteCount = 512

    /// Lowercase hexadecimal. Deterministic: the same bytes always produce the same string.
    let hexString: String
    let byteCount: Int

    /// `nil` for empty or out-of-range data (a registration callback that carried no usable
    /// token), never a partial or padded token.
    init?(deviceToken: Data) {
        guard (Self.minimumByteCount...Self.maximumByteCount).contains(deviceToken.count) else {
            return nil
        }
        hexString = Self.lowercaseHex(of: deviceToken)
        byteCount = deviceToken.count
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func lowercaseHex(of data: Data) -> String {
        var characters: [UInt8] = []
        characters.reserveCapacity(data.count * 2)
        for byte in data {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}

extension PushDeviceToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "PushDeviceToken(<redacted, \(byteCount) bytes>)"
    }

    var debugDescription: String {
        description
    }

    /// An empty mirror, so `dump(_:)`, Xcode's variable viewer text and any reflection-based
    /// logger show no children — in particular not `hexString`.
    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
