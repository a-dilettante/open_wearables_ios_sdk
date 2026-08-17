import Foundation

// MARK: - Wire outcomes

/// Which request in the upload sequence produced a response.
enum EnrichmentUploadPhase: String {
    case manifest
    case chunk
    case complete
    case receipt
    case tombstone
}

/// What a response means for the pipeline. Deliberately coarse and low-cardinality:
/// these values reach telemetry, so they must never carry a server message that could
/// quote health data or an identifier.
enum EnrichmentUploadOutcome: Equatable {
    case accepted
    /// 404 — the server feature flag is off. Not an error and never a dead letter: the
    /// durable state is kept and retried with backoff until the flag turns on.
    case featureUnavailable
    case unauthorized
    /// 409 on the manifest — a different manifest already claimed this upload id.
    /// Retrying cannot resolve it.
    case manifestConflict
    /// 409 on a chunk — the content changed underneath this upload. The upload is
    /// re-derived from a fresh read, which produces a new root hash and a new upload id.
    case chunkConflict
    case transient(String)
    case permanent(String)

    /// Low-cardinality label for telemetry and `lastErrorClass`.
    var errorClass: String? {
        switch self {
        case .accepted: return nil
        case .featureUnavailable: return "flag_off"
        case .unauthorized: return "unauthorized"
        case .manifestConflict: return "manifest_conflict"
        case .chunkConflict: return "content_changed"
        case .transient(let value): return value
        case .permanent(let value): return value
        }
    }
}

// MARK: - Uploader

/// Drives one staged upload through manifest → chunks → complete → receipt.
///
/// The driver is a re-entrant state machine rather than a linear async sequence: chunk
/// transfers run on the shared background `URLSession` and can finish minutes later, in
/// a different process launch. `advance(uploadID:)` is therefore idempotent and simply
/// performs whatever step the durable index says is next.
final class EnrichmentUploader {

    private unowned let sdk: OpenWearablesHealthSDK
    private let outbox: EnrichmentOutbox

    /// Prefix that routes a background task back here without exposing anything.
    static let taskPrefix = "enrich"

    init(sdk: OpenWearablesHealthSDK, outbox: EnrichmentOutbox) {
        self.sdk = sdk
        self.outbox = outbox
    }

    // MARK: - Pure: classification

    static func classify(statusCode: Int, phase: EnrichmentUploadPhase) -> EnrichmentUploadOutcome {
        if (200...299).contains(statusCode) { return .accepted }

        switch statusCode {
        case 401, 403:
            return .unauthorized
        case 404:
            // Every route answers 404 while `workout_owned_detail_ingest_enabled` is
            // false. A tombstone for an unknown workout is *not* a 404 — the server
            // reports that as 200 `not_found` — so a 404 here is always the flag.
            return .featureUnavailable
        case 409:
            return phase == .manifest ? .manifestConflict : .chunkConflict
        case 413:
            return .permanent("payload_too_large")
        case 422:
            return .permanent("validation_failed")
        case 400...499:
            return .permanent("http_4xx")
        case 500...599:
            return .transient("http_5xx")
        default:
            return .transient("no_response")
        }
    }

    /// Exponential backoff, capped. Deterministic so a test can assert the schedule.
    static func backoff(attempt: Int) -> TimeInterval {
        let clamped = max(0, min(attempt, 12))
        return min(30 * pow(2, Double(clamped)), 6 * 3600)
    }

    // MARK: - Pure: state transitions

