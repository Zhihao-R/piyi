import Foundation

/// Model capabilities extraction needs. The library module can't call the intelligence module, so this only states what's needed; the app hands in the intelligence module's implementation at launch
public protocol ExtractionModels: Sendable {
    /// Whether what was fetched is real content, or a login, error, or empty shell page. nil means it can't tell (no usable provider), and rules take over
    func verdict(on page: PageGlance) async -> PageVerdict?
    /// Layer 5 model fallback: when the earlier layers are unsure, have the model pick out the title and body from the page text. Returns nil if it can't
    func rescue(_ page: PageGlance) async -> (title: String?, body: String)?
    /// Body completion: turn video and audio files into timed lines of text. Returns nil if it can't
    func transcribe(_ file: URL) async -> [Cue]?
}

/// The page shown to the model: URL, title, and the text on the page
public struct PageGlance: Sendable {
    public var url: URL
    public var title: String?
    public var text: String
}

public enum PageVerdict: String, Sendable {
    case content, login, error, empty
}
