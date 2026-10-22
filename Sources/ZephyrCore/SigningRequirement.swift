import Foundation
import Security

public enum SigningRequirement {
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        // TeamIdentifier is signing information, not part of the default
        // dictionary. Request it explicitly or even a signed app appears unsigned.
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
    public static func requirement(identifier: String) -> String? {
        guard let team = currentTeamIdentifier(), !team.isEmpty else { return nil }
        let value = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(value as CFString, [], &requirement) == errSecSuccess else { return nil }
        return value
    }
}
