//
//  ShellIntegration.swift
//  CrosswireKit
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

import Foundation

/// Makes Windows programs behave like Mac apps: Dock icons on the macOS icon
/// grid instead of hard squares, a real icon for console/helper windows
/// instead of the generic "exec" document, the app's name in Cmd-Tab, and
/// games opening full screen in their own Space.
///
/// The work happens inside the engine processes, in two small dylibs shipped
/// at `Contents/Resources/ShellIntegration` (source: `ShellIntegration/`).
/// They are injected with `DYLD_INSERT_LIBRARIES`. The `Crosswire64` wrapper
/// is a `/bin/sh` script, and SIP strips `DYLD_*` variables when a protected
/// binary like `/bin/sh` is executed, so injected launches start the engine's
/// `wine` binary directly with the same `DYLD_FALLBACK_LIBRARY_PATH` the
/// wrapper would have set.
public enum ShellIntegration {
    /// Environment key that marks a launch for injection. Consumed (removed)
    /// by `spawnTarget` before the process starts.
    static let requestKey = "CROSSWIRE_SHELL_REQUEST"
    /// Per-app loader from `AppIdentityBundle`; consumed by `spawnTarget`.
    static let loaderKey = "CROSSWIRE_SHELL_LOADER"

    /// User default that turns the integration off entirely
    /// (`defaults write app.Crosswire.Crosswire shellIntegrationEnabled -bool NO`).
    public static let enabledDefaultsKey = "shellIntegrationEnabled"

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    static var folder: URL? {
        Bundle.main.resourceURL?.appending(path: "ShellIntegration")
    }

    static var loaderURL: URL? {
        guard let folder else { return nil }
        let loader = folder.appending(path: "CrosswireShell.dylib")
        let uiStage = folder.appending(path: "CrosswireShellUI.dylib")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: loader.path(percentEncoded: false)),
              fileManager.fileExists(atPath: uiStage.path(percentEncoded: false)) else { return nil }
        return loader
    }

    public static var isAvailable: Bool { isEnabled && loaderURL != nil }

    /// Environment for a user-facing launch of `url` in `bottle`. Installers
    /// are named after their own file and never get a full-screen Space.
    @MainActor
    static func environment(for url: URL, bottle: Bottle, isInstaller: Bool = false) -> [String: String] {
        guard isAvailable else { return [:] }
        var env: [String: String] = [requestKey: "1"]

        let exeName = url.lastPathComponent
        let isPrimary = bottle.settings.primaryProgramURL?.standardizedFileURL == url.standardizedFileURL
        var appName = url.deletingPathExtension().lastPathComponent
        if !isInstaller, isPrimary || bottle.programs.count <= 1 {
            let name = bottle.settings.appDisplayName ?? bottle.settings.name
            if !name.isEmpty {
                env["CROSSWIRE_APP_NAME"] = name
                appName = name
            }
            env["CROSSWIRE_APP_EXE"] = exeName
        }
        let isGame = !isInstaller && GameDetector.isLikelyGame(at: url)
        if let loader = AppIdentityBundle.loader(name: appName, exe: url, bottle: bottle,
                                                 engineBin: CrosswireEngine.binFolder, isGame: isGame) {
            env[loaderKey] = loader.path(percentEncoded: false)
        }

        if let icon = Bundle.main.resourceURL?.appending(path: "AppIcon.icns"),
           FileManager.default.fileExists(atPath: icon.path(percentEncoded: false)) {
            env["CROSSWIRE_FALLBACK_ICON"] = icon.path(percentEncoded: false)
        }

        if !isInstaller, wantsOwnSpace(bottle: bottle, isGame: isGame) {
            env["CROSSWIRE_OWN_SPACE"] = "1"
        }
        return env
    }

    @MainActor
    static func wantsOwnSpace(bottle: Bottle, isGame: Bool) -> Bool {
        switch bottle.settings.gameSpace {
        case .always: return true
        case .never: return false
        case .automatic: return isGame
        }
    }

    /// Rewrite a spawn of the `Crosswire64` wrapper into a direct, injected
    /// `wine` spawn when the launch asked for shell integration. Any other
    /// spawn is returned unchanged (minus the request marker).
    static func spawnTarget(
        executableURL: URL, environment: [String: String], wrapperURL: URL
    ) -> (executableURL: URL, environment: [String: String]) {
        var env = environment
        let identityLoader = env.removeValue(forKey: loaderKey)
        guard env.removeValue(forKey: requestKey) != nil,
              executableURL.standardizedFileURL == wrapperURL.standardizedFileURL,
              let loader = loaderURL else {
            return (executableURL, env)
        }

        let binFolder = wrapperURL.deletingLastPathComponent()
        var wine = binFolder.appending(path: "wine")
        // Run from the app's own bundle when one was prepared (Dock name).
        if let identityLoader, FileManager.default.isExecutableFile(atPath: identityLoader) {
            wine = URL(fileURLWithPath: identityLoader)
        }
        guard FileManager.default.isExecutableFile(atPath: wine.path(percentEncoded: false)) else {
            return (executableURL, env)
        }

        // Same library search path the wrapper sets (see generate-wrappers.sh).
        let engineLib = binFolder.deletingLastPathComponent().appending(path: "lib").path(percentEncoded: false)
        let fallback = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "/usr/local/lib:/usr/lib"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(engineLib):\(fallback)"

        let inserted = env["DYLD_INSERT_LIBRARIES"].map { "\(loader.path(percentEncoded: false)):\($0)" }
        env["DYLD_INSERT_LIBRARIES"] = inserted ?? loader.path(percentEncoded: false)
        return (wine, env)
    }
}

