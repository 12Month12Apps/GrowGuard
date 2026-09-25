//
//  APNsEnvironmentDetector.swift
//  Vattna
//
//  Which APNs environment this build's device token belongs to.
//

import Foundation

/// The APNs environment of this build's device token, as reported to the
/// Vattna server. Raw values are the server API's wire format.
enum APNsEnvironment: String, Sendable {
    case sandbox
    case production
}

/// Works out which APNs environment this build registers with, so one server
/// can push to Xcode and TestFlight builds at the same time.
enum APNsEnvironmentDetector {
    /// `nil` when the environment cannot be determined — the server then
    /// detects it on its next push round.
    static let current: APNsEnvironment? = detect()

    private static func detect() -> APNsEnvironment? {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        // Xcode and ad-hoc builds embed their provisioning profile;
        // TestFlight and App Store builds do not.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return .production
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return environment(fromProfile: data)
        #endif
    }

    /// Reads `aps-environment` from a provisioning profile. The profile is a
    /// CMS-signed envelope around an XML plist; the plist is cut out by its
    /// delimiters — verifying the signature is not needed to read our own
    /// bundle.
    static func environment(fromProfile data: Data) -> APNsEnvironment? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound),
                  format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String
        else { return nil }

        switch value {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }
}
