import Foundation
import Testing

@testable import PetNote

/// The upload request, field by field.
///
/// This suite exists because of one production outage. `max_file_size` was
/// added to the signed parameter set to "enforce" the size ceiling; Cloudinary
/// signs only the parameters it recognises and silently ignores the rest, so
/// the signature could not match and **every** upload failed. Its own error
/// echoed the `String to sign` back, and it listed folder, timestamp and
/// upload_preset — nothing else.
///
/// So the field set is pinned as a value, from three directions: what the
/// server says it signed, what the client puts in the form, and what the bytes
/// on the wire actually contain.
struct UploadSignatureTests {
    static let sample = UploadSignature(
        cloudName: "petnote",
        apiKey: "123456789012345",
        timestamp: 1_758_412_800,
        signature: "deadbeef",
        uploadPreset: "petnote_image_signed",
        folder: "petnote/users/abc123",
        maxFileSize: 10 * 1024 * 1024
    )

    @Test func exactlyThreeParametersAreSigned() {
        #expect(UploadSignature.signedParameterNames == ["folder", "timestamp", "upload_preset"])
        #expect(Set(Self.sample.signedParameters.keys) == UploadSignature.signedParameterNames)
    }

    /// The form is the signed three, plus the two that identify the caller
    /// rather than being covered by the signature. Nothing else may be in it.
    @Test func theUploadFormCarriesOnlyWhatTheServerSigned() {
        let fields = Self.sample.formFields

        #expect(Set(fields.keys) == ["folder", "timestamp", "upload_preset", "api_key", "signature"])
        #expect(fields["max_file_size"] == nil, """
            max_file_size in the form is what took production's uploads down. \
            The limit is the account plan's; the signature cannot enforce it.
            """)
        // Every signed parameter must travel with the value it was signed with.
        for (name, value) in Self.sample.signedParameters {
            #expect(fields[name] == value)
        }
    }

    @Test func theMultipartBodyContainsThoseFieldsAndTheFile() {
        let body = UploadFormBody.multipart(
            fields: Self.sample.formFields,
            fileData: Data(repeating: 0x7F, count: 32),
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            boundary: "TESTBOUNDARY"
        )
        let names = UploadFormBody.fieldNames(inMultipart: body)

        #expect(names == ["folder", "timestamp", "upload_preset", "api_key", "signature", "file"])
    }

    /// The scanner has to be able to see a field, or "no max_file_size" above
    /// is "the parser matched nothing".
    @Test func theBodyScannerReallyFindsAnExtraField() {
        var fields = Self.sample.formFields
        fields["max_file_size"] = "10485760"
        let body = UploadFormBody.multipart(
            fields: fields, fileData: Data(), filename: "x.jpg",
            mimeType: "image/jpeg", boundary: "B"
        )

        #expect(UploadFormBody.fieldNames(inMultipart: body).contains("max_file_size"))
    }

    /// No source file in this line may name the parameter at all.
    ///
    /// The value over the two tests above is that they check the shapes a
    /// programmer builds deliberately; this catches the one appended somewhere
    /// else on the way to the request.
    @Test func noUploadSourceEverNamesTheParameterThatBrokeProduction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        var offenders: [String] = []
        // Only the files this line owns. A scan that reaches into another
        // batch's directory turns their half-written code into this suite's
        // failure, and four batches share this tree.
        for url in PublishSourceFiles.owned(root: root) {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Prose explaining why it is absent is not a use of it.
            let code = text.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("\"max_file_size\"") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, """
            A source file names max_file_size as a parameter. Cloudinary does \
            not verify it, so signing or sending it makes every upload fail.
            """)
    }

    // MARK: - Decoding the callable's answer

    @Test func theSignatureIsReadOutOfTheCallableResponse() throws {
        let response: [String: Any] = [
            "cloudName": "petnote",
            "apiKey": "key",
            // Firebase hands numbers back as NSNumber; timestamp is part of the
            // signed string, so reading it as the wrong type is not cosmetic.
            "timestamp": NSNumber(value: 1_758_412_800),
            "signature": "sig",
            "uploadPreset": "petnote_video_signed",
            "folder": "petnote/users/abc",
            "maxFileSize": NSNumber(value: 80 * 1024 * 1024),
        ]
        let signature = try #require(UploadSignature(callableResponse: response))

        #expect(signature.timestamp == 1_758_412_800)
        #expect(signature.signedParameters["timestamp"] == "1758412800")
        #expect(signature.maxFileSize == 80 * 1024 * 1024)
    }

    @Test func aSignatureMissingAFieldIsRefusedRatherThanGuessedAt() {
        let missingFolder: [String: Any] = [
            "cloudName": "petnote", "apiKey": "key", "timestamp": 1,
            "signature": "sig", "uploadPreset": "preset",
        ]
        #expect(UploadSignature(callableResponse: missingFolder) == nil, """
            A signature with a guessed field cannot match, and failing here \
            reports far better than an Invalid Signature three seconds later.
            """)
    }

    @Test func theEndpointFollowsTheResourceType() {
        #expect(
            Self.sample.uploadEndpoint(for: .image)?.absoluteString
                == "https://api.cloudinary.com/v1_1/petnote/image/upload"
        )
        #expect(
            Self.sample.uploadEndpoint(for: .video)?.absoluteString
                == "https://api.cloudinary.com/v1_1/petnote/video/upload"
        )
    }

    // MARK: - Assets

    @Test func aVideoAssetCarriesAPosterAndAnImageDoesNot() throws {
        let video = try #require(
            URL(string: "https://res.cloudinary.com/petnote/video/upload/v1/petnote/users/u/clip.mp4")
        )
        let poster = try #require(CloudinaryUploadClient.poster(for: video))

        #expect(poster.absoluteString.contains("so_0"), "the poster is the frame at second zero")
        #expect(poster.pathExtension == "jpg")

        let asset = UploadedAsset(
            url: video, publicID: "petnote/users/u/clip", resourceType: .video, thumbnailURL: poster
        )
        let payload = asset.callablePayload
        #expect(payload["type"] as? String == "video")
        #expect(payload["thumbUrl"] as? String == poster.absoluteString)

        let image = UploadedAsset(
            url: try #require(URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/a.jpg")),
            publicID: "a", resourceType: .image, thumbnailURL: nil
        )
        #expect(image.callablePayload["thumbUrl"] == nil, """
            An absent thumbnail must be omitted, not sent as null: the server \
            copies what it is given straight into the document.
            """)
    }

    /// A round trip through the draft's encoding.
    ///
    /// The assets are what make a retry cheap, so they have to survive being
    /// written down and read back — including the optional poster.
    @Test func anAssetSurvivesBeingWrittenIntoADraft() throws {
        let asset = UploadedAsset(
            url: try #require(URL(string: "https://res.cloudinary.com/petnote/image/upload/v1/a.jpg")),
            publicID: "petnote/users/u/a", resourceType: .image, thumbnailURL: nil
        )
        let data = try JSONEncoder().encode([asset])
        let restored = try JSONDecoder().decode([UploadedAsset].self, from: data)

        #expect(restored == [asset])
    }
}


/// The source files this batch owns, so a source-level guard can be pointed at
/// them and at nothing else.
///
/// Four batches work in one tree. A guard that walks `Core/Media` whole would
/// report another batch's in-flight file as this suite's failure, which is the
/// fastest way to make a guard get switched off.
enum PublishSourceFiles {
    static func owned(root: URL) -> [URL] {
        var files: [URL] = []
        let fileManager = FileManager.default
        let media = root.appendingPathComponent("Core/Media")
        if let contents = try? fileManager.contentsOfDirectory(atPath: media.path) {
            files += contents
                .filter { $0.hasPrefix("Upload") && $0.hasSuffix(".swift") }
                .map(media.appendingPathComponent)
        }
        files.append(root.appendingPathComponent("Core/Repository/FirestorePostWriteRepository.swift"))
        for directory in ["Features/Compose", "Features/PostManage"] {
            let url = root.appendingPathComponent(directory)
            guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: nil)
            else { continue }
            for case let found as URL in walker where found.pathExtension == "swift" {
                files.append(found)
            }
        }
        return files.filter { fileManager.fileExists(atPath: $0.path) }
    }
}
