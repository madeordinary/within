import Foundation

public enum NetworkBoundary {
    /// Only the pinned model host and its Hugging Face CDN redirects are allowed.
    /// There is no transcription endpoint or update endpoint in this preview.
    public static func permitsModelDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }
}
