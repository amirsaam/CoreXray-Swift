import Foundation

// Geo database inventory. The download itself (`XrayGeoDownloader`) needs
// no engine; only the inventory read goes through here.

internal final class GeoCalls {
    /// Never instantiated: all members are static.
    private init() {}

    internal static func writeInventory(
        database: String,
        kind: XrayGeoDatabase,
        directory: URL
    ) throws -> URL {
        try EngineTransport.acknowledge(
            .catalogGeoData,
            payload: Xray.GeoCatalogRequest(directory: directory.path, name: database, kind: kind)
        )
        return directory.appendingPathComponent("\(database).json")
    }
}

extension Xray {
    internal struct GeoCatalogRequest: Encodable {
        let directory: String
        let name: String
        let kind: XrayGeoDatabase

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(directory, forKey: .directory)
            try container.encode(name, forKey: .name)
            try container.encode(kind.engineName, forKey: .kind)
        }

        enum CodingKeys: String, CodingKey {
            case directory = "datDir"
            case name
            case kind = "geoType"
        }
    }
}
