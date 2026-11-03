import XCTest
@testable import MacCleaner

final class MyToolsFavoritesTests: XCTestCase {
    func testFavoritesRoundTripInStableOrder() {
        let favorites: Set<AppSection> = [.similarPhotos, .smartScan, .permissions, .downloads, .trash]

        let encoded = MyToolsFavorites.serialize(favorites)

        XCTAssertEqual(encoded, "downloads,permissions,similarPhotos,smartScan,trash")
        XCTAssertEqual(MyToolsFavorites.parse(encoded), favorites)
    }

    func testUnknownFavoriteIdentifiersAreIgnored() {
        XCTAssertEqual(
            MyToolsFavorites.parse("smartScan,removedFeature,similarPhotos"),
            [.smartScan, .similarPhotos]
        )
    }

    func testNavigationShortcutsAreUniqueAndCoverNumbersOneThroughNine() {
        let sections = AppSection.navigationShortcutSections
        let keys = sections.compactMap(\.navigationShortcutKey)

        XCTAssertEqual(sections.count, 9)
        XCTAssertEqual(keys, Array("123456789"))
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    @MainActor
    func testNavigationStartsAtOverviewAndCanChangeSections() {
        let navigation = AppNavigationModel()

        XCTAssertEqual(navigation.selectedSection, .overview)
        navigation.selectedSection = .smartScan
        XCTAssertEqual(navigation.selectedSection, .smartScan)
    }
}
