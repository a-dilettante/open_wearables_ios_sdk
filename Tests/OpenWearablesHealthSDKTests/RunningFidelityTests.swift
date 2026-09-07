import HealthKit
import XCTest
@testable import OpenWearablesHealthSDK

final class RunningFidelityTests: XCTestCase {
    func testWireTimestampPreservesMicrosecondsAndNegativeEpoch() {
        XCTAssertEqual(OpenWearablesHealthSDK.wireTimestamp(Date(timeIntervalSince1970: 1_700_000_000.123456)), "2023-11-14T22:13:20.123456Z")
        XCTAssertEqual(OpenWearablesHealthSDK.wireTimestamp(Date(timeIntervalSince1970: 1_700_000_000.654321)), "2023-11-14T22:13:20.654321Z")
        XCTAssertEqual(OpenWearablesHealthSDK.wireTimestamp(Date(timeIntervalSince1970: -0.25)), "1969-12-31T23:59:59.750000Z")
    }

    @available(iOS 16.0, *)
    func testRunningRequestTypesSerializeCanonicalUnitsAndIntervals() throws {
        let sdk = OpenWearablesHealthSDK.shared
        let cases: [(HealthDataType, HKUnit, Double, String, Double)] = [
            (.runningSpeed, .meter().unitDivided(by: .second()), 3.5, "m/s", 3.5),
            (.runningPower, .watt(), 240, "W", 240),
            (.runningStrideLength, .meter(), 1.2, "cm", 120),
            (.runningVerticalOscillation, .meter(), 0.08, "cm", 8),
            (.runningGroundContactTime, .second(), 0.25, "ms", 250),
        ]
        let start = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let end = Date(timeIntervalSince1970: 1_700_000_000.654321)
        for (requestType, unit, value, expectedUnit, expectedValue) in cases {
            let type = try XCTUnwrap(requestType.toHKSampleType() as? HKQuantityType)
            let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: end)
            let data = try XCTUnwrap(sdk.buildCombinedPayload(samples: [sample])["data"] as? [String: Any])
            let record = try XCTUnwrap((data["records"] as? [[String: Any]])?.first)
            XCTAssertEqual(record["unit"] as? String, expectedUnit)
            XCTAssertEqual(try XCTUnwrap(record["value"] as? Double), expectedValue, accuracy: 0.000001)
            XCTAssertEqual(record["startDate"] as? String, "2023-11-14T22:13:20.123456Z")
            XCTAssertEqual(record["endDate"] as? String, "2023-11-14T22:13:20.654321Z")
        }
    }

    func testDeletionOnlyPayloadDoesNotRetainAnotherBatchesIdentities() throws {
        let sdk = OpenWearablesHealthSDK.shared
        let deletion = ["id": "synthetic-id", "type": "HKQuantityTypeIdentifierHeartRate"]
        let first = try XCTUnwrap(sdk.buildCombinedPayload(samples: [], seriesRecords: [], deletedMetrics: [deletion])["data"] as? [String: Any])
        XCTAssertEqual(first["deletedMetrics"] as? [[String: String]], [deletion])
        let second = try XCTUnwrap(sdk.buildCombinedPayload(samples: [], seriesRecords: [], deletedMetrics: [])["data"] as? [String: Any])
        XCTAssertNil(second["deletedMetrics"])
    }
}
