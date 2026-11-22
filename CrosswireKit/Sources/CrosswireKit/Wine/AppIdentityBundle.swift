//
//  AppIdentityBundle.swift
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

import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Gives each Windows app its own macOS app identity, so the Dock, Cmd-Tab,
/// Force Quit and Activity Monitor show "Among Us" instead of "wine", and the
/// app can be assigned to a desktop (Dock > Options > Assign To).
///
/// The Dock labels a process by the bundle its executable lives in, or by the
/// executable's file name when there is none. Every engine process runs the
/// loader `lib/wine/x86_64-unix/wine`, and the engine spawns child processes
/// with `realpath(<folder of ntdll.so>)/wine`. So the loader folder is cloned
/// (APFS copy-on-write: instant, no extra disk space; about 5 MB logical) into
/// `<App Name>.app/Contents/MacOS`, which makes the app and every process it
/// starts run from inside that bundle. Everything else is symlinked back to
/// the engine. Wine finds its other folders relative to the loader folder:
///
///     Contents/MacOS/                 clone of lib/wine/x86_64-unix (real files)
///     Contents/MacOS/x86_64-unix  ->  .   (unix libraries next to ntdll.so)
///     Contents/MacOS/x86_64-windows,
///     Contents/MacOS/i386-windows ->  engine lib/wine/<arch>-windows
///     <App>.app/bin, <App>.app/share -> engine bin, share  (MacOS/../../bin)
///
/// Bundles live in `Application Support/.../AppBundles/<bottle>/` and are
/// rebuilt when the engine or the app's name changes.
enum AppIdentityBundle {
    /// Bump to force existing bundles to be rebuilt after a layout change.
    private static let layoutVersion = 2

    static var root: URL { CrosswireEngine.applicationFolder.appending(path: "AppBundles") }

    /// The loader to launch `exe` with so it runs as `name`, creating or
    /// refreshing the bundle as needed. Nil if the engine layout is not the
    /// expected one; callers then launch the engine normally.
    @MainActor
    static func loader(name: String, exe: URL, bottle: Bottle, engineBin: URL, isGame: Bool) -> URL? {
        let engine = engineBin.deletingLastPathComponent()
        let unixFolder = engine.appending(path: "lib/wine/x86_64-unix")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: unixFolder.appending(path: "ntdll.so").path(percentEncoded: false)),
              fileManager.isExecutableFile(atPath: unixFolder.appending(path: "wine").path(percentEncoded: false))
        else { return nil }

        let folder = root.appending(path: bottle.url.lastPathComponent)
        let bundle = folder.appending(path: "\(sanitized(name)).app")
        let loader = bundle.appending(path: "Contents/MacOS/wine")
        let stampURL = bundle.appending(path: "Contents/Resources/crosswire-identity.txt")
        let stamp = stampText(name: name, exe: exe, unixFolder: unixFolder)

        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp,
           fileManager.isExecutableFile(atPath: loader.path(percentEncoded: false)) {
            return loader
        }

