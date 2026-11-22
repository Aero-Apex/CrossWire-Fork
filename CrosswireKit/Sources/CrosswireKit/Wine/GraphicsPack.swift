//
//  GraphicsPack.swift
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

/// Direct3D 10/11 support that the engine's DXVK folder lacks.
///
/// The engine ships DXVK's `d3d9.dll` only, so with graphics mode on,
/// Direct3D 11 games still loaded Wine's built-in d3d11, which cannot create a
/// device on Apple GPUs: Unity games fail with "Failed to initialize graphics
/// ... InitializeEngineGraphics failed". The pack adds DXVK 1.10.3 (async,
/// macOS build; zlib license) `d3d11` / `dxgi` / `d3d10core` for both
/// architectures, plus MoltenVK 1.4.2 (Apache-2.0): the engine's MoltenVK
/// 1.4.0 rejects DXVK's external-memory device creation.
///
/// Layout, at `Contents/Resources/GraphicsPack`:
///   x64/*.dll, x32/*.dll, MoltenVK/libMoltenVK.dylib, MoltenVK/MoltenVK_icd.json
/// The ICD manifest uses a relative `library_path`, resolved by the Vulkan
/// loader against the manifest's own location.
public enum GraphicsPack {
    static var folder: URL? {
        guard let url = Bundle.main.resourceURL?.appending(path: "GraphicsPack"),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    static var moltenVKICD: URL? {
        guard let icd = folder?.appending(path: "MoltenVK/MoltenVK_icd.json"),
              FileManager.default.fileExists(atPath: icd.path(percentEncoded: false)) else { return nil }
        return icd
    }
}

/// `WINEDLLOVERRIDES` parsing and merging.
///
/// The variable is a `;`-separated list of `dll[,dll...]=mode` groups. A plain
/// dictionary merge of environments lets one layer's value replace another's
/// wholesale. That is how a per-program `winhttp.dll=n,b` (needed by BepInEx
/// mods) silently dropped the bottle's DXVK `d3d11=n,b` and brought back the
/// "InitializeEngineGraphics failed" error. Merging per DLL keeps both.
enum DllOverrides {
    /// Ordered (name, mode) pairs. Names are kept as written; `key(_:)`
    /// identifies duplicates ("WinHTTP.dll" and "winhttp" are the same DLL).
    static func parse(_ value: String) -> [(name: String, mode: String)] {
        var result: [(name: String, mode: String)] = []
        for group in value.split(separator: ";") {
            let parts = group.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let names = parts[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let mode = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            for name in names where !name.isEmpty {
                result.append((name, mode))
            }
        }
        return result
    }

    static func key(_ name: String) -> String {
        var lowered = name.lowercased()
        if lowered.hasSuffix(".dll") { lowered.removeLast(4) }
        return lowered
    }

    /// `base` with `override`'s entries applied on top, per DLL.
    static func merge(_ base: String, _ override: String) -> String {
        var order: [String] = []
        var entries: [String: (name: String, mode: String)] = [:]
        for entry in parse(base) + parse(override) {
            let id = key(entry.name)
            if entries[id] == nil { order.append(id) }
            entries[id] = entry
        }

        // Re-group consecutive DLLs that share a mode: "a,b=n,b;c=b".
        var groups: [(names: [String], mode: String)] = []
        for id in order {
            guard let entry = entries[id] else { continue }
            if let last = groups.last, last.mode == entry.mode {
                groups[groups.count - 1].names.append(entry.name)
            } else {
                groups.append(([entry.name], entry.mode))
            }
        }
        return groups.map { "\($0.names.joined(separator: ","))=\($0.mode)" }.joined(separator: ";")
    }
}
