import FirebaseFunctions
import Foundation
import OSLog

/// One picked file, ready to be sent.
struct UploadItem: Sendable, Equatable {
    let data: Data
    let filename: String
    let mimeType: String
    let resourceType: UploadedAsset.ResourceType
}

/// One case per way an upload fails, because they need different words and
/// different recovery.
///
/// The split that matters is `timedOut` / `transport` versus the rest: those
/// two are the ones where the bytes may or may not have landed. That ambiguity
/// is cheap here — a re-upload costs data and leaves an orphan, it cannot
/// duplicate a post — and it is the publish step, not this one, where an
/// uncertain outcome has to be handled rather than retried.
enum UploadError: Error, Sendable, Equatable {
    case notSignedIn
    case banned
    case rateLimited
    /// The signature call itself refused or came back unusable.
    case signatureUnavailable(String)
    /// Over the plan's per-file ceiling, refused before sending. Advisory: see
    /// `UploadSignature.isAdvisory`.
    case tooLarge(limitBytes: Int, actualBytes: Int)
    case timedOut
    case offline
    /// Cloudinary answered and refused. Never retryable — the same bytes and
    /// the same signature will be refused again.
    case rejected(status: Int, message: String)
    /// The upload succeeded but the answer was not the shape the contract says.
    case malformedResponse
    case transport(String)

    /// Whether offering "try again" is honest.
    var isRetryable: Bool {
        switch self {
        case .rejected, .tooLarge, .banned, .notSignedIn: false
        case .rateLimited, .timedOut, .offline, .transport, .signatureUnavailable, .malformedResponse: true
        }
    }
}

protocol MediaUploading: Sendable {
    /// Signs, sends, and reports where the bytes landed.
    func upload(_ item: UploadItem) async throws -> UploadedAsset
}

