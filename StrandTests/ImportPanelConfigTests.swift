#if os(macOS)
import XCTest
import UniformTypeIdentifiers
@testable import Strand

/// The macOS import panel is configured from `ImportPanelConfig.make(for:)` instead of SwiftUI's
/// `.fileImporter`, whose mixed `[.zip, .folder]` list greyed out the WHOOP export (the .zip AND its
/// unzipped folder). These tests pin the file/folder rules per target without presenting a panel.
final class ImportPanelConfigTests: XCTestCase {
    private let allTargets: [ImportTarget] = [
        .whoop, .appleHealth, .xiaomi, .nutrition, .lifting, .activityFile, .wearable
    ]

    /// True when a file of `fileType` would be selectable under `config.types`.
    private func accepts(_ config: (types: [UTType], files: Bool, dirs: Bool), _ fileType: UTType) -> Bool {
        config.files && config.types.contains { fileType.conforms(to: $0) }
    }

    private var zipType: UTType { UTType(filenameExtension: "zip")! }

    func testWhoopAcceptsZipFilesAndFolders() {
        let c = ImportPanelConfig.make(for: .whoop)
        XCTAssertTrue(c.files)
        XCTAssertTrue(c.dirs)
        XCTAssertTrue(accepts(c, zipType), "public.zip-archive must be selectable")
        XCTAssertEqual(zipType.identifier, "public.zip-archive")
    }

    func testFolderIsExpressedAsDirectoryModeNotAsFileType() {
        // `.folder` inside the panel's file-type list is what flips macOS into directory-only mode.
        for target in allTargets {
            let c = ImportPanelConfig.make(for: target)
            XCTAssertFalse(c.types.contains { $0.conforms(to: .folder) }, "\(target) leaks a folder type")
            XCTAssertTrue(c.files, "\(target) must allow choosing files")
        }
    }

    func testAppleHealthAcceptsXmlZipAndFolders() {
        let c = ImportPanelConfig.make(for: .appleHealth)
        XCTAssertTrue(c.dirs)
        XCTAssertTrue(accepts(c, zipType))
        XCTAssertTrue(accepts(c, .xml))
        XCTAssertTrue(accepts(c, UTType(filenameExtension: "xml")!))
    }

    func testXiaomiAcceptsZipDbAndFolders() {
        let c = ImportPanelConfig.make(for: .xiaomi)
        XCTAssertTrue(c.dirs)
        XCTAssertTrue(accepts(c, zipType))
        XCTAssertTrue(accepts(c, UTType(filenameExtension: "db") ?? .data))
    }

    func testWearableAcceptsJsonZipAndFolders() {
        let c = ImportPanelConfig.make(for: .wearable)
        XCTAssertTrue(c.dirs)
        XCTAssertTrue(accepts(c, zipType))
        XCTAssertTrue(accepts(c, .json))
    }

    func testCsvAndLogTargetsAreFilesOnly() {
        for target in [ImportTarget.nutrition, .lifting] {
            let c = ImportPanelConfig.make(for: target)
            XCTAssertFalse(c.dirs, "\(target) has no folder input")
            XCTAssertTrue(accepts(c, .commaSeparatedText))
            XCTAssertTrue(accepts(c, UTType(filenameExtension: "csv")!))
        }
        XCTAssertTrue(accepts(ImportPanelConfig.make(for: .lifting), .json))
    }

    func testActivityFileAcceptsGpxTcxFitAndIsFilesOnly() {
        let c = ImportPanelConfig.make(for: .activityFile)
        XCTAssertFalse(c.dirs)
        for ext in ["gpx", "tcx", "fit"] {
            let t = UTType(filenameExtension: ext) ?? .data
            XCTAssertTrue(accepts(c, t), ".\(ext) must be selectable")
        }
    }

    func testFoldersAreOnlyOfferedWhereTheImporterReadsThem() {
        let folderTargets: Set<String> = ["whoop", "appleHealth", "xiaomi", "wearable"]
        for target in allTargets {
            let c = ImportPanelConfig.make(for: target)
            XCTAssertEqual(c.dirs, folderTargets.contains("\(target)"), "\(target)")
        }
    }

    @MainActor
    func testPanelIsBuiltFromTheTargetAtCallTime() {
        let whoop = ImportPanel.makePanel(for: .whoop)
        XCTAssertTrue(whoop.canChooseFiles)
        XCTAssertTrue(whoop.canChooseDirectories)
        XCTAssertFalse(whoop.allowsMultipleSelection)
        XCTAssertTrue(whoop.allowedContentTypes.contains(zipType))

        // A panel for the next target must not inherit anything from the previous one.
        let csv = ImportPanel.makePanel(for: .nutrition)
        XCTAssertFalse(csv.canChooseDirectories)
        XCTAssertFalse(csv.allowedContentTypes.contains(zipType))
    }
}
#endif