    /// Applies a non-terminal outcome to a job.
    ///
    /// This function cannot produce `published` or `noop` for any phase — those states
    /// exist only in `applyReceipt`. A 2xx on a manifest or a chunk means bytes were
    /// accepted, which is not the same as a committed generation.
    static func apply(
        outcome: EnrichmentUploadOutcome,
        phase: EnrichmentUploadPhase,
        to job: EnrichmentJob,
        now: Date = Date()
    ) -> EnrichmentJob {
        var updated = job
        updated.updatedAt = now
        updated.lastErrorClass = outcome.errorClass

        switch outcome {
        case .accepted:
            updated.attemptCount = 0
            updated.nextAttemptAt = nil
            updated.state = phase == .complete ? .awaitingReceipt : .uploading

        case .featureUnavailable, .transient, .unauthorized:
            // Authorization recovery is owned by the SDK's token-refresh path; the job
            // itself simply stays retryable.
            updated.attemptCount += 1
            updated.nextAttemptAt = now.addingTimeInterval(backoff(attempt: updated.attemptCount))
            updated.state = .deferred

        case .manifestConflict, .permanent:
            updated.state = .failedPermanent
            updated.nextAttemptAt = nil

        case .chunkConflict:
            // Re-derive from a fresh read: new content means a new root hash and a new
            // upload id, so the staged upload is abandoned rather than repaired.
            updated.state = .pending
            updated.uploadID = nil
            updated.rootHash = nil
            updated.attemptCount += 1
            updated.nextAttemptAt = now
        }

        return updated
    }

    /// The only path to a terminal published state.
    static func applyReceipt(
        state: String,
        generationNumber: Int?,
        failureReason: String?,
        routeAvailability: WorkoutDetailAvailability?,
        to job: EnrichmentJob,
        now: Date = Date()
    ) -> EnrichmentJob {
        var updated = job
        updated.updatedAt = now

        switch state {
        case "published", "noop":
            updated.state = state == "published" ? .published : .noop
            updated.generationNumber = generationNumber
            updated.lastErrorClass = nil
            updated.attemptCount = 0
            updated.nextAttemptAt = nil
            if let routeAvailability {
                updated.routeAvailabilityAtLastPublish = routeAvailability.rawValue
            }

        case "failed":
            updated.state = .failedPermanent
            // `failure_reason` is a server string; only its presence is recorded, never
            // its content, which could quote validated payload.
            updated.lastErrorClass = failureReason == nil ? "publish_failed" : "publish_rejected"
            updated.nextAttemptAt = nil

        default:
            // staging / validating — still in flight, ask again later.
            updated.state = .awaitingReceipt
            updated.attemptCount += 1
            updated.nextAttemptAt = now.addingTimeInterval(backoff(attempt: updated.attemptCount))
        }

        return updated
    }

    // MARK: - Pure: URLs

    static func uploadsBase(apiBaseURL: String, userID: String) -> String {
        "\(apiBaseURL)/sdk/users/\(userID)/\(EnrichmentWire.basePathComponent)"
    }

    static func manifestURL(apiBaseURL: String, userID: String, uploadID: String) -> URL? {
        URL(string: "\(uploadsBase(apiBaseURL: apiBaseURL, userID: userID))/uploads/\(uploadID)")
    }

    static func chunkURL(
        apiBaseURL: String,
        userID: String,
        uploadID: String,
        record: EnrichmentChunkRecord
    ) -> URL? {
        var path = "\(uploadsBase(apiBaseURL: apiBaseURL, userID: userID))"
            + "/uploads/\(uploadID)/chunks/\(record.family)/\(record.chunkIndex)"
        if let partIndex = record.partIndex { path += "?part_index=\(partIndex)" }
        return URL(string: path)
    }

    static func completeURL(apiBaseURL: String, userID: String, uploadID: String) -> URL? {
        URL(string: "\(uploadsBase(apiBaseURL: apiBaseURL, userID: userID))/uploads/\(uploadID)/complete")
    }

    static func tombstonesURL(apiBaseURL: String, userID: String) -> URL? {
        URL(string: "\(uploadsBase(apiBaseURL: apiBaseURL, userID: userID))/tombstones")
    }

    /// `enrich|<8 hex of upload id>|<file name>`.
    ///
    /// Carries no absolute path, no user id, no workout identity, and no coordinate —
    /// task descriptions are visible in system state and survive in crash reports.
    static func taskDescription(uploadID: String, fileName: String) -> String {
        "\(taskPrefix)|\(EnrichmentUploadID.logPrefix(uploadID))|\(fileName)"
    }

