import Foundation
import Security
import CryptoKit

/// Proves an artifact is ours: the release certificate whose SHA-256 is pinned here.
///
/// One self-signed RSA certificate (build/signing/SpeechCast.cer) signs the DMG and everything
/// nested inside the app. The pin is the leaf's DER digest, so a renewal or rename changes the
/// pin and nothing silently re-trusts. The certificate never enters a keychain the app reads;
/// validation compares digests, not chains.
enum BundleSignature {
    /// The pinned release-certificate digest. `Scripts/check-signing-config.sh` compares this
    /// literal against `Config/signing.conf` at build time; they must never diverge.
    static let pinnedCertificateSHA256 = "A0AA9BCD7AFBC13A3CF4B16CAC7B84A0632816143F9C9D217DF9757B8400FD62"

    /// The bundle id a release may carry; anything else is not this app, whatever it signs.
    static let expectedBundleIdentifier = "com.tinycast.app"

    /// A signed DMG is trusted when its seal is intact and its signing leaf is the pinned one.
    static func isTrustedImage(_ image: URL) -> Bool {
        trusted(image, validateOptions: [])
    }

    /// A staged app bundle is trusted when its seal covers every architecture and every nested
    /// Mach-O, and its signing leaf is the pinned one. `kSecCSCheckNestedCode` makes Security
    /// itself walk the bundle and validate each nested executable against the app's seal — but
    /// a sealed nested binary may still carry a *foreign, valid* signature of its own, so every
    /// nested Mach-O is additionally required to be signed by the pinned certificate.
    static func isTrusted(_ bundle: URL) -> Bool {
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard trusted(bundle, validateOptions: flags) else { return false }
        return nestedExecutables(of: bundle).allSatisfy { trusted($0, validateOptions: flags) }
    }

    private static func trusted(_ url: URL, validateOptions: SecCSFlags) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return false }
        // The seal first: a tampered artifact fails before its certificate is even read.
        guard SecStaticCodeCheckValidity(staticCode, validateOptions, nil) == errSecSuccess else {
            return false
        }
        // Then the signer: the digest of the leaf certificate, compared to the pin.
        guard let digest = leafDigest(of: staticCode) else { return false }
        return Self.hex(digest) == pinnedCertificateSHA256
    }

    /// Every Mach-O inside the bundle: the main executable, helpers and frameworks, found by
    /// the file magic rather than by path convention. Symlinks are skipped: a link out of the
    /// bundle is never re-signed, and following it would check the link's target instead.
    private static func nestedExecutables(of bundle: URL) -> [URL] {
        let fm = FileManager.default
        let root = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard let paths = try? fm.subpathsOfDirectory(atPath: root.path) else { return [] }
        var executables = [URL]()
        for relative in paths {
            let url = root.appendingPathComponent(relative)
            guard isMachO(at: url) else { continue }
            executables.append(url)
        }
        return executables
    }

    /// A Mach-O begins with a magic number; 32/64-bit, native and byte-swapped, fat and thin.
    private static func isMachO(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
            let magic = (try? handle.read(upToCount: 4)) ?? nil
        else { return false }
        try? handle.close()
        guard magic.count == 4 else { return false }
        let bytes = [UInt8](magic)
        let magics: Set<[UInt8]> = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF],
            [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
        ]
        return magics.contains(bytes)
    }

    /// `SecCodeCopySigningInformation` hands back the whole chain; the leaf is element zero.
    private static func leafDigest(of code: SecStaticCode) -> SHA256Digest? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
    }

    /// Uppercase hex, matching how the pin is written.
    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02X", $0) }.joined()
    }
}
