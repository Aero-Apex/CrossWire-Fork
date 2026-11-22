//
//  FileHandle+Extensions.swift
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

extension FileManager {
    /// Copy every DLL in `sourceDirectory` into `destinationDirectory`.
    /// DLLs whose names also exist in `skippingNamesIn` are left alone, and
    /// files already identical to the source are not rewritten (this runs on
    /// every launch).
    func replaceDLLs(
        in destinationDirectory: URL, withContentsIn sourceDirectory: URL, makeOriginalCopy: Bool = false,
        skippingNamesIn skipDirectory: URL? = nil
    ) throws {
        let enumerator = FileManager.default.enumerator(
            at: sourceDirectory, includingPropertiesForKeys: [.isRegularFileKey])

        while let fileURL = enumerator?.nextObject() as? URL {
            // `continue`, not `return`: a stray non-DLL (.DS_Store, a
            // license file) used to abort the copy of every DLL after it.
            guard fileURL.pathExtension.lowercased() == "dll" else { continue }
            if let skipDirectory {
                let enginePath = skipDirectory.appending(path: fileURL.lastPathComponent).path(percentEncoded: false)
                if fileExists(atPath: enginePath) { continue }
            }
            let originalURL = destinationDirectory.appending(path: fileURL.lastPathComponent)
            if contentsEqual(atPath: originalURL.path(percentEncoded: false),
                             andPath: fileURL.path(percentEncoded: false)) {
                continue
            }
            if fileExists(atPath: originalURL.path(percentEncoded: false)) {
                try replaceFile(at: originalURL, with: fileURL, makeOriginalCopy: makeOriginalCopy)
            } else if fileExists(atPath: destinationDirectory.path(percentEncoded: false)) {
                // A prefix may lack the builtin placeholder; install anyway.
                try copyItem(at: fileURL, to: originalURL)
            }
        }
    }

    func replaceFile(at originalURL: URL, with replacementURL: URL, makeOriginalCopy: Bool = true) throws {
        if fileExists(atPath: originalURL.path(percentEncoded: false)) {
            if makeOriginalCopy {
                let copyURL = originalURL.appendingPathExtension("orig")

                if fileExists(atPath: copyURL.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: copyURL)
                }

                try FileManager.default.moveItem(at: originalURL, to: copyURL)
            } else {
                try FileManager.default.removeItem(at: originalURL)
            }

            try FileManager.default.copyItem(at: replacementURL, to: originalURL)
        }
    }
}
