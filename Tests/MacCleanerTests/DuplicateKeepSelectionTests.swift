import XCTest
@testable import MacCleaner

final class DuplicateKeepSelectionTests: XCTestCase {
    func testChoosingKeeperChecksEligibleCopiesAndPreservesOtherSelections() {
        let groupID = "duplicate-group"
        let first = item(path: "/scan/group/first.txt", inode: 1, groupID: groupID)
        let second = item(path: "/scan/group/second.txt", inode: 2, groupID: groupID)
        let unreadable = item(path: "/scan/group/unreadable.txt", inode: 3, groupID: groupID)
        let unrelatedPath = "/scan/other.txt"

        let result = DuplicateKeepSelection.selectingAlternatives(
            in: [first, second, unreadable],
            keepingPath: second.path,
            from: [second.path, unrelatedPath],
            eligiblePaths: [first.path, second.path]
        )

        XCTAssertEqual(result, [first.path, unrelatedPath])
    }

    func testChoosingCopyOutsideDuplicateGroupDoesNotChangeSelection() {
        let first = item(path: "/scan/group/first.txt", inode: 1, groupID: "duplicate-group")
        let existing = Set([first.path, "/scan/other.txt"])

        let result = DuplicateKeepSelection.selectingAlternatives(
            in: [first],
            keepingPath: "/scan/not-in-group.txt",
            from: existing,
            eligiblePaths: [first.path]
        )

        XCTAssertEqual(result, existing)
    }

    func testChoosingKeeperDoesNotSelectCopiesHiddenByTheReview() {
        let first = item(path: "/scan/group/first.txt", inode: 1, groupID: "group")
        let keeper = item(path: "/scan/group/keeper.txt", inode: 2, groupID: "group")
        let hidden = item(path: "/scan/group/hidden.txt", inode: 3, groupID: "group")
        let result = DuplicateKeepSelection.selectingAlternatives(
            in: [first, keeper, hidden], keepingPath: keeper.path,
            from: [hidden.path], eligiblePaths: [first.path, keeper.path, hidden.path],
            reviewedPaths: [first.path, keeper.path]
        )
        XCTAssertEqual(result, [first.path])
    }

    private func item(path: String, inode: UInt64, groupID: String) -> ScanItem {
        ScanItem(
            path: path,
            identity: FileIdentity(device: 1, inode: inode, size: 12, modifiedAt: 1_700_000_000, linkCount: 1),
            lastAccessedAt: nil,
            isCloudManaged: nil,
            categories: [.exactDuplicate],
            reasons: [],
            safetyNote: "Review carefully",
            confidence: 1,
            duplicateGroupID: groupID,
            duplicateGroupCount: 3,
            suggestedKeepPath: "/scan/group/first.txt",
            cacheReviewDetails: nil
        )
    }
}
