import AppKit
import Foundation
import Photos

struct PhotoLibraryScanner: Sendable {
    let maximumPhotos: Int

    init(maximumPhotos: Int = 10_000) {
        self.maximumPhotos = max(1, maximumPhotos)
    }

    func scan(
        maximumDistance: Int,
        progress: @escaping @Sendable (SimilarPhotoScanProgress) -> Void
    ) throws -> PhotoLibraryScanResult {
        guard PhotoLibraryAuthorizationState(PHPhotoLibrary.authorizationStatus(for: .readWrite)).canRead else {
            throw PhotoLibraryError.accessNotAllowed
        }

        let assets = PHAsset.fetchAssets(with: .image, options: nil)
        let count = min(assets.count, maximumPhotos)
        var inspected = 0
        var skipped = 0
        var unavailableFromCloud = 0
        var fingerprints: [VisualPhotoFingerprint] = []
        fingerprints.reserveCapacity(count)

        for index in 0..<count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            inspected += 1
            if inspected == 1 || inspected.isMultiple(of: 16) || inspected == count {
                progress(SimilarPhotoScanProgress(
                    stage: "Checking your Photos library",
                    photosInspected: inspected,
                    filesHashed: 0
                ))
            }

            let thumbnail = localThumbnail(for: asset)
            guard let image = thumbnail.image else {
                skipped += 1
                if thumbnail.unavailableFromCloud { unavailableFromCloud += 1 }
                continue
            }
            guard let fingerprint = VisualPhotoFingerprinting.make(
                image: image,
                identifier: asset.localIdentifier,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                createdAt: asset.creationDate
            ) else {
                skipped += 1
                continue
            }
            fingerprints.append(fingerprint)
        }

        try Task.checkCancellation()
        let matched = try VisualPhotoMatcher.groups(fingerprints, maximumDistance: maximumDistance)
        let modificationDates = Dictionary(uniqueKeysWithValues: (0..<count).map { index in
            let asset = assets.object(at: index)
            return (asset.localIdentifier, asset.modificationDate)
        })
        let groups = matched.map { fingerprints in
            PhotoLibraryGroup(photos: fingerprints.map { fingerprint in
                PhotoLibraryPhoto(fingerprint: fingerprint, modificationDate: modificationDates[fingerprint.identifier] ?? nil)
            })
        }
        return PhotoLibraryScanResult(
            groups: groups,
            inspected: inspected,
            skipped: skipped,
            unavailableFromCloud: unavailableFromCloud,
            truncated: assets.count > maximumPhotos
        )
    }

    private func localThumbnail(for asset: PHAsset) -> (image: CGImage?, unavailableFromCloud: Bool) {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        var imageResult: CGImage?
        var unavailableFromCloud = false
        let target = CGSize(width: 256, height: 256)
        _ = PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            guard info?[PHImageCancelledKey] as? Bool != true,
                  info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
            if info?[PHImageResultIsInCloudKey] as? Bool == true {
                unavailableFromCloud = true
                return
            }
            guard let image else { return }
            var proposedRect = CGRect(origin: .zero, size: image.size)
            imageResult = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        }
        return (imageResult, unavailableFromCloud)
    }
}

enum PhotoLibraryAccess {
    static var currentAuthorization: PhotoLibraryAuthorizationState {
        PhotoLibraryAuthorizationState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func requestAuthorization() async -> PhotoLibraryAuthorizationState {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
        return PhotoLibraryAuthorizationState(status)
    }

    static func remove(
        selected: Set<String>,
        reviewedGroups: [PhotoLibraryGroup]
    ) async throws -> Int {
        guard currentAuthorization.canRead else { throw PhotoLibraryError.accessNotAllowed }
        let reviewedIdentifiers = Set(reviewedGroups.flatMap { $0.photos.map(\.id) })
        guard selected.isSubset(of: reviewedIdentifiers) else { throw PhotoLibraryError.selectedPhotosChanged }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(reviewedIdentifiers), options: nil)
        let currentAssets = (0..<fetch.count).map { fetch.object(at: $0) }
        let currentIdentifiers = Set(currentAssets.map(\.localIdentifier))
        guard selected.isSubset(of: currentIdentifiers) else { throw PhotoLibraryError.selectedPhotosChanged }
        guard PhotoLibraryCleanupSafety.hasUnselectedSurvivors(
            groups: reviewedGroups,
            selected: selected,
            currentIdentifiers: currentIdentifiers
        ) else { throw PhotoLibraryError.noUnselectedSurvivor }

        let selectedAssets = currentAssets.filter { selected.contains($0.localIdentifier) }
        guard selectedAssets.allSatisfy({ $0.canPerform(.delete) }) else { throw PhotoLibraryError.selectedPhotoCannotBeDeleted }
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(selectedAssets as NSArray)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: selectedAssets.count)
                } else {
                    continuation.resume(throwing: PhotoLibraryError.deletionFailed(error?.localizedDescription ?? "Try again in Photos."))
                }
            }
        }
    }
}

enum PhotoLibraryImageProvider {
    static func image(for identifier: String, targetSize: CGSize) async -> NSImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard assets.count == 1 else { return nil }
        let asset = assets.object(at: 0)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            _ = PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                continuation.resume(returning: image)
            }
        }
    }
}
