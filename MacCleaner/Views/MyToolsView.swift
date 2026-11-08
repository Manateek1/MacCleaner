import AppKit
import SwiftUI

struct MyToolsView: View {
    let onOpenTool: (AppSection) -> Void

    @AppStorage("MacCleaner.favoriteToolSections") private var storedFavorites = "smartScan,largeFiles,similarPhotos"
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 270), spacing: 14)]

    private var favoriteSections: Set<AppSection> {
        MyToolsFavorites.parse(storedFavorites)
    }

    private var matchingTools: [MyTool] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.tools }
        return Self.tools.filter {
            $0.section.title.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchingFavorites: [MyTool] {
        matchingTools.filter { favoriteSections.contains($0.section) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("My Tools")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(MacCleanerTheme.primaryText)
                    Text("Search Mac Cleaner and pin the tools you use most.")
                        .font(.title3)
                        .foregroundStyle(MacCleanerTheme.secondaryText)
                }

                TextField("Search tools", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 440)

                if !matchingFavorites.isEmpty {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("FAVORITES")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            HStack(spacing: 9) {
                                ForEach(matchingFavorites) { tool in
                                    Button {
                                        onOpenTool(tool.section)
                                    } label: {
                                        Label(tool.section.title, systemImage: tool.section.symbol)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("ALL TOOLS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if matchingTools.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(minHeight: 180)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(matchingTools) { tool in
                                toolCard(tool)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func toolCard(_ tool: MyTool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onOpenTool(tool.section)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: tool.section.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MacCleanerTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(tool.section.title)
                            .font(.headline)
                            .foregroundStyle(MacCleanerTheme.primaryText)
                        Text(tool.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(tool.section.title). \(tool.summary)")

            Button {
                toggleFavorite(tool.section)
            } label: {
                Image(systemName: favoriteSections.contains(tool.section) ? "star.fill" : "star")
                    .foregroundStyle(favoriteSections.contains(tool.section) ? MacCleanerTheme.accent : MacCleanerTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .help(favoriteSections.contains(tool.section) ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(favoriteSections.contains(tool.section) ? "Remove \(tool.section.title) from Favorites" : "Add \(tool.section.title) to Favorites")
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .cleanerCard()
    }

    private func toggleFavorite(_ section: AppSection) {
        var updated = favoriteSections
        if updated.contains(section) {
            updated.remove(section)
        } else {
            updated.insert(section)
        }
        storedFavorites = MyToolsFavorites.serialize(updated)
    }

    private static let tools: [MyTool] = [
        MyTool(section: .overview, summary: "Check available storage and jump into common cleanup tasks."),
        MyTool(section: .smartScan, summary: "Scan accessible areas of your Mac for files worth reviewing."),
        MyTool(section: .largeFiles, summary: "Find large and older files, then preview them before deciding."),
        MyTool(section: .downloads, summary: "Scan your Mac, then show review findings from Downloads."),
        MyTool(section: .duplicates, summary: "Find byte-for-byte copies and keep at least one copy."),
        MyTool(section: .similarPhotos, summary: "Compare similar pictures from your Mac or Photos library."),
        MyTool(section: .junk, summary: "Review recognized caches, logs, and temporary files."),
        MyTool(section: .aiClutter, summary: "Review recognized temporary data from AI development tools."),
        MyTool(section: .localModels, summary: "See local model names, locations, and storage sizes."),
        MyTool(section: .privacyCleanup, summary: "Review local Safari, Chrome, and Firefox cache folders and browser privacy controls."),
        MyTool(section: .spaceLens, summary: "Explore folder sizes from your latest scan."),
        MyTool(section: .applications, summary: "Review installed apps and prepare a confirmed removal."),
        MyTool(section: .appUpdates, summary: "Check supported update feeds and open the app's own updater."),
        MyTool(section: .appSecurity, summary: "Verify installed app signatures, sealed files, and embedded code."),
        MyTool(section: .malwareScan, summary: "Run an optional ClamAV scan of local files and review alerts."),
        MyTool(section: .appLeftovers, summary: "Review exact app-data matches left in common locations."),
        MyTool(section: .startup, summary: "See readable login and background launch items."),
        MyTool(section: .deviceBackups, summary: "Review local iPhone and iPad backups by size and file-change date."),
        MyTool(section: .xcodeStorage, summary: "Review Xcode archives and connected-device support files without changing them."),
        MyTool(section: .diagnosticReports, summary: "Review older crash and diagnostic reports before moving selected reports to Trash."),
        MyTool(section: .screenCleaning, summary: "Cover your displays for a short, timed screen-cleaning break."),
        MyTool(section: .trash, summary: "Open Finder Trash to restore items or manage files already there."),
        MyTool(section: .performance, summary: "View current CPU, memory, battery, and storage readings."),
        MyTool(section: .maintenance, summary: "Review Mac health, safe maintenance shortcuts, and local Time Machine snapshots."),
        MyTool(section: .permissions, summary: "Check Full Disk Access and current Photos access."),
        MyTool(section: .activity, summary: "Review local scan and cleanup summaries."),
        MyTool(section: .settings, summary: "Adjust scan thresholds and review app behavior.")
    ]
}

private struct MyTool: Identifiable {
    let section: AppSection
    let summary: String
    var id: AppSection { section }
}

enum MyToolsFavorites {
    static func parse(_ value: String) -> Set<AppSection> {
        Set(value.split(separator: ",").compactMap { AppSection(rawValue: String($0)) })
    }

    static func serialize(_ sections: Set<AppSection>) -> String {
        sections.map(\.rawValue).sorted().joined(separator: ",")
    }
}

struct TrashReviewView: View {
    @State private var errorMessage: String?

    private var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Trash")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(MacCleanerTheme.primaryText)
            Text("Mac Cleaner moves files you approve to Trash so Finder can restore them. Finder manages the Trash itself; Mac Cleaner never empties it or permanently deletes files.")
                .font(.callout)
                .foregroundStyle(MacCleanerTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if !NSWorkspace.shared.open(trashURL) {
                    errorMessage = "Finder couldn't open Trash. Open Trash from the Dock and try again."
                } else {
                    errorMessage = nil
                }
            } label: {
                Label("Open Trash in Finder", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(MacCleanerTheme.accent)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