    static func parseTaskDescription(_ description: String) -> (uploadIDPrefix: String, fileName: String)? {
        let parts = description.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == taskPrefix else { return nil }
        return (parts[1], parts[2])
    }

    // MARK: - Driver

    /// Performs the next step for one upload. Safe to call repeatedly.
    func advance(uploadID: String, identityKey: String) {
        guard let index = outbox.loadIndex(uploadID: uploadID) else { return }

        if !index.isManifestAccepted {
            putManifest(uploadID: uploadID, identityKey: identityKey)
            return
        }

        let pending = index.pendingChunks
        if !pending.isEmpty {
            enqueueChunks(pending, uploadID: uploadID)
            return
        }

        if !index.isCompleteRequested {
            postComplete(uploadID: uploadID, identityKey: identityKey)
            return
        }

        getReceipt(uploadID: uploadID, identityKey: identityKey)
    }

    // MARK: Manifest

    private func putManifest(uploadID: String, identityKey: String) {
        guard let context = requestContext(),
              let url = Self.manifestURL(apiBaseURL: context.base, userID: context.userID, uploadID: uploadID),
              let body = try? Data(contentsOf: outbox.manifestURL(uploadID)) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sdk.applyAuth(to: &request, credential: context.credential)
        request.httpBody = body

        send(request, phase: .manifest, uploadID: uploadID, identityKey: identityKey) { [weak self] json in
            guard let self else { return }
            self.outbox.updateIndex(uploadID: uploadID) { $0.isManifestAccepted = true }

            // The server may answer the manifest itself with a terminal state when this
            // exact content is already published; honour it instead of re-uploading.
            if let state = json?["state"] as? String, state == "published" || state == "noop" {
                self.finishFromReceipt(json: json, uploadID: uploadID, identityKey: identityKey)
                return
            }
            self.advance(uploadID: uploadID, identityKey: identityKey)
        }
    }

    // MARK: Chunks

