import Darwin
import Foundation

enum SystemActivityReader {
    static func networkByteCounters() -> NetworkByteCounters? {
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else { return nil }
        defer { freeifaddrs(firstInterface) }

        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var interface = firstInterface
        while true {
            let value = interface.pointee
            if let address = value.ifa_addr,
               Int32(address.pointee.sa_family) == AF_LINK,
               let name = value.ifa_name.map({ String(cString: $0) }),
               name.hasPrefix("en"),
               value.ifa_flags & UInt32(IFF_UP) != 0,
               let rawData = value.ifa_data {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                receivedBytes &+= UInt64(data.ifi_ibytes)
                sentBytes &+= UInt64(data.ifi_obytes)
            }

            guard let next = value.ifa_next else { break }
            interface = next
        }
        return NetworkByteCounters(receivedBytes: receivedBytes, sentBytes: sentBytes)
    }

    static func externalVolumes() -> [ExternalVolumeSnapshot] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsLocalKey,
            .volumeIsInternalKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true,
                  values.volumeIsInternal == false,
                  let totalBytes = values.volumeTotalCapacity,
                  totalBytes > 0 else { return nil }
            let importantAvailable = values.volumeAvailableCapacityForImportantUsage
            let availableBytes = max(0, importantAvailable ?? Int64(values.volumeAvailableCapacity ?? 0))
            return ExternalVolumeSnapshot(
                id: values.volumeUUIDString ?? url.path,
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(totalBytes),
                availableBytes: min(Int64(totalBytes), availableBytes)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
