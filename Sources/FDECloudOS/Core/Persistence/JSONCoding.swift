import Foundation

enum JSONCoding {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        do {
            let encoder = makeEncoder()
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw PersistenceError.encodingFailed(error.localizedDescription)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        guard let data = value.data(using: .utf8) else {
            throw PersistenceError.decodingFailed("Invalid UTF-8 payload")
        }

        do {
            let decoder = makeDecoder()
            return try decoder.decode(type, from: data)
        } catch {
            throw PersistenceError.decodingFailed(error.localizedDescription)
        }
    }
}
