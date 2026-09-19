//
//  APNsEnvironmentDetectorTests.swift
//  GrowGuardTests
//
//  Reading aps-environment out of a provisioning profile.
//

import Foundation
import Testing
@testable import GrowGuard

struct APNsEnvironmentDetectorTests {

    /// A provisioning profile is a CMS envelope around an XML plist. The
    /// binary bytes around the plist stand in for the signature.
    private func profile(apsEnvironment: String?) -> Data {
        let entitlement = apsEnvironment.map {
            "<key>aps-environment</key><string>\($0)</string>"
        } ?? ""
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Name</key><string>GrowGuard Development</string>
                <key>Entitlements</key>
                <dict>
                    \(entitlement)
                    <key>application-identifier</key><string>ABCDE12345.pro.veit.GrowGuard</string>
                </dict>
            </dict>
            </plist>
            """
        var data = Data([0x30, 0x82, 0x4E, 0x1F, 0x06, 0x09, 0x2A, 0x86])
        data.append(Data(plist.utf8))
        data.append(Data([0xA0, 0x82, 0x0B, 0x00, 0xFF, 0x00]))
        return data
    }

    @Test func developmentProfileMeansSandbox() {
        #expect(APNsEnvironmentDetector.environment(fromProfile: profile(apsEnvironment: "development")) == .sandbox)
    }

    @Test func productionProfileMeansProduction() {
        #expect(APNsEnvironmentDetector.environment(fromProfile: profile(apsEnvironment: "production")) == .production)
    }

    /// Unknown means "let the server detect it" — guessing would pin the
    /// token to a possibly wrong environment, which the server trusts.
    @Test func profileWithoutPushEntitlementIsUnknown() {
        #expect(APNsEnvironmentDetector.environment(fromProfile: profile(apsEnvironment: nil)) == nil)
    }

    @Test func unexpectedEntitlementValueIsUnknown() {
        #expect(APNsEnvironmentDetector.environment(fromProfile: profile(apsEnvironment: "staging")) == nil)
    }

    @Test func garbageIsUnknown() {
        #expect(APNsEnvironmentDetector.environment(fromProfile: Data([0x00, 0x01, 0x02, 0xFF])) == nil)
    }

    @Test func truncatedPlistIsUnknown() {
        let data = profile(apsEnvironment: "development")
        #expect(APNsEnvironmentDetector.environment(fromProfile: data.prefix(data.count / 2)) == nil)
    }

    @Test func rawValuesMatchServerAPI() {
        #expect(APNsEnvironment.sandbox.rawValue == "sandbox")
        #expect(APNsEnvironment.production.rawValue == "production")
    }
}
