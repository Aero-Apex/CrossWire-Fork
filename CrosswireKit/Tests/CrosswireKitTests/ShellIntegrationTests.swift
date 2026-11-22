//
//  ShellIntegrationTests.swift
//  CrosswireKitTests
//
//  This file is part of Crosswire.
//
//  Crosswire is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Crosswire is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Crosswire.
//  If not, see https://www.gnu.org/licenses/.
//

import XCTest
@testable import CrosswireKit

final class DllOverridesTests: XCTestCase {
    /// The regression: a BepInEx per-program override used to replace the
    /// bottle's DXVK overrides wholesale, so d3d11 fell back to builtin.
    func testPerProgramOverrideKeepsDXVK() {
        let merged = DllOverrides.merge("dxgi,d3d9,d3d10core,d3d11=n,b", "winhttp.dll=n,b")
        XCTAssertEqual(merged, "dxgi,d3d9,d3d10core,d3d11,winhttp.dll=n,b")
    }

    func testOverrideWinsPerDLL() {
        let merged = DllOverrides.merge("dxgi,d3d9,d3d10core,d3d11=n,b", "d3d9=b;xinput1_3=")
        let entries = Dictionary(uniqueKeysWithValues: DllOverrides.parse(merged).map {
            (DllOverrides.key($0.name), $0.mode)
        })
        XCTAssertEqual(entries["d3d9"], "b")
        XCTAssertEqual(entries["d3d11"], "n,b")
        XCTAssertEqual(entries["xinput1_3"], "")
    }

    func testDuplicateNamesAreCaseAndExtensionInsensitive() {
        let merged = DllOverrides.merge("winhttp=n,b", "WinHTTP.dll=b")
        XCTAssertEqual(merged, "WinHTTP.dll=b")
    }

    func testAlreadyMergedValueIsStable() {
        let value = "dxgi,d3d9,d3d10core,d3d11,winhttp=n,b"
        XCTAssertEqual(DllOverrides.merge("dxgi,d3d9,d3d10core,d3d11=n,b", value), value)
    }
}

final class ShellIntegrationSpawnTests: XCTestCase {
    private let wrapper = URL(fileURLWithPath: "/tmp/engine/bin/Crosswire64")

    func testUnrequestedSpawnIsUnchanged() {
        let env = ["WINEPREFIX": "/tmp/prefix"]
        let target = ShellIntegration.spawnTarget(executableURL: wrapper, environment: env, wrapperURL: wrapper)
        XCTAssertEqual(target.executableURL, wrapper)
        XCTAssertEqual(target.environment, env)
    }

    func testRequestMarkerNeverReachesTheProcess() {
        // No dylibs in the test bundle, so the spawn must fall back to the
        // wrapper, and the marker must still be stripped.
        let env = [ShellIntegration.requestKey: "1", "WINEPREFIX": "/tmp/prefix"]
        let target = ShellIntegration.spawnTarget(executableURL: wrapper, environment: env, wrapperURL: wrapper)
        XCTAssertEqual(target.executableURL, wrapper)
        XCTAssertNil(target.environment[ShellIntegration.requestKey])
        XCTAssertNil(target.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(target.environment["WINEPREFIX"], "/tmp/prefix")
    }
}

final class GameDetectorTests: XCTestCase {
    func testUnityFolderIsAGame() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exe = folder.appending(path: "Among Us.exe")
        FileManager.default.createFile(atPath: exe.path, contents: Data())
        FileManager.default.createFile(atPath: folder.appending(path: "UnityPlayer.dll").path, contents: Data())
        XCTAssertTrue(GameDetector.isLikelyGame(at: exe))
    }

    func testPlainFolderWithoutPEIsNotAGame() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let exe = folder.appending(path: "Setup.exe")
        FileManager.default.createFile(atPath: exe.path, contents: Data())
        XCTAssertFalse(GameDetector.isLikelyGame(at: exe))
    }
}
