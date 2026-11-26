import CryptoKit
import Foundation

public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease?.isEmpty == true ? nil : prerelease
    }

    public init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix: Substring
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            withoutPrefix = trimmed.dropFirst()
        } else {
            withoutPrefix = Substring(trimmed)
        }
        guard !withoutPrefix.isEmpty else { return nil }

        let buildStripped = withoutPrefix.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? withoutPrefix
        let preParts = buildStripped.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let corePart = preParts[0]
        let prereleasePart = preParts.count > 1 ? String(preParts[1]) : nil

        let numbers = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count >= 2 && numbers.count <= 3 else { return nil }
        guard
            let major = Int(numbers[0]), major >= 0,
            let minor = Int(numbers[1]), minor >= 0
        else {
            return nil
        }
        let patch: Int
        if numbers.count == 3 {
            guard let parsedPatch = Int(numbers[2]), parsedPatch >= 0 else { return nil }
            patch = parsedPatch
        } else {
            patch = 0
        }
        self.init(major: major, minor: minor, patch: patch, prerelease: prereleasePart)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        if let prerelease {
            return "\(core)-\(prerelease)"
        }
        return core
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(lPre), .some(rPre)):
            return lPre.localizedStandardCompare(rPre) == .orderedAscending
        }
    }
}

public struct GitHubCommitHeadPayload: Decodable, Equatable, Sendable {
    public struct CommitDetail: Decodable, Equatable, Sendable {
        public let message: String
    }

    public let sha: String
    public let htmlURL: String?
    public let commit: CommitDetail

    enum CodingKeys: String, CodingKey {
        case sha
        case htmlURL = "html_url"
        case commit
    }

    public var firstLineMessage: String {
        commit.message
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public struct CommitBuildManifest: Codable, Equatable, Sendable {
    public let repo: String
    public let branch: String
    public let sha: String
    public let shortSHA: String
    public let version: String
    public let commitTitle: String
    public let publishedAt: String
    public let assetName: String
    public let assetURL: String
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case repo
        case branch
        case sha
        case shortSHA = "short_sha"
        case version
        case commitTitle = "commit_title"
        case publishedAt = "published_at"
        case assetName = "asset_name"
        case assetURL = "asset_url"
        case sha256
    }

    public init(
        repo: String,
        branch: String,
        sha: String,
        shortSHA: String,
        version: String,
        commitTitle: String,
        publishedAt: String,
        assetName: String,
        assetURL: String,
        sha256: String
    ) {
        self.repo = repo
        self.branch = branch
        self.sha = sha
        self.shortSHA = shortSHA
        self.version = version
        self.commitTitle = commitTitle
        self.publishedAt = publishedAt
        self.assetName = assetName
        self.assetURL = assetURL
        self.sha256 = sha256
    }
}

public struct CommitUpdateCandidate: Equatable, Sendable {
    public let targetSHA: String
    public let shortSHA: String
    public let version: String
    public let commitTitle: String
    public let downloadURL: URL
    public let expectedSHA256: String?
    public let commitURL: URL

    public init(
        targetSHA: String,
        shortSHA: String,
        version: String,
        commitTitle: String,
        downloadURL: URL,
        expectedSHA256: String?,
        commitURL: URL
    ) {
        self.targetSHA = targetSHA
        self.shortSHA = shortSHA
        self.version = version
        self.commitTitle = commitTitle
        self.downloadURL = downloadURL
        self.expectedSHA256 = expectedSHA256
        self.commitURL = commitURL
    }
}

public enum CommitUpdateResolution: Equatable, Sendable {
    case upToDate(sha: String)
    case buildInProgress(headSHA: String)
    case updateAvailable(CommitUpdateCandidate)
}

public enum CommitUpdateEvaluator {
    public static func normalizeSHA(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              trimmed.count >= 7,
              trimmed.allSatisfy({ $0.isHexDigit })
        else {
            return nil
        }
        return trimmed
    }

    public static func shortSHA(_ sha: String) -> String {
        String(sha.prefix(7))
    }

    public static func isSameCommit(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let a = normalizeSHA(lhs), let b = normalizeSHA(rhs) else { return false }
        if a.count == b.count { return a == b }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    public static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "github.com"
            || host == "api.github.com"
            || host == "objects.githubusercontent.com"
            || host == "release-assets.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func resolve(
        localSHA: String?,
        headCommit: GitHubCommitHeadPayload?,
        manifest: CommitBuildManifest?,
        repository: String
    ) -> CommitUpdateResolution {
        let normalizedLocal = normalizeSHA(localSHA)
        let normalizedHead = normalizeSHA(headCommit?.sha)

        if let normalizedLocal, let normalizedHead, isSameCommit(normalizedLocal, normalizedHead) {
            return .upToDate(sha: normalizedHead)
        }

        if let manifest,
           let manifestSHA = normalizeSHA(manifest.sha),
           let downloadURL = URL(string: manifest.assetURL),
           isTrustedGitHubURL(downloadURL)
        {
            if let normalizedLocal, isSameCommit(normalizedLocal, manifestSHA) {
                if let normalizedHead, !isSameCommit(normalizedHead, manifestSHA) {
                    return .buildInProgress(headSHA: normalizedHead)
                }
                return .upToDate(sha: manifestSHA)
            }

            let commitURL = URL(string: "https://github.com/\(repository)/commit/\(manifestSHA)")
                ?? downloadURL
            let cleanSHA256 = normalizeSHA(manifest.sha256)
            let title = manifest.commitTitle.isEmpty
                ? (headCommit?.firstLineMessage ?? "")
                : manifest.commitTitle
            return .updateAvailable(
                CommitUpdateCandidate(
                    targetSHA: manifestSHA,
                    shortSHA: shortSHA(manifestSHA),
                    version: manifest.version,
                    commitTitle: title,
                    downloadURL: downloadURL,
                    expectedSHA256: cleanSHA256?.count == 64 ? cleanSHA256 : nil,
                    commitURL: commitURL
                )
            )
        }

        if let normalizedHead {
            return .buildInProgress(headSHA: normalizedHead)
        }

        return .upToDate(sha: normalizedLocal ?? "unknown")
    }
}
