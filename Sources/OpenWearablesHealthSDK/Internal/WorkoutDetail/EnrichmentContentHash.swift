import Foundation

/// The pinned **wire** content-hash recipes for workout-owned detail, schema version 1.
///
/// These are contract, not an implementation detail. The device declares a family hash in
/// its manifest and the server recomputes the same hash from the bytes that actually
/// arrived; a mismatch is reported as `family_hash_mismatch` and nothing is published.
/// The server's copy lives in `app/services/workout_owned_detail/hashing.py` and is
/// canonical — this file mirrors it byte for byte.
///
/// ## What goes into a hash
///
/// Nothing here ever hashes a coordinate or a sample value directly. A chunked family is
/// identified by the SHA-256 checksums of its **uncompressed chunk bodies**, in
/// `chunk_index` order; an inline family is identified by its per-entry content ids. Both
/// sides therefore derive the same digest from the same wire bytes, without either having
/// to reproduce the other's in-memory model.
///
/// This is deliberately *not* ``WorkoutDetailHashing``. That one fingerprints what the
/// reader collected, in a canonical text form that only ever exists on the device; these
/// digests describe what is on the wire.
///
/// ## Domain separation
///
/// Every recipe is prefixed with a version-tagged label, so the hash of one family can
/// never collide with the hash of another and a future schema version can change a recipe
/// without silently matching a v1 digest.
enum EnrichmentContentHash {

    /// Version tag shared by every recipe. Bumping it invalidates every v1 digest.
    static let prefix = "owd1"

    /// `sha256(parts joined by "|")`, lowercase hex — the server's `_digest`.
    static func digest(_ parts: [String]) -> String {
        WorkoutDetailHashing.sha256Hex(parts.joined(separator: "|"))
    }

    /// Identity of one metric stream.
    ///
    /// `sourceKey` is inside the hash because the same metric from a watch and from a
    /// chest strap are different series, not two versions of one.
    static func streamFamily(
        metric: String,
        sourceKey: String,
        pointCount: Int,
        chunkChecksums: [String],
        provenance: [String: Any]? = nil
    ) -> String {
        var parts = [
            "\(prefix):stream",
            metric,
            sourceKey,
            String(pointCount),
            chunkChecksums.joined(separator: ":")
        ]
        if let provenance,
           let data = try? JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys, .withoutEscapingSlashes]),
           let canonical = String(data: data, encoding: .utf8) {
            parts.append(canonical)
        }
        return digest(parts)
    }

    /// Identity of one `HKWorkoutRoute` object, over the chunks that carry it.
    static func routePart(partIndex: Int, pointCount: Int, chunkChecksums: [String]) -> String {
        digest([
            "\(prefix):routepart",
            String(partIndex),
            String(pointCount),
            chunkChecksums.joined(separator: ":")
        ])
    }

    /// Identity of the whole route family, ordered by part index.
    static func routeFamily(pointCount: Int, partHashes: [Int: String]) -> String {
        let ordered = partHashes.keys.sorted()
            .map { "\($0):\(partHashes[$0] ?? "")" }
            .joined(separator: ";")
        return digest(["\(prefix):route", String(pointCount), ordered])
    }

    /// Identity of the recorder event list, in the order the entries are sent.
    static func eventsFamily(contentIDs: [String]) -> String {
        digest(["\(prefix):events", contentIDs.joined(separator: ";")])
    }

    /// Identity of the recorder activity list, in the order the entries are sent.
    static func activitiesFamily(contentHashes: [String]) -> String {
        digest(["\(prefix):activities", contentHashes.joined(separator: ";")])
    }

    /// Identity of a whole generation's content, over the family set this upload declares.
    ///
    /// The server computes the same digest over its *effective* family set — the families
    /// this upload replaced plus the ones carried forward from the previously published
    /// generation. An upload that addresses every family it has produces the same set, and
    /// therefore the same root hash, which is what makes "identical content" detectable: a
    /// replay is published as a no-op rather than as another identical generation.
    ///
    /// Family names are the wire names (`route`, `heart_rate`, `events`, `activities`),
    /// sorted ascending.
    static func root(familyHashes: [String: String]) -> String {
        let ordered = familyHashes.keys.sorted()
            .map { "\($0)=\(familyHashes[$0] ?? "")" }
            .joined(separator: ";")
        return digest(["\(prefix):root", ordered])
    }

    // The server's `hashing.py` also defines `identity_hash_prefix`, the non-reversible
    // tag it puts in logs and outbox payloads. It is deliberately not mirrored here: the
    // device never sends or verifies that value, and its own log handle is the upload-id
    // prefix in `EnrichmentUploadID.logPrefix`.
}