/// Signed uploads straight to Cloudinary.
///
/// The server signs; the bytes never touch our functions. Three rules here come
/// from production incidents and the server's own comments:
///
///   1. **Only the signed parameters go in the signed half of the form.**
///      `UploadSignature.formFields` is the whole list, and it is the whole
///      list on purpose — adding one Cloudinary does not verify makes the
///      signature unmatchable and takes every upload down.
///   2. **The size check is advisory.** It buys a clear message before a doomed
///      upload; the enforceable ceiling is the account plan.
///   3. **Nothing here ever deletes.** This client — the composer's — has no
///      call to `deleteCloudinaryAssetsCallable`, and `AssetReclaim` is what
///      keeps it that way. The app's only call to it is elsewhere: a profile
///      picture whose save the server refused outright
///      (`CloudinaryAvatarUploader.discard`), as the web client does.
actor CloudinaryUploadClient: MediaUploading {
    private let functions: Functions
    private let session: URLSession
    private let environment: AppEnvironment
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "upload")

    /// Covers a maximum-size video on a sluggish uplink while still killing the
    /// pathological hang that used to leave the spinner going forever. Same
    /// number as the web client's AbortController.
    static let requestTimeout: TimeInterval = 90

    init(
        functions: Functions = .functions(),
        session: URLSession? = nil,
        environment: AppEnvironment = .current
    ) {
        self.functions = functions
        self.environment = environment
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            // An upload must not be answered from a cache, and must not go
            // into one: the response is a one-time asset record.
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func upload(_ item: UploadItem) async throws -> UploadedAsset {
        // Known in advance on a device pointed at a local emulator: the
        // Functions SDK will not put an auth token on a plaintext request to a
        // non-loopback host, so the signature call cannot succeed. Refused with
        // a reason rather than sent and misreported as "sign in again".
        guard environment.supportsCallables else {
            throw UploadError.signatureUnavailable(CallableTransport.unavailable)
        }

        let signature = try await self.signature(for: item.resourceType)
        if signature.maxFileSize > 0 && item.data.count > signature.maxFileSize {
            throw UploadError.tooLarge(limitBytes: signature.maxFileSize, actualBytes: item.data.count)
        }
        return try await send(item, with: signature)
    }

    /// Asks `getCloudinaryUploadSignature` for one upload's credentials.
    func signature(for resourceType: UploadedAsset.ResourceType) async throws -> UploadSignature {
        do {
            // Through `CallableClient`, which owns the `sending` payload rule:
            // a dictionary built inside this actor belongs to it, and handing
            // it straight to the SDK is the data race the compiler refuses.
            let data = try await CallableClient.call(
                Callables.cloudinaryUploadSignature,
                ["resourceType": resourceType.rawValue],
                functions: functions
            )
            guard let signature = UploadSignature(callableResponse: data) else {
                log.error("upload signature came back in an unexpected shape")
                throw UploadError.signatureUnavailable("malformed-signature")
            }
            return signature
        } catch let error as UploadError {
            throw error
        } catch {
            throw Self.mapSignatureError(error)
        }
    }

    private func send(_ item: UploadItem, with signature: UploadSignature) async throws -> UploadedAsset {
        guard let endpoint = signature.uploadEndpoint(for: item.resourceType) else {
            throw UploadError.signatureUnavailable("bad-cloud-name")
        }
        let boundary = "PetNote-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.requestTimeout
        let body = UploadFormBody.multipart(
            fields: signature.formFields,
            fileData: item.data,
            filename: item.filename,
            mimeType: item.mimeType,
            boundary: boundary
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch {
            throw Self.mapTransportError(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            log.error("cloudinary refused the upload: \(http.statusCode)")
            throw UploadError.rejected(status: http.statusCode, message: message)
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secureURL = (payload["secure_url"] as? String).flatMap(URL.init(string:)),
              let publicID = payload["public_id"] as? String, !publicID.isEmpty
        else {
            log.error("cloudinary response was missing secure_url or public_id")
            throw UploadError.malformedResponse
        }

        return UploadedAsset(
            url: secureURL,
            publicID: publicID,
            resourceType: item.resourceType,
            thumbnailURL: item.resourceType == .video ? Self.poster(for: secureURL) : nil
        )
    }

    /// The poster frame stored alongside a video.
    ///
    /// Built with `CloudinaryURL.videoPoster`, the helper the rest of this app
    /// already uses, rather than the web client's hand-rolled string surgery.
    /// The transformation differs — `w_300,h_300,c_fill` here against the web's
    /// `w_400,h_400,c_fill` — and that is deliberate: this is the size ladder
    /// `RemoteImage` and `ImageLoader` key their cache on, so a poster written
    /// here is a poster the native client already has a rendition for. Both are
    /// valid delivery URLs and either client renders either.
    static func poster(for videoURL: URL) -> URL? {
        CloudinaryURL.videoPoster(videoURL, size: .thumbnail)
    }

    static func mapSignatureError(_ error: Error) -> UploadError {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return mapTransportError(error)
        }
        let message = nsError.localizedDescription.lowercased()
        switch code {
        case .unauthenticated:
            // The SDK reports "this build cannot send credentials at all" with
            // the same code as "you are not signed in"; only the message tells
            // them apart, and they need opposite handling.
            return message.contains(CallableTransport.plaintextTokenRefusal)
                ? .signatureUnavailable(CallableTransport.unavailable)
                : .notSignedIn
        case .permissionDenied:
            return .banned
        case .resourceExhausted:
            return .rateLimited
        case .failedPrecondition:
            // The server's words for "Cloudinary secrets are not configured".
            return .signatureUnavailable("server-not-configured")
        default:
            return .signatureUnavailable("functions/\(code.rawValue)")
        }
    }

    static func mapTransportError(_ error: Error) -> UploadError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .transport(nsError.domain) }
        switch nsError.code {
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
             NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return .offline
        default:
            return .transport("url/\(nsError.code)")
        }
    }
}

/// Detail strings carried by the "we could not even ask" errors.
///
/// Lifted from `FirestoreCommentRepository.Transport`, which owns the same two
/// facts for comments. Duplicated rather than shared because that type is
/// nested inside a repository this line does not own; it should collapse into
/// one when `Core/Backend` exists.
enum CallableTransport {
    /// This build cannot reach the callables at all — a device talking to a
    /// local emulator over its LAN address. A **certain** failure and never
    /// retryable: the same build on the same network refuses again every time.
    static let unavailable = "callables-unavailable"
    /// The Functions SDK's own words when it refuses to attach tokens.
    static let plaintextTokenRefusal = "refusing to send auth"
}
