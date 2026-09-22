import Foundation
import OSLog
import UIKit

/// The picture that came back from Cloudinary.
///
/// `publicId` is carried, not just the URL: it is the only thing that can undo
/// an upload whose Firestore write then failed, and an orphan image nobody can
/// name is an orphan image forever.
struct UploadedAvatar: Sendable, Equatable {
    let url: String
    let publicID: String
}

enum AvatarUploadError: Error, Sendable, Equatable {
    case tooLarge(limitBytes: Int)
    case notAnImage
    case timedOut
    case offline
    case rejected(String)
    case transport(String)

    var message: String {
        switch self {
        case .tooLarge(let limit):
            "That photo is larger than \(limit / (1024 * 1024))MB. Choose a smaller one."
        case .notAnImage:
            "That file is not an image we can use."
        case .timedOut:
            "The upload timed out. Check your connection and try again."
        case .offline:
            "No connection. Check your network and try again."
        case .rejected(let reason):
            reason
        case .transport:
            "The photo could not be uploaded. Try again."
        }
    }
}

/// Uploading a profile picture, behind a protocol so the screens that use it
/// can be tested without a network.
protocol AvatarUploading: Sendable {
    func upload(imageData: Data) async throws -> UploadedAvatar
    /// Best-effort cleanup for a picture that was uploaded and never
    /// referenced. **Never throws**: the caller is already reporting a
    /// failure, and this must not replace that report with its own.
    func discard(_ avatar: UploadedAvatar) async
}

/// TEMP-SHARED: this duplicates nothing yet and should not stay duplicated.
///
/// The shared uploader lives at `Core/Media/Upload*.swift` and belongs to the
/// posting line, which has not landed it. Rather than block the profile screen
/// on it, the signed-upload dance is implemented here against the same two
/// callables the web client uses. **When the shared uploader lands, this type
/// should become a thin adapter over it** — the handover says so.
///
/// Two details that are not obvious and that have cost this project time
/// before:
///
///   - **only the parameters the signature covers are sent.** The server signs
///     `timestamp`, `folder` and `upload_preset`; adding `max_file_size` to the
///     form makes Cloudinary include it in the string it verifies, and every
///     upload fails the signature check. The size limit is applied before the
///     request instead, and the enforceable ceiling lives in the upload preset;
///   - **the size limit is the account's**, handed back by the callable. It is
///     not a constant to copy here.
struct CloudinaryAvatarUploader: AvatarUploading {
    /// 90 seconds: enough for a large photo on a poor uplink, short enough
    /// that a hung request does not leave a spinner up forever.
    static let requestTimeout: TimeInterval = 90

    private let session: URLSession
    private let environment: AppEnvironment
    private var log: Logger { Logger(subsystem: "dev.local.petnote.native", category: "profile") }

    /// No `Functions` held here: callables go through `CallableClient`, which
    /// is where the `sending` payload rule lives.
    init(session: URLSession = .shared, environment: AppEnvironment = .current) {
        self.session = session
        self.environment = environment
    }

    func upload(imageData: Data) async throws -> UploadedAvatar {
        guard environment.supportsCallables else {
            throw AvatarUploadError.transport(FirestoreUserRepository.callablesUnavailable)
        }

        let signature: Signature
        do {
            let data = try await CallableClient.call(
                Callables.cloudinaryUploadSignature, ["resourceType": "image"]
            )
            guard let parsed = Signature(data) else {
                throw AvatarUploadError.transport("signature-shape")
            }
            signature = parsed
        } catch let error as AvatarUploadError {
            throw error
        } catch {
            throw Self.mapCallableFailure(error)
        }

        if signature.maxFileSize > 0, imageData.count > signature.maxFileSize {
            throw AvatarUploadError.tooLarge(limitBytes: signature.maxFileSize)
        }

        let boundary = "petnote-\(UUID().uuidString)"
        guard let endpoint = UploadSignature.endpoint(cloudName: signature.cloudName, resourceType: "image") else {
            throw AvatarUploadError.transport("bad-cloud-name")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary, imageData: imageData, signature: signature
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw AvatarUploadError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                throw AvatarUploadError.offline
            default:
                throw AvatarUploadError.transport("url-\(error.code.rawValue)")
            }
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            log.error("cloudinary upload rejected with status \(status)")
            throw AvatarUploadError.transport("http-\(status)")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = payload["secure_url"] as? String,
              let publicID = payload["public_id"] as? String
        else {
            throw AvatarUploadError.transport("upload-shape")
        }
        return UploadedAvatar(url: url, publicID: publicID)
    }

