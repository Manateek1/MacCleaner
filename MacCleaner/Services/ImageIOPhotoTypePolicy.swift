import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageIOPhotoTypePolicy {
    /// Image formats that should stay out of a photo comparison. DICOM may
    /// contain sensitive medical images, while texture and icon containers are
    /// not useful photo candidates. HEIC and MPO sequence containers need
    /// frame-aware matching before they can be treated as one picture.
    static let excludedTypeIdentifiers: Set<String> = [
        "org.nema.dicom",
        "org.khronos.astc",
        "org.khronos.ktx",
        "public.pvr",
        "com.microsoft.dds",
        "com.apple.icns",
        "com.microsoft.ico",
        "public.heics",
        "public.mpo-image"
    ]

    /// Use the image types ImageIO actually registers on this Mac. This also
    /// picks up readable formats beyond the common photo and camera RAW list,
    /// while avoiding formats that are not useful or safe to treat as photos.
    static let supportedExtensions: Set<String> = {
        guard let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] else { return [] }
        var extensions = Set<String>()
        for identifier in identifiers {
            guard !excludedTypeIdentifiers.contains(identifier),
                  let type = UTType(identifier), type.conforms(to: .image),
                  let filenameExtensions = type.tags[.filenameExtension] else { continue }
            for filenameExtension in filenameExtensions {
                let normalized = filenameExtension.lowercased()
                extensions.insert(normalized)
            }
        }
        return extensions
    }()
}
