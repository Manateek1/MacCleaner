import AppKit
import ImageIO
import QuickLookUI
import SwiftUI

struct SimilarPhotosView: View {
    @ObservedObject var model: ScanViewModel
    @State private var source: SimilarPhotoSource = .onThisMac

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Photo source")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MacCleanerTheme.secondaryText)
                Picker("Photo source", selection: $source) {
                    Text("On This Mac").tag(SimilarPhotoSource.onThisMac)
                    Text("Photos Library").tag(SimilarPhotoSource.library)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)

            Divider()

            Group {
                switch source {
                case .onThisMac:
                    LocalSimilarPhotosPane(model: model)
                case .library:
                    PhotosLibrarySimilarPhotosView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private enum SimilarPhotoSource: Hashable {
    case onThisMac
    case library
}

private struct LocalSimilarPhotosPane: View {
    @ObservedObject var model: ScanViewModel
    @State private var result: SimilarPhotoScanResult?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanning = false
    @State private var scanProgress = SimilarPhotoScanProgress(stage: "Finding photos", photosInspected: 0, filesHashed: 0)
    @State private var root: URL?
    @State private var scope: URL?
    @AppStorage(SimilarPhotosPreference.storageKey)
    private var distance = SimilarPhotosPreference.defaultValue
    @State private var selected = Set<String>()
    @State private var error: String?
    @State private var preview: PhotoPreview?
    @State private var confirm = false
    @State private var outcome: String?
    private var selectedPhotos: [SimilarPhoto] { result?.groups.flatMap(\.photos).filter { selected.contains($0.path) } ?? [] }
    private var selectsEntireGroup: Bool { result?.groups.contains { $0.photos.allSatisfy { selected.contains($0.path) } } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Similar Photos").font(.largeTitle.bold())
                    Text("Find pictures that look alike, then compare them before deciding what to keep.").foregroundStyle(.secondary)
                }
                Spacer()
                if scanning { Button("Cancel") { scanTask?.cancel() } }
                else {
                    Button("Scan This Mac") { scanDisk() }.buttonStyle(.borderedProminent).tint(MacCleanerTheme.accent)
                    Button("Choose Folder…") { chooseFolder() }
                }
            }
            HStack {
                Text("Match tolerance")
                Slider(value: $distance, in: SimilarPhotosPreference.allowedRange, step: 1)
                    .frame(width: 180)
                    .disabled(scanning)
                    .accessibilityLabel("Similar photo match tolerance")
                    .accessibilityValue(SimilarPhotosPreference.label(for: distance))
                Text(SimilarPhotosPreference.label(for: distance))
                Text("Change this before scanning.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text("Byte-identical copies are labeled separately from pictures that only look alike. Photos libraries and iCloud are not scanned here. No files are selected automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if scanning {
                ProgressView(progressLabel)
                Spacer()
            } else if let result {
                HStack {
                    Text("\(result.groups.count) \(result.groups.count == 1 ? "group" : "groups") · \(result.inspected) photos checked").font(.headline)
                    Spacer()
                    if !selected.isEmpty { Button("Clear selection") { selected.removeAll() } }
                    Button("Move \(selected.count) to Trash") { confirm = true }.disabled(selected.isEmpty || selectsEntireGroup)
                }
                if selectsEntireGroup { Text("Keep at least one photo in each group.").foregroundStyle(.orange).font(.caption) }
                if result.skipped > 0 || result.truncated || result.exactVerificationLimited {
                    Label("\(result.skipped) items could not be checked.\(result.truncated ? " The scan stopped at its photo limit, so results are partial." : "")\(result.exactVerificationLimited ? " Some byte-for-byte checks were skipped to keep the scan bounded." : "")", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if result.groups.isEmpty {
                    ContentUnavailableView("No similar photos found", systemImage: "photo.on.rectangle.angled", description: Text("Try a different folder or a less strict tolerance."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(result.groups) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(group.title) · \(group.photos.count) photos").font(.headline)
                                    Text(group.explanation).font(.caption).foregroundStyle(.secondary)
                                    ForEach(group.photos) { photo in
                                        HStack(spacing: 12) {
                                            Toggle("Select \(photo.fileName)", isOn: Binding(get: { selected.contains(photo.path) }, set: { if $0 { selected.insert(photo.path) } else { selected.remove(photo.path) } })).labelsHidden()
                                            PhotoThumbnail(url: photo.url)
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack { Text(photo.fileName).fontWeight(.medium).lineLimit(1); if group.suggestedKeep == photo.path { Text("Suggested to keep").font(.caption).foregroundStyle(.blue) } }
                                                Text("\(photo.width) × \(photo.height) · \(photo.identity.size.formattedByteCount) · Modified \(Date(timeIntervalSince1970: photo.identity.modifiedAt).formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                                                if let created = photo.createdAt { Text("Created \(created.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                                                Text(photo.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                            }
                                            Spacer()
                                            Button("Preview") { preview = PhotoPreview(url: photo.url) }
                                            Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
                                        }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Find similar photos", systemImage: "photo.on.rectangle.angled", description: Text("Scan accessible local files to compare photos and screenshots."))
            }
        }
        .padding(28)
        .alert("Similar Photos", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .alert("Move selected photos to Trash?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) { moveSelected() }
        } message: {
            Text("You selected \(selectedPhotos.count) photos:\n\(selectedPhotos.map(\.path).joined(separator: "\n"))\n\nByte-identical groups contain exact copies. Visual matches may show different moments. Review each location before moving anything. Items go to Trash, which is not emptied.")
        }
        .alert("Cleanup results", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) { Button("OK") { outcome = nil } } message: { Text(outcome ?? "") }
        .sheet(item: $preview) { item in PhotoQuickLook(url: item.url) }
        .onDisappear {
            root = nil
            scanTask?.cancel()
            if !scanning { scope?.stopAccessingSecurityScopedResource(); scope = nil }
        }
    }

    private func scanDisk() {
        guard let url = model.borrowDiskAccess() else { error = "Enable Mac Cleaner under Full Disk Access in System Settings, then try again."; return }
        start(root: url, access: url)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder of photos"
        panel.message = "Images are checked locally. No files are moved during the scan."
        panel.prompt = "Scan Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.startAccessingSecurityScopedResource() else { error = "macOS did not grant access to that folder."; return }
        start(root: url, access: url)
    }
    private func start(root: URL, access: URL) {
        scope?.stopAccessingSecurityScopedResource()
        scope = access
        self.root = root
        result = nil
        selected.removeAll()
        scanProgress = SimilarPhotoScanProgress(stage: "Finding photos", photosInspected: 0, filesHashed: 0)
        scanning = true
        let tolerance = SimilarPhotosPreference.normalizedTolerance(distance)
        scanTask = Task {
            let worker = Task.detached(priority: .utility) {
                try SimilarPhotoScanner().scan(root: root, maximumDistance: tolerance) { progress in
                    Task { @MainActor in
                        scanProgress = progress
                    }
                }
            }
            do {
                let scanned = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                result = scanned
                let exactGroups = scanned.groups.filter { $0.matchKind == .exactCopies }.count
                model.activity.record(title: "Similar Photos scan completed", files: scanned.inspected, bytes: 0, note: "\(exactGroups) byte-identical groups among \(scanned.groups.count) photo groups; \(scanned.skipped) items could not be checked.\(scanned.truncated || scanned.exactVerificationLimited ? " Partial results." : "")", kind: .scan)
            } catch is CancellationError { self.root = nil }
            catch { self.root = nil; self.error = error.localizedDescription }
            scanning = false
            if self.root == nil { scope?.stopAccessingSecurityScopedResource(); scope = nil }
        }
    }
    private func moveSelected() {
        guard let root, !selectedPhotos.isEmpty, !selectsEntireGroup else { return }
        guard let groups = result?.groups, SimilarPhotoSafety.hasUnchangedSurvivors(groups: groups, selected: selected, root: root) else { error = "A photo you chose to keep has changed or is no longer accessible. Scan again before moving anything."; return }
        let results = TrashService().moveToTrash(selectedPhotos.map(\.scanItem), allCandidates: [], inside: root)
        model.activity.record(title: "Similar photos reviewed", files: results.moved.count, bytes: results.bytesMoved, note: "Moved to Trash after confirmation; \(results.failures.count) could not be moved.", kind: .cleanup)
        let moved = Set(results.moved)
        if let previous = result {
            let groups = previous.groups.compactMap { group -> SimilarPhotoGroup? in
                let remaining = group.photos.filter { !moved.contains($0.path) }
                return remaining.count > 1 ? SimilarPhotoGroup(photos: remaining) : nil
            }
            result = SimilarPhotoScanResult(groups: groups, inspected: previous.inspected, skipped: previous.skipped, truncated: previous.truncated, exactVerificationLimited: previous.exactVerificationLimited)
        }
        selected.removeAll()
        outcome = "Moved \(results.moved.count) photos to Trash.\(results.failures.isEmpty ? "" : "\n\nCould not move:\n" + results.failures.map { "\($0.path): \($0.reason)" }.joined(separator: "\n"))"
    }

    private var progressLabel: String {
        var label = "\(scanProgress.stage) · \(scanProgress.photosInspected) photos inspected"
        if scanProgress.filesHashed > 0 { label += " · \(scanProgress.filesHashed) copies verified" }
        if scanProgress.bytesHashed > 0 { label += " · \(scanProgress.bytesHashed.formattedByteCount) read" }
        return label
    }
}

private struct PhotoPreview: Identifiable { let id = UUID(); let url: URL }
private struct PhotoQuickLook: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack { HStack { Text(url.lastPathComponent).font(.headline); Spacer(); Button("Done") { dismiss() } }.padding(); PhotoQuickLookView(url: url) }
            .frame(minWidth: 700, minHeight: 500)
    }
}
private struct PhotoQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.previewItem = url as NSURL; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
private struct PhotoThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "photo").foregroundStyle(.secondary) } }
            .frame(width: 70, height: 60)
            .task(id: url) {
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 140] as CFDictionary) else { return nil }
                    let representation = NSBitmapImageRep(cgImage: image)
                    return representation.representation(using: .png, properties: [:])
                }.value
                if let data { image = NSImage(data: data) }
            }
    }
}
