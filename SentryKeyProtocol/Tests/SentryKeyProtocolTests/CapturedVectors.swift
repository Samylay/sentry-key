// Test vectors captured from a real OpenSSH 10.2 login on 2026-11-23.
//
// How they were captured: a throwaway sshd on 127.0.0.1 with its own config
// and authorized_keys, and a stand-in agent that signed with a throwaway
// P-256 test key. sshd accepted the login, so the signature encoding below is
// one that a real server verified. See SentryKeyProtocol/README.md.
//
// The user name inside the signed data was replaced after capture with
// "tester" (same length). That keeps the structure exact, but the signature
// no longer verifies over the modified data. The private test key was not kept.

enum CapturedVectors {
    /// Uncompressed X9.63 public point of the test key (65 bytes).
    static let publicPoint = hex(
        "049b52aef9c7edac930a075c74c6b653818b181e4b23ce5068a11b1b2aa84f8ea49b3545a0847118d1599246bf05ad61" +
        "3c1f4843bc3c895bfaa0d0d93d923cde52"
    )

    /// The test key's ecdsa-sha2-nistp256 public key blob.
    static let keyBlob = hex(
        "0000001365636473612d736861322d6e69737470323536000000086e6973747032353600000041049b52aef9c7edac93" +
        "0a075c74c6b653818b181e4b23ce5068a11b1b2aa84f8ea49b3545a0847118d1599246bf05ad613c1f4843bc3c895bfa" +
        "a0d0d93d923cde52"
    )

    /// session-bind@openssh.com extension sent by ssh, with its uint32 length prefix.
    static let sessionBindMessage = hex(
        "000000d01b0000001873657373696f6e2d62696e64406f70656e7373682e636f6d000000330000000b7373682d656432" +
        "35353139000000208e2eddfb436291ac0a137eccc2360e84b12826d53e9fe4c2c11372616d1fbd4e000000202e9efdec" +
        "11d270bcab95a61d76b59c928ebb77502960cb8744ef5d407149efd7000000530000000b7373682d6564323535313900" +
        "000040adef5d26c1e360fce4a9fdfdfb33b2a76524ddbfcc03fe958ab019dc48783f1347ef6fd0f30718569dc8f064e1" +
        "d837912a7b5e3f00a268c5de0f7ed12c6ac90f00"
    )

    /// SSH_AGENTC_REQUEST_IDENTITIES sent by ssh, with its uint32 length prefix.
    static let requestIdentitiesMessage = hex(
        "000000010b"
    )

    /// The stand-in agent's answer listing the test key (comment "sentrykey-test"), which ssh accepted.
    static let identitiesAnswerMessage = hex(
        "000000830c00000001000000680000001365636473612d736861322d6e69737470323536000000086e69737470323536" +
        "00000041049b52aef9c7edac930a075c74c6b653818b181e4b23ce5068a11b1b2aa84f8ea49b3545a0847118d1599246" +
        "bf05ad613c1f4843bc3c895bfaa0d0d93d923cde520000000e73656e7472796b65792d74657374"
    )

    /// SSH_AGENTC_SIGN_REQUEST sent by ssh, with its uint32 length prefix. User name replaced with "tester".
    static let signRequestMessage = hex(
        "000001980d000000680000001365636473612d736861322d6e69737470323536000000086e6973747032353600000041" +
        "049b52aef9c7edac930a075c74c6b653818b181e4b23ce5068a11b1b2aa84f8ea49b3545a0847118d1599246bf05ad61" +
        "3c1f4843bc3c895bfaa0d0d93d923cde5200000123000000202e9efdec11d270bcab95a61d76b59c928ebb77502960cb" +
        "8744ef5d407149efd732000000067465737465720000000e7373682d636f6e6e656374696f6e000000237075626c6963" +
        "6b65792d686f7374626f756e642d763030406f70656e7373682e636f6d010000001365636473612d736861322d6e6973" +
        "7470323536000000680000001365636473612d736861322d6e69737470323536000000086e6973747032353600000041" +
        "049b52aef9c7edac930a075c74c6b653818b181e4b23ce5068a11b1b2aa84f8ea49b3545a0847118d1599246bf05ad61" +
        "3c1f4843bc3c895bfaa0d0d93d923cde52000000330000000b7373682d65643235353139000000208e2eddfb436291ac" +
        "0a137eccc2360e84b12826d53e9fe4c2c11372616d1fbd4e00000000"
    )

    /// r of the ECDSA signature the stand-in agent produced (32 bytes).
    static let signatureR = hex(
        "69732c3d86938a9ba3ca7f33cd5d184c5a01b3b28a09d1370d7586f95e915ee3"
    )

    /// s of the same signature (32 bytes).
    static let signatureS = hex(
        "4bde550c31cb97774d447077c4e3d4a3e4c7226f499601b0ac8742234d63b93f"
    )

    /// SSH_AGENT_SIGN_RESPONSE carrying that signature. sshd verified it.
    static let signResponseMessage = hex(
        "000000680e000000630000001365636473612d736861322d6e69737470323536000000480000002069732c3d86938a9b" +
        "a3ca7f33cd5d184c5a01b3b28a09d1370d7586f95e915ee3000000204bde550c31cb97774d447077c4e3d4a3e4c7226f" +
        "499601b0ac8742234d63b93f"
    )
}

/// Decodes a hex string. Test-only helper: traps on invalid input.
func hex(_ string: String) -> [UInt8] {
    precondition(string.count % 2 == 0, "odd hex length")
    var bytes: [UInt8] = []
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        bytes.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}