    func discard(_ avatar: UploadedAvatar) async {
        guard environment.supportsCallables else { return }
        do {
            try await CallableClient.callIgnoringResult(
                Callables.deleteCloudinaryAssets,
                ["assets": [["publicId": avatar.publicID, "resourceType": "image"]]]
            )
        } catch {
            // Deliberately swallowed. An orphan image is the cheaper mistake,
            // and the caller is in the middle of reporting the real failure.
            log.warning("orphan avatar cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What `getCloudinaryUploadSignature` hands back.
    struct Signature: Sendable, Equatable {
        let cloudName: String
        let apiKey: String
        let timestamp: Int
        let signature: String
        let uploadPreset: String
        let folder: String
        let maxFileSize: Int

        init?(_ data: [String: Any]) {
            guard let cloudName = data["cloudName"] as? String,
                  let apiKey = data["apiKey"] as? String,
                  let signature = data["signature"] as? String,
                  let uploadPreset = data["uploadPreset"] as? String,
                  let folder = data["folder"] as? String
            else { return nil }
            // The numbers cross the wire as NSNumber and can arrive as either
            // Int or Double depending on the JSON bridge; asking for one of
            // them only is how a valid response gets rejected.
            guard let timestamp = (data["timestamp"] as? NSNumber)?.intValue else { return nil }
            self.cloudName = cloudName
            self.apiKey = apiKey
            self.timestamp = timestamp
            self.signature = signature
            self.uploadPreset = uploadPreset
            self.folder = folder
            self.maxFileSize = (data["maxFileSize"] as? NSNumber)?.intValue ?? 0
        }

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
    }

    /// The exact set of form fields, and no more.
    ///
    /// Static and pure so the "nothing beyond the signed parameters" rule can
    /// be asserted rather than reviewed: an extra field here breaks every
    /// upload with a signature mismatch, and the failure looks like a server
    /// problem rather than like a client one.
    static func multipartBody(boundary: String, imageData: Data, signature: Signature) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(imageData)
        body.append(Data("\r\n".utf8))

        field("api_key", signature.apiKey)
        field("timestamp", String(signature.timestamp))
        field("signature", signature.signature)
        field("upload_preset", signature.uploadPreset)
        field("folder", signature.folder)
        // No `max_file_size`. See the type's own note: Cloudinary folds every
        // sent parameter into the string it verifies, and the server did not
        // sign this one.

        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// The signature callable's failures, in this screen's words.
    ///
    /// Delegates to `FirestoreUserRepository.map` rather than reading
    /// `FunctionsErrorCode` again. One place decides what a callable status
    /// means; this only chooses the sentence, and a status added there cannot
    /// be silently missed here.
    static func mapCallableFailure(_ error: Error) -> AvatarUploadError {
        switch FirestoreUserRepository.map(error) {
        case .offline:
            return .offline
        case .outcomeUnknown:
            // The signature request, not the upload: nothing was uploaded, so
            // there is no ambiguity about an asset — only about this request.
            return .timedOut
        case .rateLimited:
            return .rejected("Too many uploads just now. Wait a moment and try again.")
        case .notSignedIn:
            return .rejected("Sign in again to change your picture.")
        case .banned:
            return .rejected("This account cannot upload pictures.")
        case .displayNameTaken:
            // Not reachable from this callable; mapped rather than crashed.
            return .transport("unexpected-status")
        case .rejected(let reason):
            return .rejected(reason)
        case .transport(let detail):
            return .transport(detail)
        }
    }
}

/// Turning whatever the photo picker handed over into bytes worth uploading.
///
/// The same ceiling as the web client's `prepareImageForUpload`: 1920 on the
/// long edge, JPEG quality 0.8. A modern phone photo is 4000px and 5MB, and
/// sending that for a 100px avatar spends somebody's mobile data on pixels the
/// CDN immediately throws away.
enum AvatarImage {
    static let maxDimension: CGFloat = 1920
    static let jpegQuality: CGFloat = 0.8

    /// Nil when the bytes are not an image this device can decode.
    static func prepareForUpload(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let resized = downscaled(image)
        return resized.jpegData(compressionQuality: jpegQuality)
    }

    static func downscaled(_ image: UIImage) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxDimension, longEdge > 0 else { return image }
        let scale = maxDimension / longEdge
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        // 1, not the screen's scale: this is a pixel size for a file, and
        // rendering at @3x would silently produce an image three times the
        // dimension that was just calculated.
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
