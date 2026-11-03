import AppKit
import Photos
import SwiftUI

struct PhotosLibrarySimilarPhotosView: View {
    @ObservedObject var model: ScanViewModel
    @State private var authorization = PhotoLibraryAccess.currentAuthorization
    @State private var scanResult: PhotoLibraryScanResult?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanning = false
    @State private var progress = SimilarPhotoScanProgress(stage: "Ready", photosInspected: 0, filesHashed: 0)
    @State private var maximumDistance = 6.0
    @State private var selected = Set<String>()
    @State private var preview: PhotosLibraryPreview?
    @State private var confirmRemoval = false
    @State private var error: String?
    @State private var outcome: String?

    private var selectedCount: Int { selected.count }
    private var selectsEntireGroup: Bool {
        scanResult?.groups.contains { $0.photos.allSatisfy { selected.contains($0.id) } } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Photos Library").font(.largeTitle.bold())
                    Text("Find similar pictures in Photos, compare them, then choose what stays.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if scanning {
                    Button("Cancel") { scanTask?.cancel() }
                } else {
                    Button("Scan Photos Library", action: scanLibrary)
                        .buttonStyle(.borderedProminent)
                        .tint(MacCleanerTheme.accent)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(MacCleanerTheme.accent)
                Text("Photos access is requested only when you start a scan. Mac Cleaner checks locally available previews and never downloads images from iCloud. Removing selected photos changes your Photos library and may sync to other devices if iCloud Photos is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MacCleanerTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Text("Match tolerance")
                Slider(value: $maximumDistance, in: 0...12, step: 1)
                    .frame(width: 180)
                    .disabled(scanning)
                Text(maximumDistance < 4 ? "Strict" : maximumDistance < 9 ? "Balanced" : "More matches")
                    .foregroundStyle(.secondary)
                Spacer()
                if authorization == .limited {
                    Label("Only selected Photos items are available", systemImage: "photo.badge.arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if authorization == .denied || authorization == .restricted {
                Label("Allow Mac Cleaner in System Settings › Privacy & Security › Photos, then scan again.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }
                .buttonStyle(.link)
            }

            if scanning {
                ProgressView("\(progress.stage) · \(progress.photosInspected) photos checked")
                Spacer()
            } else if let scanResult {
                results(scanResult)
            } else {
                ContentUnavailableView(
                    "Scan your Photos library",
                    systemImage: "photo.stack",
                    description: Text("Mac Cleaner looks for visually similar pictures stored on this Mac. It won’t change anything during the scan.")
                )
            }
        }
        .padding(28)
        .alert("Photos Library", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .alert("Remove selected photos from Photos?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) { }
            Button("Remove Photos", role: .destructive) { removeSelected() }
        } message: {
            Text("You selected \(selectedCount) photos. They will be removed from your Photos library only after you confirm. Photos may sync this change to your other devices when iCloud Photos is enabled. Keep at least one photo in every group.")
        }
        .alert("Photos update", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK") { outcome = nil }
        } message: {
            Text(outcome ?? "")
        }
        .sheet(item: $preview) { item in
            PhotosLibraryPreviewView(assetIdentifier: item.id)
        }
        .onAppear { authorization = PhotoLibraryAccess.currentAuthorization }
        .onDisappear { scanTask?.cancel() }
    }

    @ViewBuilder
    private func results(_ result: PhotoLibraryScanResult) -> some View {
        HStack {
            Text("\(result.groups.count) \(result.groups.count == 1 ? "group" : "groups") · \(result.inspected) photos checked")
                .font(.headline)
            Spacer()
            if !selected.isEmpty { Button("Clear selection") { selected.removeAll() } }
            Button("Remove \(selected.count) from Photos") { confirmRemoval = true }
                .disabled(selected.isEmpty || selectsEntireGroup)
        }
        if selectsEntireGroup {
            Text("Keep at least one photo in each group.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if result.skipped > 0 || result.truncated {
            Label(skippedDescription(result), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if result.groups.isEmpty {
            ContentUnavailableView(
                "No similar photos found",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Try a different match tolerance or make more Photos items available on this Mac.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(result.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Visually similar photos · \(group.photos.count)")
                                .font(.headline)
                            Text("These pictures look alike, but they may show different moments. Preview them before choosing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(group.photos) { photo in
                                photoRow(photo, group: group)
                            }
                        }
                        .padding(14)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private func skippedDescription(_ result: PhotoLibraryScanResult) -> String {
        var details = "\(result.skipped) photos couldn’t be checked."
        if result.unavailableFromCloud > 0 {
            details += " \(result.unavailableFromCloud) weren’t stored on this Mac, so they were skipped without downloading them."
        }
        if result.truncated { details += " The scan stopped at its 10,000-photo limit; results are partial." }
        return details
    }

    private func photoRow(_ photo: PhotoLibraryPhoto, group: PhotoLibraryGroup) -> some View {
        HStack(spacing: 12) {
            Toggle("Select photo", isOn: Binding(
                get: { selected.contains(photo.id) },
                set: { isSelected in
                    if isSelected { selected.insert(photo.id) }
                    else { selected.remove(photo.id) }
                }
            ))
            .labelsHidden()

            PhotosLibraryThumbnail(assetIdentifier: photo.id)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Photo")
                        .fontWeight(.medium)
                    if group.suggestedKeep == photo.id {
                        Text("Suggested to keep")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                Text("\(photo.width) × \(photo.height)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let date = photo.creationDate {
                    Text("Created \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Preview") { preview = PhotosLibraryPreview(id: photo.id) }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func scanLibrary() {
        guard !scanning else { return }
        scanResult = nil
        selected.removeAll()
        error = nil
        scanning = true
        progress = SimilarPhotoScanProgress(stage: "Requesting Photos access", photosInspected: 0, filesHashed: 0)
        let tolerance = Int(maximumDistance)
        scanTask = Task {
            let permission = await PhotoLibraryAccess.requestAuthorization()
            authorization = permission
            guard !Task.isCancelled else { scanning = false; return }
            guard permission.canRead else {
                scanning = false
                error = permission == .denied || permission == .restricted
                    ? "Photos access is off. Open System Settings › Privacy & Security › Photos, allow Mac Cleaner, then try again."
                    : "Photos didn’t grant access. Try again from this screen."
                return
            }

            let worker = Task.detached(priority: .utility) {
                try PhotoLibraryScanner().scan(maximumDistance: tolerance) { update in
                    Task { @MainActor in progress = update }
                }
            }
            do {
                let scanned = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                scanResult = scanned
                model.activity.record(
                    title: "Photos Library scan completed",
                    files: scanned.inspected,
                    bytes: 0,
                    note: "\(scanned.groups.count) visual groups; \(scanned.skipped) photos could not be checked.",
                    kind: .scan
                )
            } catch is CancellationError {
                progress = SimilarPhotoScanProgress(stage: "Scan cancelled", photosInspected: progress.photosInspected, filesHashed: 0)
            } catch {
                self.error = error.localizedDescription
            }
            scanning = false
        }
    }

    private func removeSelected() {
        guard let previous = scanResult, !selected.isEmpty, !selectsEntireGroup else { return }
        let selectedForRemoval = selected
        Task {
            do {
                let removedCount = try await PhotoLibraryAccess.remove(selected: selectedForRemoval, reviewedGroups: previous.groups)
                let remainingGroups = previous.groups.compactMap { group -> PhotoLibraryGroup? in
                    let photos = group.photos.filter { !selectedForRemoval.contains($0.id) }
                    return photos.count > 1 ? PhotoLibraryGroup(photos: photos) : nil
                }
                scanResult = PhotoLibraryScanResult(
                    groups: remainingGroups,
                    inspected: previous.inspected,
                    skipped: previous.skipped,
                    unavailableFromCloud: previous.unavailableFromCloud,
                    truncated: previous.truncated
                )
                model.activity.record(
                    title: "Photos reviewed",
                    files: removedCount,
                    bytes: 0,
                    note: "Removed from Photos after confirmation.",
                    kind: .cleanup
                )
                selected.removeAll()
                outcome = "Removed \(removedCount) selected photos from your Photos library."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct PhotosLibraryPreview: Identifiable {
    let id: String
}

private struct PhotosLibraryThumbnail: View {
    let assetIdentifier: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 82, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: assetIdentifier) {
            image = await PhotoLibraryImageProvider.image(
                for: assetIdentifier,
                targetSize: CGSize(width: 256, height: 256)
            )
        }
    }
}

private struct PhotosLibraryPreviewView: View {
    let assetIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Photo preview").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "photo", description: Text("This photo may not be stored on this Mac."))
            }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 480)
        .task {
            image = await PhotoLibraryImageProvider.image(
                for: assetIdentifier,
                targetSize: CGSize(width: 1600, height: 1200)
            )
        }
    }
}
