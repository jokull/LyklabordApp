import XCTest

@testable import LemmaCore

/// Tests run against the REAL shipped artifact (data/is/paradigms.bin,
/// 22.8MB mmap — resident cost is only the touched pages), located via the
/// repo root; skipped gracefully when the checkout has no data directory
/// (the artifact is a build product, not a test resource — bundling a 24MB
/// copy into the package would defeat the point).
final class ParadigmsReaderTests: XCTestCase {

    static var reader: ParadigmsReader?

    override class func setUp() {
        super.setUp()
        // Packages/LemmaCore/Tests/LemmaCoreTests/ParadigmsReaderTests.swift
        // → 5 parents up = repo root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        url = url.appendingPathComponent("data/is/paradigms.bin")
        reader = try? ParadigmsReader(contentsOf: url)
    }

    func requireReader() throws -> ParadigmsReader {
        guard let reader = Self.reader else {
            throw XCTSkip("data/is/paradigms.bin not present in this checkout")
        }
        return reader
    }

    // MARK: - Header

    func testHeaderMetadata() throws {
        let reader = try requireReader()
        XCTAssertEqual(reader.version, 1)
        XCTAssertEqual(reader.minLemmaFreq, 10)
        XCTAssertGreaterThan(reader.groupCount, 30_000)
        XCTAssertGreaterThan(reader.entryCount, 700_000)
        XCTAssertGreaterThan(reader.formCount, 300_000)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ParadigmsReader(data: Data(repeating: 0xAB, count: 64)))
        XCTAssertThrowsError(try ParadigmsReader(data: Data()))
    }

    // MARK: - Worked examples from data/is/PARADIGMS_FORMAT.md

    func testHesturHasSixteenForms() throws {
        let reader = try requireReader()
        let groups = reader.groups(ofLemma: "hestur")
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.lemma, "hestur")
        XCTAssertEqual(group.pos, .noun)
        XCTAssertEqual(group.genderCode, 0)  // kk
        XCTAssertEqual(group.forms.count, 16)

        // Every (form, bundle string) pair from the format doc's --verify
        // output must be present.
        let rendered = Set(group.forms.map { "\($0.form) \($0.bundle)" })
        for expected in [
            "hestur no:nf:et:ngr", "hest no:þf:et:ngr",
            "hesti no:þgf:et:ngr", "hests no:ef:et:ngr",
            "hestar no:nf:ft:ngr", "hesta no:þf:ft:ngr",
            "hestum no:þgf:ft:ngr", "hesta no:ef:ft:ngr",
            "hesturinn no:nf:et:gr", "hestinn no:þf:et:gr",
            "hestinum no:þgf:et:gr", "hestsins no:ef:et:gr",
            "hestarnir no:nf:ft:gr", "hestana no:þf:ft:gr",
            "hestunum no:þgf:ft:gr", "hestanna no:ef:ft:gr",
        ] {
            XCTAssertTrue(rendered.contains(expected), "missing \(expected)")
        }
    }

    func testGodurAdjectiveHasAll120Bundles() throws {
        let reader = try requireReader()
        let groups = reader.groups(ofLemma: "góður")
        let adjective = try XCTUnwrap(groups.first(where: { $0.pos == .adjective }))
        XCTAssertEqual(adjective.genderCode, 0xFF)  // gender is per-form for adjectives
        XCTAssertEqual(adjective.forms.count, 120)
        // All 120 distinct bundles present (4 case × 2 number × 3 gender ×
        // 5 valid degree/strength pairs).
        XCTAssertEqual(Set(adjective.forms.map(\.bundle)).count, 120)
    }

    func testHestinumAnalysis() throws {
        let reader = try requireReader()
        let analyses = reader.analyses(ofForm: "hestinum")
        XCTAssertEqual(analyses.count, 1)
        let analysis = try XCTUnwrap(analyses.first)
        XCTAssertEqual(analysis.lemma, "hestur")
        XCTAssertEqual(analysis.pos, .noun)
        XCTAssertEqual("\(analysis.bundle)", "no:þgf:et:gr")
        XCTAssertEqual(analysis.bundle.caseName, "þgf")
        XCTAssertFalse(analysis.bundle.isPlural)
        XCTAssertTrue(analysis.bundle.isDefinite)
    }

    func testSyncretismHestaHasTwoBundles() throws {
        let reader = try requireReader()
        // "hesta" is both þf:ft and ef:ft of hestur (syncretism noted in the
        // format doc's worked example).
        let analyses = reader.analyses(ofForm: "hesta")
            .filter { $0.lemma == "hestur" }
        XCTAssertEqual(Set(analyses.map(\.bundle.caseName)), ["þf", "ef"])
        XCTAssertTrue(analyses.allSatisfy(\.bundle.isPlural))
    }

    func testUnknownLemmaAndFormReturnEmpty() throws {
        let reader = try requireReader()
        XCTAssertTrue(reader.groups(ofLemma: "xyzzyquux").isEmpty)
        XCTAssertTrue(reader.analyses(ofForm: "xyzzyquux").isEmpty)
        XCTAssertFalse(reader.isKnownForm("xyzzyquux"))
        XCTAssertTrue(reader.isKnownForm("hestinum"))
    }

    func testLookupsAreCaseInsensitive() throws {
        let reader = try requireReader()
        XCTAssertEqual(
            reader.analyses(ofForm: "Hestinum"),
            reader.analyses(ofForm: "hestinum")
        )
        XCTAssertEqual(reader.groups(ofLemma: "HESTUR").count, 1)
    }

    // MARK: - Bundle encoding round-trips

    func testBundleCaseReplacement() {
        // no:nf:et:ngr (raw 0) → no:þgf:et:ngr (raw 2)
        let nominative = ParadigmBundle(rawValue: 0)
        XCTAssertEqual("\(nominative)", "no:nf:et:ngr")
        let dative = nominative.replacingCase(2)
        XCTAssertEqual("\(dative)", "no:þgf:et:ngr")
        XCTAssertEqual(dative.replacingCase(0), nominative)
    }

    func testAdjectiveBundleDecoding() {
        // lo:nf:et:kk:fst:sb — pos bit set, everything else zero → raw 0b1000
        let bundle = ParadigmBundle(rawValue: 0b1000)
        XCTAssertEqual(bundle.pos, .adjective)
        XCTAssertEqual("\(bundle)", "lo:nf:et:kk:fst:sb")
        // strength bit (8) + gender kvk (bit 4) + degree mst (bit 6)
        let weak = ParadigmBundle(rawValue: 0b1_0101_1000)
        XCTAssertEqual("\(weak)", "lo:nf:et:kvk:mst:vb")
    }
}
