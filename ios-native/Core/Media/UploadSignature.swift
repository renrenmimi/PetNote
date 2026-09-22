import Foundation

/// What `getCloudinaryUploadSignature` hands back (functions/src/media.ts).
struct UploadSignature: Sendable, Equatable {
    let cloudName: String
    let apiKey: String
    let timestamp: Int
    let signature: String
    let uploadPreset: String
    let folder: String
    /// **Advisory.** See `isAdvisory` below.
    let maxFileSize: Int

    /// The parameters the server actually signed, and therefore the only ones
    /// whose values the signature covers.
    ///
    /// **Do not add to this set, and do not put anything outside it into the
    /// signed half of the form.** Cloudinary signs only the upload parameters
    /// it recognises and silently ignores the rest, so a fourth parameter it
    /// never verifies produces a signature that cannot match — every upload
    /// fails with a `String to sign` in the error that lists exactly these
    /// three. That is not a hypothetical: `max_file_size` was added here to
    /// "enforce" the ceiling below and took production's uploads down.
    ///
    /// The server-side comment in functions/src/media.ts is the authority; this
    /// set mirrors it so the client can be *checked* against it rather than
    /// trusted to agree.
    static let signedParameterNames: Set<String> = ["folder", "timestamp", "upload_preset"]

    /// The signed parameters, by name, with the values the signature was
    /// computed over.
    var signedParameters: [String: String] {
        [
            "folder": folder,
            "timestamp": String(timestamp),
            "upload_preset": uploadPreset,
        ]
    }

    /// Every field that goes into the multipart body except the file itself.
    ///
    /// Three signed parameters plus two that authenticate the request rather
    /// than being covered by it (`api_key`, `signature`). Nothing else. The
    /// test `theUploadFormCarriesOnlyWhatTheServerSigned` is what keeps that
    /// true when somebody next wants to "just pass one more thing".
    var formFields: [String: String] {
        var fields = signedParameters
        fields["api_key"] = apiKey
        fields["signature"] = signature
        return fields
    }

    func uploadEndpoint(for resourceType: UploadedAsset.ResourceType) -> URL? {
        URL(string: "https://api.cloudinary.com/v1_1/\(cloudName)/\(resourceType.rawValue)/upload")
    }

    /// `maxFileSize` is a **client-side hint**, not a limit anybody enforces.
    ///
    /// Spelled out as a property so the name at the call site says what the
    /// number is worth. The real ceiling is the Cloudinary account plan, which
    /// rejects an oversize file whatever we send; the upload preset has no
    /// max-file-size setting at all; and the signature cannot constrain an
    /// upload, only prove who asked for it. Checking here buys a clear message
    /// instead of a doomed upload — and nothing more.
    static let isAdvisory = true

    init(
        cloudName: String, apiKey: String, timestamp: Int, signature: String,
        uploadPreset: String, folder: String, maxFileSize: Int
    ) {
        self.cloudName = cloudName
        self.apiKey = apiKey
        self.timestamp = timestamp
        self.signature = signature
        self.uploadPreset = uploadPreset
        self.folder = folder
        self.maxFileSize = maxFileSize
    }

    /// Decodes the callable's answer.
    ///
    /// Returns nil rather than filling in defaults: a signature with a guessed
    /// field cannot match, and failing at the call is a much better report than
    /// an "Invalid Signature" from Cloudinary three seconds later.
    init?(callableResponse raw: Any?) {
        guard let data = raw as? [String: Any],
              let cloudName = data["cloudName"] as? String, !cloudName.isEmpty,
              let apiKey = data["apiKey"] as? String, !apiKey.isEmpty,
              let signature = data["signature"] as? String, !signature.isEmpty,
              let uploadPreset = data["uploadPreset"] as? String, !uploadPreset.isEmpty,
              let folder = data["folder"] as? String, !folder.isEmpty
        else { return nil }
        // The callable sends JSON numbers, which arrive as NSNumber and bridge
        // to Int or Double depending on how they were written. `timestamp` is
        // part of the signed string, so reading it as the wrong type is not a
        // cosmetic bug — the string would not match.
        guard let timestamp = Self.integer(data["timestamp"]) else { return nil }
        self.init(
            cloudName: cloudName,
            apiKey: apiKey,
            timestamp: timestamp,
            signature: signature,
            uploadPreset: uploadPreset,
            folder: folder,
            maxFileSize: Self.integer(data["maxFileSize"]) ?? 0
        )
    }

    static func integer(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int: value
        case let value as Int64: Int(value)
        case let value as Double where value.isFinite: Int(value)
        case let value as NSNumber: value.intValue
        case let value as String: Int(value)
        default: nil
        }
    }
}

/// Builds the multipart body Cloudinary's upload endpoint expects.
///
/// Separated from the network call so the body can be asserted in a test
/// without a server: the thing that has gone wrong here is the *field set*, and
/// a field set is a value.
enum UploadFormBody {
    static func multipart(
        fields: [String: String], fileData: Data, filename: String, mimeType: String,
        boundary: String
    ) -> Data {
        var body = Data()
        // Sorted so the body is a function of its inputs. Cloudinary does not
        // care about the order; a test comparing two bodies does.
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// The field names present in a multipart body, for tests and for the
    /// guard that the form never grows a parameter the signature does not
    /// cover.
    static func fieldNames(inMultipart body: Data) -> Set<String> {
        guard let text = String(data: body.prefix(64 * 1024), encoding: .isoLatin1) else { return [] }
        var names: Set<String> = []
        // The negative lookbehind is load-bearing: `filename="photo.jpg"` also
        // ends in `name="…"`, and without it the scanner reported the photo's
        // filename as a form field — which would have made the "no extra
        // parameters" guard fail for a reason that had nothing to do with
        // parameters.
        let pattern = #"(?<!file)name="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            if let captured = Range(match.range(at: 1), in: text) {
                names.insert(String(text[captured]))
            }
        }
        return names
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
