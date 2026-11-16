// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// Imported MilkDrop presets, read from Application Support at launch.
///
/// They live in a user folder rather than in the app bundle: the preset packs
/// are community works with unclear licensing, so they are something the user
/// brings, not something this project redistributes.
@MainActor
final class MilkdropLibrary: ObservableObject {
    @Published private(set) var presets: [MilkdropPreset] = []
    @Published private(set) var lastImportSummary: String?

    static let selectionKey = "visualizerMilkdropPreset"

    let folderURL: URL

    init() {
        folderURL = AppPaths.support
            .appendingPathComponent("milkdrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        reload()
    }

    var isEmpty: Bool { presets.isEmpty }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil
        )) ?? []
        presets = urls
            .filter { $0.pathExtension.lowercased() == "milk" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { MilkdropPreset(contentsOf: $0) }
    }

    /// Copies `.milk` files in, recursing into any folders chosen, then reloads.
    /// Files that carry no equations are skipped — their header alone is all
    /// defaults and would render as a motionless frame.
    func importPresets(from sources: [URL]) {
        var copied = 0
        var skipped = 0
        var partial: [MilkdropCompatibility.Feature: Int] = [:]

        func consider(_ url: URL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
            if isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil
                )) ?? []
                children.forEach(consider)
                return
            }
            guard url.pathExtension.lowercased() == "milk" else { return }
            guard MilkdropPreset(contentsOf: url) != nil else { skipped += 1; return }

            let destination = folderURL.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                copied += 1
                if let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) {
                    for feature in MilkdropCompatibility.unsupported(in: text) { partial[feature, default: 0] += 1 }
                }
            } catch {
                skipped += 1
            }
        }

        sources.forEach(consider)
        reload()
        lastImportSummary = MilkdropCompatibility.summary(copied: copied, skipped: skipped, partial: partial)
    }

    func clearImportSummary() { lastImportSummary = nil }

    func removeAll() {
        for url in (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension.lowercased() == "milk" {
            try? FileManager.default.removeItem(at: url)
        }
        reload()
    }
}

/// What an imported preset uses that this visualizer does not draw. Only the
/// motion (per-frame equations and header values) is reproduced; see
/// `MilkdropPreset`.
enum MilkdropCompatibility {
    enum Feature: String, CaseIterable, Hashable {
        case waves = "custom waves"
        case shapes = "custom shapes"
        case perPixel = "per-pixel warp"
        case shaders = "MilkDrop 2 shaders"
    }

    static func unsupported(in text: String) -> Set<Feature> {
        var found = Set<Feature>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let value = line.split(separator: "=", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.hasPrefix("wavecode_"), line.contains("_enabled="), value != "0" { found.insert(.waves) }
            else if line.hasPrefix("shapecode_"), line.contains("_enabled="), value != "0" { found.insert(.shapes) }
            else if line.hasPrefix("per_pixel_") { found.insert(.perPixel) }
            else if line.hasPrefix("warp_1=") || line.hasPrefix("comp_1=") { found.insert(.shaders) }
        }
        return found
    }

    static func summary(copied: Int, skipped: Int, partial: [Feature: Int]) -> String {
        var lines = ["Imported \(copied) preset\(copied == 1 ? "" : "s")."]
        if skipped > 0 {
            lines.append("\(skipped) skipped: no motion equations, or the file could not be copied.")
        }
        let parts = Feature.allCases.compactMap { f in partial[f].map { "\(f.rawValue) (\($0))" } }
        if !parts.isEmpty {
            lines.append("Presets play their motion only. Not drawn: " + parts.joined(separator: ", ") + ", so these look simpler than in MilkDrop.")
        }
        return lines.joined(separator: "\n\n")
    }
}
