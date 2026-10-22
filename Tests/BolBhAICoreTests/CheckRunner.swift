import Foundation

// The Apple Command Line Tools do not ship XCTest. This small runner
// executes the same behavioral checks with no external dependency.
@MainActor class XCTestCase {}
@MainActor enum CheckState { static var failures: [String] = []; static var count = 0 }
@MainActor func XCTFail(_ message: String = "Check failed", file: StaticString = #filePath, line: UInt = #line) {
    CheckState.failures.append("\(file):\(line): \(message)")
}
@MainActor func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { if !value() { XCTFail("Expected true. \(message)", file: file, line: line) } }
@MainActor func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { if value() { XCTFail("Expected false. \(message)", file: file, line: line) } }
@MainActor func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if lhs != rhs { XCTFail("\(lhs) != \(rhs). \(message)", file: file, line: line) }
}
@MainActor func XCTAssertNil<T>(_ value: @autoclosure () -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { if value() != nil { XCTFail("Expected nil. \(message)", file: file, line: line) } }
@MainActor func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) { if lhs > rhs { XCTFail("Expected <=", file: file, line: line) } }
@MainActor func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { XCTFail("Unexpected error: \(error). \(message)", file: file, line: line) }
}
@MainActor func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); XCTFail("Expected error. \(message)", file: file, line: line) } catch { }
}
@MainActor func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { XCTFail("Expected non-nil", file: file, line: line); throw CheckError.failed }; return value
}
enum CheckError: Error { case failed }
@MainActor func checks(_ name: String, _ body: () async throws -> Void) async rethrows {
    let before = CheckState.failures.count; CheckState.count += 1
    do { try await body() } catch { XCTFail("\(name): \(error)") }
    print("\(CheckState.failures.count == before ? "PASS" : "FAIL") \(name)")
}
@main struct CheckRunner {
    @MainActor static func main() async {
        do { try await runSessionChecks(); try await runLifecycleChecks(); try await runCleanupChecks() }
        catch { XCTFail("Unexpected check error: \(error)") }
        for failure in CheckState.failures { print(failure) }
        print("\(CheckState.count) checks; \(CheckState.failures.count) failures")
        if !CheckState.failures.isEmpty { exit(1) }
    }
}
