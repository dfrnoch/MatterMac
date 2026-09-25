import Foundation
import MatterMacModels

/// `POST /teams/{id}/files/search` → FileInfoList
/// `{order:[ids], file_infos:{id:FileInfo}, next_file_info_id, prev_file_info_id,
/// first_inaccessible_file_time}` (verified live on 10.11.24 and 11.11.1). Entries are
/// kept only when listed in `order` and their embedded id matches the map key; the
/// result is capped at `maximumFiles`.
struct FileInfoListWire: Decodable {
    static let maximumFiles = 200

    let files: [FileInfo]
    let skippedMalformed: Int

    enum Keys: String, CodingKey { case order, file_infos }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let rawOrder = ((try? c.decodeIfPresent([String].self, forKey: .order)) ?? []).prefix(Self.maximumFiles * 2)
        var infos: [FileID: FileInfo] = [:]
        var skipped = 0
        if c.contains(.file_infos), (try? c.decodeNil(forKey: .file_infos)) != true,
           let map = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: .file_infos) {
            for key in map.allKeys.prefix(Self.maximumFiles * 2) {
                guard let wire = try? map.decode(FileInfoWire.self, forKey: key), wire.info.id.rawValue == key.stringValue else {
                    skipped += 1
                    continue
                }
                infos[wire.info.id] = wire.info
            }
        }
        var seen = Set<FileID>()
        var files: [FileInfo] = []
        for raw in rawOrder where files.count < Self.maximumFiles {
            guard let id = FileID(rawValue: raw), let info = infos[id], seen.insert(id).inserted else { continue }
            files.append(info)
        }
        self.files = files
        self.skippedMalformed = skipped + max(0, infos.count - files.count)
    }
}

/// `PUT /users/{id}/patch` with only the changed profile fields (absent keys are kept).
struct UserProfilePatchBody: Encodable {
    let patch: UserProfilePatch

    func encode(to encoder: any Encoder) throws {
        enum Keys: String, CodingKey { case first_name, last_name, nickname, position }
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(patch.firstName, forKey: .first_name)
        try c.encodeIfPresent(patch.lastName, forKey: .last_name)
        try c.encodeIfPresent(patch.nickname, forKey: .nickname)
        try c.encodeIfPresent(patch.position, forKey: .position)
    }
}

/// `PUT /users/{id}/status` for a timed Do Not Disturb (`dnd_end_time` in seconds).
struct TimedStatusBody: Encodable {
    let user_id: String
    let status: String
    let dnd_end_time: Int64
}

/// A `multipart/form-data` body with one file part, assembled in memory. Only used
/// for small, already bounded payloads (the re-encoded profile picture); user files
/// are streamed through the raw-body upload instead.
struct MultipartFormBody {
    let boundary: String
    let data: Data

    var contentType: String { "multipart/form-data; boundary=" + boundary }

    /// `field` and `fileName` must be plain ASCII tokens without quotes or line breaks.
    init?(field: String, fileName: String, contentType: String, content: Data, boundary: String = MultipartFormBody.makeBoundary()) {
        let isToken: (String) -> Bool = { value in
            !value.isEmpty && value.utf8.count <= 128
                && value.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }
        }
        guard isToken(field), isToken(fileName), isToken(contentType), isToken(boundary),
              content.range(of: Data(("--" + boundary).utf8)) == nil else { return nil }
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        self.boundary = boundary
        self.data = body
    }

    static func makeBoundary() -> String {
        "MatterMacBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