    /// Chunk bodies go through the shared background session from files, so a suspended
    /// or terminated app still finishes the transfer.
    private func enqueueChunks(_ records: [EnrichmentChunkRecord], uploadID: String) {
        guard let context = requestContext() else { return }
        let directory = outbox.uploadDirectory(uploadID)

        sdk.session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let inFlight = Set(tasks.compactMap { $0.taskDescription })

            for record in records {
                let description = Self.taskDescription(uploadID: uploadID, fileName: record.fileName)
                guard !inFlight.contains(description) else { continue }
                guard let url = Self.chunkURL(
                    apiBaseURL: context.base,
                    userID: context.userID,
                    uploadID: uploadID,
                    record: record
                ) else { continue }

                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(EnrichmentWire.gzipEncoding, forHTTPHeaderField: EnrichmentWire.contentEncodingHeader)
                request.setValue(record.checksum, forHTTPHeaderField: EnrichmentWire.checksumHeader)
                request.setValue("\(record.uncompressedBytes)", forHTTPHeaderField: EnrichmentWire.uncompressedBytesHeader)
                self.sdk.applyAuth(to: &request, credential: context.credential)

                let task = self.sdk.session.uploadTask(
                    with: request,
                    fromFile: directory.appendingPathComponent(record.fileName)
                )
                task.taskDescription = description
                task.resume()
            }
        }
    }

    /// Called by the URL-session delegate when a background chunk task finishes.
    func handleBackgroundChunkCompletion(taskDescription: String, statusCode: Int, hadTransportError: Bool) {
        guard let parsed = Self.parseTaskDescription(taskDescription),
              let uploadID = outbox.uploadID(matchingPrefix: parsed.uploadIDPrefix),
              let index = outbox.loadIndex(uploadID: uploadID) else { return }

        let identityKey = index.identityKey

        // A transport error is not a server verdict; the file stays staged and the next
        // pass re-enqueues it.
        if hadTransportError {
            updateJob(identityKey: identityKey) {
                Self.apply(outcome: .transient("network"), phase: .chunk, to: $0)
            }
            return
        }

        let outcome = Self.classify(statusCode: statusCode, phase: .chunk)
        switch outcome {
        case .accepted:
            outbox.markChunkUploaded(uploadID: uploadID, fileName: parsed.fileName)
            updateJob(identityKey: identityKey) { Self.apply(outcome: .accepted, phase: .chunk, to: $0) }
            advance(uploadID: uploadID, identityKey: identityKey)

        case .unauthorized:
            updateJob(identityKey: identityKey) { Self.apply(outcome: outcome, phase: .chunk, to: $0) }
            refreshTokenThenRetry(uploadID: uploadID, identityKey: identityKey)

        case .chunkConflict, .manifestConflict, .permanent:
            // Either the content moved on or the server will never accept these bytes.
            // Drop the staging area; the coordinator re-reads when appropriate.
            updateJob(identityKey: identityKey) { Self.apply(outcome: outcome, phase: .chunk, to: $0) }
            outbox.remove(uploadID: uploadID)

        case .featureUnavailable, .transient:
            // Keep every staged file: this is retried, never dead-lettered.
            updateJob(identityKey: identityKey) { Self.apply(outcome: outcome, phase: .chunk, to: $0) }
        }
    }

    // MARK: Complete and receipt

    private func postComplete(uploadID: String, identityKey: String) {
        guard let context = requestContext(),
              let url = Self.completeURL(apiBaseURL: context.base, userID: context.userID, uploadID: uploadID) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sdk.applyAuth(to: &request, credential: context.credential)

        send(request, phase: .complete, uploadID: uploadID, identityKey: identityKey) { [weak self] json in
            guard let self else { return }
            self.outbox.updateIndex(uploadID: uploadID) { $0.isCompleteRequested = true }
            self.finishFromReceipt(json: json, uploadID: uploadID, identityKey: identityKey)
        }
    }

    private func getReceipt(uploadID: String, identityKey: String) {
        guard let context = requestContext(),
              let url = Self.manifestURL(apiBaseURL: context.base, userID: context.userID, uploadID: uploadID) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        sdk.applyAuth(to: &request, credential: context.credential)

        send(request, phase: .receipt, uploadID: uploadID, identityKey: identityKey) { [weak self] json in
            self?.finishFromReceipt(json: json, uploadID: uploadID, identityKey: identityKey)
        }
    }

    /// Applies a terminal publication receipt — the only place a job becomes published.
    private func finishFromReceipt(json: [String: Any]?, uploadID: String, identityKey: String) {
        guard let state = json?["state"] as? String else { return }

        let generation = json?["generation_number"] as? Int
        let failureReason = json?["failure_reason"] as? String
        let routeAvailability = stagedRouteAvailability(uploadID: uploadID)

        let job = updateJob(identityKey: identityKey) {
            Self.applyReceipt(
                state: state,
                generationNumber: generation,
                failureReason: failureReason,
                routeAvailability: routeAvailability,
                to: $0
            )
        }

        if let job, job.isTerminal {
            // Staged files exist only to reach a receipt; once one arrives they are
            // health data with no remaining purpose.
            outbox.remove(uploadID: uploadID)
        }
    }

    /// The route availability this upload represents, so reconciliation knows whether to
    /// keep watching this workout.
    ///
    /// Read from the durable index rather than the manifest: a route that has not
    /// arrived is deliberately *omitted* from the manifest so the server cannot mistake
    /// an empty read for a deletion, which leaves the manifest unable to express it.
    private func stagedRouteAvailability(uploadID: String) -> WorkoutDetailAvailability? {
        outbox.loadIndex(uploadID: uploadID).flatMap { WorkoutDetailAvailability(rawValue: $0.routeAvailability) }
    }

    // MARK: Tombstones

    /// Posts one tombstone. Idempotent server-side: a repeat answers `not_found`, which
    /// is success for the device.
    func sendTombstone(identityKey: String, tombstone: EnrichmentTombstone) {
        guard let context = requestContext(),
              let url = Self.tombstonesURL(apiBaseURL: context.base, userID: context.userID),
              let body = try? JSONSerialization.data(
                  withJSONObject: tombstone.identity.tombstoneObject(deletedAt: tombstone.deletedAt)
              ) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sdk.applyAuth(to: &request, credential: context.credential)
        request.httpBody = body

        let userKey = sdk.userKey()
        sdk.foregroundSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = error != nil
                ? EnrichmentUploadOutcome.transient("network")
                : Self.classify(statusCode: statusCode, phase: .tombstone)

            self.sdk.enrichmentCheckpoint.mutate(userKey: userKey) { state in
                guard var stored = state.tombstones[identityKey] else { return }
                switch outcome {
                case .accepted:
                    // `deleted` or `not_found` — either way nothing of this workout
                    // remains to publish or to track.
                    state.tombstones.removeValue(forKey: identityKey)
                    state.jobs.removeValue(forKey: identityKey)
                case .manifestConflict, .permanent:
                    state.tombstones.removeValue(forKey: identityKey)
                default:
                    stored.attemptCount += 1
                    stored.lastErrorClass = outcome.errorClass
                    stored.nextAttemptAt = Date().addingTimeInterval(Self.backoff(attempt: stored.attemptCount))
                    state.tombstones[identityKey] = stored
                }
            }
        }.resume()
    }

    // MARK: - Transport plumbing

    private struct RequestContext {
        let base: String
        let userID: String
        let credential: String
    }

    private func requestContext() -> RequestContext? {
        guard let base = sdk.apiBaseUrl, let userID = sdk.userId, let credential = sdk.authCredential else { return nil }
        return RequestContext(base: base, userID: userID, credential: credential)
    }

    /// Small JSON request/response through the foreground session. Manifest, complete,
    /// and receipt bodies are tiny and their contents drive the state machine, so they
    /// are not background transfers; the durable index means a lost one simply repeats.
    private func send(
        _ request: URLRequest,
        phase: EnrichmentUploadPhase,
        uploadID: String,
        identityKey: String,
        onAccepted: @escaping ([String: Any]?) -> Void
    ) {
        sdk.foregroundSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if error != nil {
                self.updateJob(identityKey: identityKey) {
                    Self.apply(outcome: .transient("network"), phase: phase, to: $0)
                }
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = Self.classify(statusCode: statusCode, phase: phase)

            switch outcome {
            case .accepted:
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                self.updateJob(identityKey: identityKey) { Self.apply(outcome: .accepted, phase: phase, to: $0) }
                onAccepted(json)

            case .unauthorized:
                self.updateJob(identityKey: identityKey) { Self.apply(outcome: outcome, phase: phase, to: $0) }
                self.refreshTokenThenRetry(uploadID: uploadID, identityKey: identityKey)

            case .manifestConflict, .permanent, .chunkConflict:
                self.updateJob(identityKey: identityKey) { Self.apply(outcome: outcome, phase: phase, to: $0) }
                self.outbox.remove(uploadID: uploadID)

            case .featureUnavailable, .transient:
                self.updateJob(identityKey: identityKey) { Self.apply(outcome: outcome, phase: phase, to: $0) }
            }
        }.resume()
    }

    /// Reuses the SDK's existing single-flight token refresh.
    private func refreshTokenThenRetry(uploadID: String, identityKey: String) {
        guard !sdk.isApiKeyAuth else {
            sdk.emitAuthError(statusCode: 401)
            return
        }
        sdk.attemptTokenRefresh { [weak self] result in
            guard let self, case .success = result else { return }
            self.advance(uploadID: uploadID, identityKey: identityKey)
        }
    }

    @discardableResult
    private func updateJob(
        identityKey: String,
        _ transform: (EnrichmentJob) -> EnrichmentJob
    ) -> EnrichmentJob? {
        sdk.enrichmentCheckpoint.mutate(userKey: sdk.userKey()) { state in
            guard let existing = state.jobs[identityKey] else { return nil }
            let updated = transform(existing)
            state.jobs[identityKey] = updated
            return updated
        }
    }
}
