import Foundation
import XCTest
@testable import VexSign

/// Characterization tests for the App Store catalog's category and search heuristics.
///
/// `AppStoreView.matchesCategory` decides what a user sees in each tab from keyword sets that
/// nothing else covered: a keyword that stops matching empties a category silently, and one that
/// matches too widely fills it with the wrong apps. These assert the shipped behaviour, including
/// the parts that are broad on purpose -- `"tweaked"` matches any name containing `pro`, so an
/// unrelated app called Proton lands there as well. That is recorded deliberately, so widening or
/// narrowing the reach later is a decision rather than an accident nobody noticed.
///
/// The sort orders in `rebuildFilteredCatalog` are not covered here: they compare
/// `ASRepository.App` values, which are `Decodable` members of the AltSourceKit package and would
/// need JSON fixtures to construct. These predicates take strings for exactly that reason.
final class AppStoreCatalogFilterTests: XCTestCase {
    private func matches(
        _ category: String,
        appCategory: String? = nil,
        name: String = "",
        appDescription: String? = nil
    ) -> Bool {
        AppStoreView.matchesCategory(
            category,
            appCategory: appCategory,
            name: name,
            appDescription: appDescription
        )
    }

    private func searched(
        _ query: String,
        name: String = "",
        appDescription: String? = nil,
        sourceName: String = ""
    ) -> Bool {
        AppStoreView.matchesQuery(
            query,
            name: name,
            appDescription: appDescription,
            sourceName: sourceName
        )
    }

    func testTheAllCategoryMatchesEverything() {
        XCTAssertTrue(matches("all", appCategory: "Games", name: "Delta", appDescription: "An emulator"))
        XCTAssertTrue(matches("all"), "even an app with no metadata at all")
        XCTAssertTrue(matches("All", name: "Delta"), "the tab label is capitalized in the UI")
    }

    func testUtilitiesMatchesItsKeywords() {
        XCTAssertTrue(matches("utilities", appCategory: "Utilities"))
        XCTAssertTrue(matches("utilities", appCategory: "Developer Tools"))
        XCTAssertTrue(matches("utilities", name: "Toolbox"))
        XCTAssertTrue(matches("utilities", appDescription: "A file manager"))
        XCTAssertTrue(matches("utilities", appDescription: "Handy utilities"))
        XCTAssertFalse(
            matches("utilities", appCategory: "Entertainment", name: "Photos", appDescription: "Watch films"),
            "an app with no utility keyword must not appear in the tab"
        )
    }

    func testEmulatorsMatchesItsKeywords() {
        XCTAssertTrue(matches("emulators", appCategory: "Emulation"))
        // `emu` in the name is the only name-side keyword, so a well-known emulator whose name
        // does not contain it is only found through its category or description.
        XCTAssertFalse(matches("emulators", name: "Delta"), "Delta carries no emulator keyword in its name")
        XCTAssertTrue(matches("emulators", name: "Emu"))
        XCTAssertTrue(matches("emulators", name: "Delta", appDescription: "A Nintendo emulator"))
        XCTAssertTrue(matches("emulators", appDescription: "Play retro games"))
        XCTAssertTrue(matches("emulators", appDescription: "GameBoy titles"))
        XCTAssertTrue(matches("emulators", appDescription: "Dolphin builds"))
        XCTAssertTrue(matches("emulators", appDescription: "Runs on UTM"))
        XCTAssertFalse(matches("emulators", appCategory: "Social", name: "Chat", appDescription: "Talk to friends"))
    }

    func testTweakedMatchesItsKeywords() {
        XCTAssertTrue(matches("tweaked", name: "App++"))
        XCTAssertTrue(matches("tweaked", name: "Spotify Mod"))
        XCTAssertTrue(matches("tweaked", name: "Something Tweak"))
        XCTAssertTrue(matches("tweaked", appDescription: "A tweaked build"))
        XCTAssertTrue(matches("tweaked", appDescription: "All features unlocked"))
        XCTAssertFalse(matches("tweaked", appCategory: "Utilities", name: "Calculator", appDescription: "Adds numbers"))
    }

    func testTweakedAlsoCatchesAnyNameContainingPro() {
        // Documented over-match: the keyword is the substring `pro`, not a word, so unrelated
        // names qualify. Pinned so the breadth is visible rather than surprising later.
        XCTAssertTrue(matches("tweaked", name: "Proton Mail"))
        XCTAssertTrue(matches("tweaked", name: "Procreate"))
    }

    func testGamesMatchesItsKeywords() {
        XCTAssertTrue(matches("games", appCategory: "Games"))
        XCTAssertTrue(matches("games", appDescription: "Play now"))
        XCTAssertTrue(matches("games", appDescription: "A fun game"))
        XCTAssertTrue(matches("games", name: "GameCenter Helper"))
        XCTAssertFalse(matches("games", appCategory: "Utilities", name: "Files", appDescription: "Browse documents"))
    }

    func testJailbreakMatchesItsKeywords() {
        XCTAssertTrue(matches("jailbreak", appCategory: "Jailbreak"))
        XCTAssertTrue(matches("jailbreak", name: "TrollStore"))
        XCTAssertTrue(matches("jailbreak", appDescription: "A rootless jailbreak"))
        XCTAssertTrue(matches("jailbreak", appDescription: "Install from Sileo"))
        XCTAssertFalse(matches("jailbreak", appCategory: "Games", name: "Delta", appDescription: "Play retro games"))
    }

    func testAnUnlistedCategoryFallsBackToSubstringMatching() {
        XCTAssertTrue(matches("photo", appCategory: "Photography", name: "Viewer"))
        XCTAssertTrue(matches("photo", name: "Photo Editor"), "the name is matched too")
        XCTAssertFalse(matches("photo", appCategory: "Games", name: "Delta"))
    }

    func testMissingMetadataIsTreatedAsEmptyRatherThanFatal() {
        XCTAssertFalse(matches("utilities", appCategory: nil, name: "", appDescription: nil))
        XCTAssertFalse(matches("emulators", appCategory: nil, name: "", appDescription: nil))
        XCTAssertTrue(matches("all", appCategory: nil, name: "", appDescription: nil))
    }

    func testTheCategoryKeyIsMatchedCaseInsensitively() {
        XCTAssertTrue(matches("UTILITIES", appCategory: "util"))
        XCTAssertTrue(matches("Utilities", appCategory: "util"))
    }

    func testAnEmptyQueryMatchesEverything() {
        XCTAssertTrue(searched("", name: "Delta", appDescription: nil, sourceName: "AltStore"))
        XCTAssertTrue(searched(""), "so the search field stays optional instead of emptying the list")
    }

    func testAQueryMatchesNameDescriptionOrSource() {
        XCTAssertTrue(searched("delta", name: "Delta Emulator"))
        XCTAssertTrue(searched("DELTA", name: "Delta"), "matching is case-insensitive")
        XCTAssertTrue(searched("retro", appDescription: "Play retro games"))
        XCTAssertTrue(searched("altstore", sourceName: "AltStore"))
    }

    func testAQueryThatMatchesNothingIsRejected() {
        XCTAssertFalse(searched("zelda", name: "Delta", appDescription: "Play retro games", sourceName: "AltStore"))
    }

    func testAMissingDescriptionNeverMatchesAQuery() {
        XCTAssertFalse(searched("anything", name: "Delta", appDescription: nil, sourceName: "AltStore"))
    }
}