        do {
            let identity = Identity(name: name, exe: exe, bundleID: bundleIdentifier(bottle: bottle, name: name),
                                    isGame: isGame)
            try build(bundle: bundle, identity: identity, engine: engine)
            try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        } catch {
            try? fileManager.removeItem(at: bundle)
            return nil
        }
        LSRegisterURL(bundle as CFURL, true)
        return loader
    }

    private static func stampText(name: String, exe: URL, unixFolder: URL) -> String {
        let ntdll = unixFolder.appending(path: "ntdll.so")
        let attributes = try? FileManager.default.attributesOfItem(atPath: ntdll.path(percentEncoded: false))
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? Int) ?? 0
        return "\(layoutVersion)\n\(name)\n\(exe.path(percentEncoded: false))\n"
            + "\(unixFolder.path(percentEncoded: false))\n\(modified)\n\(size)\n"
    }

    private struct Identity {
        let name: String
        let exe: URL
        let bundleID: String
        let isGame: Bool
    }

    private static func build(bundle: URL, identity: Identity, engine: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: bundle)
        let contents = bundle.appending(path: "Contents")
        let resources = contents.appending(path: "Resources")
        let macOS = contents.appending(path: "MacOS")
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        // FileManager clones on APFS.
        try fileManager.copyItem(at: engine.appending(path: "lib/wine/x86_64-unix"), to: macOS)
        try fileManager.createSymbolicLink(atPath: macOS.appending(path: "x86_64-unix").path(percentEncoded: false),
                                           withDestinationPath: ".")
        for arch in ["x86_64-windows", "i386-windows"] {
            let target = engine.appending(path: "lib/wine/\(arch)")
            guard fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            try fileManager.createSymbolicLink(at: macOS.appending(path: arch), withDestinationURL: target)
        }
        for item in ["bin", "share"] {
            try fileManager.createSymbolicLink(at: bundle.appending(path: item),
                                               withDestinationURL: engine.appending(path: item))
        }

        let hasIcon = writeIcon(for: identity.exe, to: resources.appending(path: "AppIcon.icns"))
        let name = identity.name
        var info: [String: Any] = [
            "CFBundleExecutable": "wine",
            "CFBundleIdentifier": identity.bundleID,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            // The engine was always run unbundled, which AppKit treats as
            // Retina-capable; keep that behavior.
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticGraphicsSwitching": true,
            // Without this, full screen on a notched Mac stops above the
            // camera (e.g. 1512x949 instead of 1512x982). A borderless game
            // asks for the full display, so macOS and the game resize the
            // window back and forth on every frame (visible flicker, DXVK
            // rebuilds its swap chain thousands of times).
            "NSPrefersDisplaySafeAreaCompatibilityMode": "YES"
        ]
        if hasIcon { info["CFBundleIconFile"] = "AppIcon" }
        if identity.isGame { info["LSApplicationCategoryType"] = "public.app-category.games" }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    /// Stable per app, so "Assign To Desktop" and other per-app macOS
    /// settings survive relaunches and rebuilds.
    private static func bundleIdentifier(bottle: Bottle, name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        func component(_ text: String) -> String {
            let mapped = text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
            let joined = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return joined.isEmpty ? "app" : joined
        }
        return "app.Crosswire.program.\(component(bottle.url.lastPathComponent)).\(component(name))"
    }

    /// File-system-safe bundle name (the Dock shows CFBundleName, not this).
    static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "App" : String(cleaned.prefix(80))
    }

    // MARK: - Icon

    /// Writes the exe's icon as a Mac-style .icns (rounded body on the macOS
    /// icon grid). Returns false when the exe has no usable icon.
    private static func writeIcon(for exe: URL, to destination: URL) -> Bool {
        guard let source = (try? PEFile(url: exe))?.bestIcon() else { return false }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.icns.identifier as CFString,
                                                           10, nil) else { return false }
        for side in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let image = renderIcon(source, pixels: side * scale) else { continue }
                CGImageDestinationAddImage(output, image, [kCGImagePropertyDPIWidth: 72 * scale,
                                                           kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
            }
        }
        return CGImageDestinationFinalize(output)
    }

    private static func renderIcon(_ source: NSImage, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let canvas = CGFloat(pixels)
        let body = CGRect(x: canvas * 100 / 1024, y: canvas * 100 / 1024,
                          width: canvas * 824 / 1024, height: canvas * 824 / 1024)
        let path = squircle(in: body)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -canvas * 10 / 1024), blur: canvas * 22 / 1024,
                          color: CGColor(gray: 0, alpha: 0.3))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        var rect = body
        if let cgSource = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            context.draw(cgSource, in: body)
        }
        context.restoreGState()
        return context.makeImage()
    }

    /// Superellipse (n = 5), the continuous-corner shape of macOS app icons.
    private static func squircle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let exponent = 2.0 / 5.0
        let steps = 240
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let cosine = cos(angle), sine = sin(angle)
            let point = CGPoint(
                x: rect.midX + rect.width / 2 * CGFloat(copysign(pow(abs(cosine), exponent), cosine)),
                y: rect.midY + rect.height / 2 * CGFloat(copysign(pow(abs(sine), exponent), sine))
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
