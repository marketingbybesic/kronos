import CoreData
import Foundation
import SwiftData
import XCTest
@testable import KronosCore

/// The frozen V1 copy must keep hashing exactly like the stores real builds wrote, or SwiftData
/// stops recognising them and refuses to open them. The expected hashes below were read from the
/// store metadata (`NSStoreModelVersionHashes`) of real stores, never computed from this code:
///   - V1: a store opened and saved by the 09665b2 build (the first child-task release);
///   - older shape: a store last written by a build from before child tasks existed.
/// XCTest for the reason given on `SchemaV2MigrationTests`.
final class FrozenSchemaHashTests: XCTestCase {

    static let v1Written: [String: String] = [
        "KArea": "WmRK+7hAP9G6hCerNT55OIZKiJSEBnHgR4ykOq0DKbk=",
        "KLabel": "c/0h+7iMaKzzqMdVA5UQ6AgSyac37k5JK/ZMFMGdLG8=",
        "KProject": "pVtD7/8dqKlN1UV+6z1FU0CugAjzCWrU/LNCZFZIQqM=",
        "KRule": "X/VSn5ulnnxc74N/7SXCz3jncWRbqtbNWS1zvdoLqJ8=",
        "KSavedView": "6YEXsJubTWeNGJY/nN539zjAuLhgP+Xubyk7NRRERoA=",
        "KSubtask": "GaRq+ycmTFbwH4yddt/giohBDRKzYMLMQA/rIzJRL6M=",
        "KTask": "oh/zTcpImWXO7vHljGI+lbY2AZ0gSuJNZV2zO5gU9Vo=",
    ]

    static let olderShapeWritten: [String: String] = [
        "KArea": "WmRK+7hAP9G6hCerNT55OIZKiJSEBnHgR4ykOq0DKbk=",
        "KLabel": "c/0h+7iMaKzzqMdVA5UQ6AgSyac37k5JK/ZMFMGdLG8=",
        "KProject": "pVtD7/8dqKlN1UV+6z1FU0CugAjzCWrU/LNCZFZIQqM=",
        "KRule": "X/VSn5ulnnxc74N/7SXCz3jncWRbqtbNWS1zvdoLqJ8=",
        "KSavedView": "6YEXsJubTWeNGJY/nN539zjAuLhgP+Xubyk7NRRERoA=",
        "KSubtask": "GaRq+ycmTFbwH4yddt/giohBDRKzYMLMQA/rIzJRL6M=",
        "KTask": "11Ep2dOb3QrNdC2usBvfCdym3v0r2hppjrMn7NfOrWM=",
    ]

    private func hashes(_ models: [any PersistentModel.Type]) throws -> [String: String] {
        let model = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: models))
        return model.entityVersionHashesByName.mapValues { $0.base64EncodedString() }
    }

    func testFrozenV1HashesLikeTheStoresTheFirstChildTaskBuildWrote() throws {
        XCTAssertEqual(try hashes(KronosSchemaV1.models), Self.v1Written)
    }

    func testTheOlderShapeFixtureHashesLikeARealOlderStore() throws {
        XCTAssertEqual(try hashes(SchemaV0Test.models), Self.olderShapeWritten)
    }

    func testV2DiffersFromV1OnlyWhereItShould() throws {
        let v2 = try hashes(KronosSchemaV2.models)
        XCTAssertEqual(Set(v2.keys), ["KArea", "KProject", "KLabel", "KTask", "KRule", "KSavedView",
                                      "KStoreMeta", "KSession", "KAttachment"])
        for unchanged in ["KArea", "KProject", "KLabel", "KRule", "KSavedView"] {
            XCTAssertEqual(v2[unchanged], Self.v1Written[unchanged], "\(unchanged) has no V2 change")
        }
        XCTAssertNotEqual(v2["KTask"], Self.v1Written["KTask"])
    }
}
