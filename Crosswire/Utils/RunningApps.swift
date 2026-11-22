//
//  RunningApps.swift
//  Crosswire
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
import CrosswireKit

/// Shared, observable liveness state for the bottles currently shown in the
/// UI. The button that launches an app becomes a red Stop button while any
/// process (including a launcher's detached children) is still running in its
/// bottle.
@MainActor
final class RunningApps: ObservableObject {
    static let shared = RunningApps()

    @Published private(set) var running: Set<URL> = []

    private var watched: Set<URL> = []
    private var timer: Timer?

    /// Watch `url` and refresh immediately. Cheap to call repeatedly.
    func watch(_ url: URL) {
        let url = url.standardizedFileURL
        guard watched.insert(url).inserted else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        Task { await refresh() }
    }

    func isRunning(_ bottle: Bottle) -> Bool {
        running.contains(bottle.url.standardizedFileURL)
    }

    func refresh() async {
        running = Wine.runningBottleURLs(among: Array(watched))
    }

    /// Stop everything in this bottle and refresh the button promptly.
    func stop(_ bottle: Bottle) {
        try? Wine.killBottle(bottle: bottle)
        Task { @MainActor in
            // wineserver -k is issued synchronously, but it can take a moment
            // for the last process to disappear from `ps`.
            try? await Task.sleep(for: .milliseconds(800))
            await refresh()
        }
    }
}
