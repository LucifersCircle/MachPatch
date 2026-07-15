import Foundation

public enum PatchBuildRecordCodec {
    public static func encode(_ record: PatchBuildRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> PatchBuildRecord {
        try JSONDecoder().decode(PatchBuildRecord.self, from: data)
    }

    public static func write(_ record: PatchBuildRecord, to url: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw PatchDylibBuilderError.unsafeOutputPath(url.path)
        }
        try encode(record).write(to: url, options: [.atomic])
    }
}