/// Whether to open a program in its own full-screen Space.
public enum GameSpaceMode: String, Codable, CaseIterable, Sendable {
    /// Games (detected from the executable and its folder) get their own Space.
    case automatic
    case always
    case never
}

/// Heuristic "is this a game?" check used by `GameSpaceMode.automatic`.
/// Looks for game-engine runtimes next to the executable and for graphics /
/// game-input imports. Conservative: a launcher or tool wrongly sent full
/// screen is more annoying than a game that opens in a window.
public enum GameDetector {
    private static let engineMarkers: Set<String> = [
        "unityplayer.dll", "gameassembly.dll", "mono-2.0-bdwgc.dll",   // Unity
        "steam_api.dll", "steam_api64.dll",                              // Steamworks
        "galaxy.dll", "galaxy64.dll", "eossdk-win64-shipping.dll",       // GOG / Epic
        "fmod.dll", "fmod64.dll", "fmodstudio.dll",                      // FMOD audio
        "bink2w32.dll", "bink2w64.dll", "binkw32.dll", "binkw64.dll",    // Bink video
        "physx3_x64.dll", "physx3_x86.dll", "phonon.dll"
    ]

    private static let graphicsImports: Set<String> = [
        "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll",
        "opengl32.dll", "vulkan-1.dll", "ddraw.dll", "d3d8.dll"
    ]

    private static let inputImports: Set<String> = [
        "xinput1_3.dll", "xinput1_4.dll", "xinput9_1_0.dll", "dinput8.dll", "dinput.dll"
    ]

    public static func isLikelyGame(at url: URL) -> Bool {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent

        let siblings = (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let lowered = Set(siblings.map { $0.lowercased() })
        if !lowered.isDisjoint(with: engineMarkers) { return true }
        // Unity's "<Exe>_Data" folder; Unreal's "-Shipping" binaries.
        if lowered.contains("\(stem.lowercased())_data") { return true }
        if stem.lowercased().hasSuffix("-shipping") { return true }

        guard let peFile = try? PEFile(url: url) else { return false }
        let imports = Set(peFile.importedDLLs.map { $0.lowercased() })
        // Direct3D / Vulkan / DirectDraw imports are a strong signal on their
        // own. OpenGL and plain DXGI are common in ordinary apps too, so they
        // only count together with game-controller input.
        if !imports.isDisjoint(with: gameGraphicsImports) { return true }
        return !imports.isDisjoint(with: graphicsImports) && !imports.isDisjoint(with: inputImports)
    }

    private static let gameGraphicsImports: Set<String> = [
        "d3d8.dll", "d3d9.dll", "d3d11.dll", "d3d12.dll", "vulkan-1.dll", "ddraw.dll"
    ]
}
