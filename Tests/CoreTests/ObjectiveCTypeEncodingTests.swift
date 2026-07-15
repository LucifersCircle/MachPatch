import MachPatchCore
import XCTest

final class ObjectiveCTypeEncodingTests: XCTestCase {
    func testDecodesPlanExamplesWithAndWithoutLayoutOffsets() throws {
        let boolean = try decode("B@:")
        XCTAssertEqual(boolean.returnType.kind, .boolean)
        XCTAssertNil(boolean.frameSize)
        XCTAssertEqual(boolean.arguments.map(\.kind), [.object, .selector])
        XCTAssertTrue(boolean.explicitArguments.isEmpty)

        let laidOutBoolean = try decode("B16@0:8")
        XCTAssertEqual(laidOutBoolean.returnType.kind, .boolean)
        XCTAssertEqual(laidOutBoolean.frameSize, 16)
        XCTAssertEqual(laidOutBoolean.arguments.map(\.kind), [.object, .selector])

        let voidWithBoolean = try decode("v24@0:8B16")
        XCTAssertEqual(voidWithBoolean.returnType.kind, .void)
        XCTAssertEqual(voidWithBoolean.explicitArguments.map(\.kind), [.boolean])

        XCTAssertEqual(try decode("q@:").returnType.kind, .signedLongLong)
        XCTAssertEqual(try decode("Q@:").returnType.kind, .unsignedLongLong)
        XCTAssertEqual(try decode("@@:").returnType.kind, .object)
    }

    func testDecodesEveryScalarCode() throws {
        let expected: [(Character, ObjectiveCTypeKind)] = [
            ("v", .void),
            ("B", .boolean),
            ("c", .signedChar),
            ("C", .unsignedChar),
            ("s", .signedShort),
            ("S", .unsignedShort),
            ("i", .signedInt),
            ("I", .unsignedInt),
            ("l", .signedLong),
            ("L", .unsignedLong),
            ("q", .signedLongLong),
            ("Q", .unsignedLongLong),
            ("f", .float),
            ("d", .double),
            ("D", .longDouble),
            ("#", .classObject),
            (":", .selector),
            ("*", .cString),
            ("?", .unknown),
        ]

        for (code, kind) in expected {
            XCTAssertEqual(try decode("\(code)@:").returnType.kind, kind, "code \(code)")
        }
    }

    func testDecodesObjectAnnotationsQualifiersAndNestedTypes() throws {
        let signature = try decode(
            "@\"NSString\"64@0:8r^i16[4Q]24{CGPoint=\"x\"d\"y\"d}32(Choice=qQ)48"
        )

        XCTAssertEqual(signature.returnType.kind, .object)
        XCTAssertEqual(signature.returnType.annotation, "NSString")
        XCTAssertEqual(signature.explicitArguments.count, 4)

        let pointer = signature.explicitArguments[0]
        XCTAssertEqual(pointer.kind, .pointer)
        XCTAssertEqual(pointer.qualifiers, [.constant])
        XCTAssertEqual(pointer.children.map(\.kind), [.signedInt])

        let array = signature.explicitArguments[1]
        XCTAssertEqual(array.kind, .array)
        XCTAssertEqual(array.count, 4)
        XCTAssertEqual(array.children.map(\.kind), [.unsignedLongLong])

        let structure = signature.explicitArguments[2]
        XCTAssertEqual(structure.kind, .structure)
        XCTAssertEqual(structure.annotation, "CGPoint")
        XCTAssertEqual(structure.children.map(\.kind), [.double, .double])

        let union = signature.explicitArguments[3]
        XCTAssertEqual(union.kind, .union)
        XCTAssertEqual(union.annotation, "Choice")
        XCTAssertEqual(union.children.map(\.kind), [.signedLongLong, .unsignedLongLong])
    }

    func testRecognizesBlocksFunctionPointersAndBitFieldsWithoutTreatingThemAsObjects() throws {
        let signature = try decode("v40@0:8@?16^?24b7")

        XCTAssertEqual(
            signature.explicitArguments.map(\.kind),
            [.block, .pointer, .bitField]
        )
        XCTAssertEqual(signature.explicitArguments[1].children.map(\.kind), [.unknown])
        XCTAssertEqual(signature.explicitArguments[2].count, 7)
    }

    func testRecognizesOnlyExactSupportedStructureLayouts() throws {
        XCTAssertEqual(try decode("{CGPoint=dd}@:").returnType.knownStructure, .cgPoint)
        XCTAssertEqual(try decode("{CGSize=dd}@:").returnType.knownStructure, .cgSize)
        XCTAssertEqual(
            try decode("{CGRect={CGPoint=dd}{CGSize=dd}}@:").returnType.knownStructure,
            .cgRect
        )
        XCTAssertEqual(try decode("{_NSRange=QQ}@:").returnType.knownStructure, .nsRange)
        XCTAssertEqual(try decode("{NSRange=QQ}@:").returnType.knownStructure, .nsRange)

        XCTAssertNil(try decode("{Point=dd}@:").returnType.knownStructure)
        XCTAssertNil(try decode("{CGPoint=ff}@:").returnType.knownStructure)
        XCTAssertNil(try decode("{_NSRange=II}@:").returnType.knownStructure)
        XCTAssertNil(
            try decode("{CGRect={CGPoint=ff}{CGSize=ff}}@:").returnType.knownStructure
        )
    }

    func testAcceptsSignedLayoutOffsetsAndWhitespace() throws {
        let signature = try decode("  v24  @+0  :-8  i16  ")
        XCTAssertEqual(signature.frameSize, 24)
        XCTAssertEqual(signature.arguments.map(\.kind), [.object, .selector, .signedInt])
    }

    func testRejectsMalformedEncodingsWithOffsets() {
        let malformed = [
            "",
            "v@:[4i",
            "v@:{Thing=i",
            "v@:@\"NSString",
            "v@:b",
            "v@:x",
            "v@:[i]",
        ]

        for encoding in malformed {
            XCTAssertThrowsError(try decode(encoding), encoding) { error in
                XCTAssertNotNil(error as? ObjectiveCTypeEncodingError)
            }
        }
    }

    func testDecodedSignatureRoundTripsThroughCodable() throws {
        let signature = try decode("B24@0:8@\"NSNumber\"16")
        let encoded = try JSONEncoder().encode(signature)
        let decoded = try JSONDecoder().decode(ObjectiveCMethodSignature.self, from: encoded)
        XCTAssertEqual(decoded, signature)
    }

    private func decode(_ encoding: String) throws -> ObjectiveCMethodSignature {
        try ObjectiveCTypeEncodingDecoder.decodeMethodSignature(encoding)
    }
}
