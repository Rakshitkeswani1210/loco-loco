import Foundation

/// Finds servers and links by what's typed in the panel's search field. Every word has to be found somewhere,
/// in any order, ignoring case and accents. A port matches from its start, so "88" finds 8841.
public enum Search {
  public struct Fields: Sendable {
    public var name: String
    public var ports: [UInt16]
    public var project: String?
    public var folder: String
    public var command: String
    public var title: String?

    public init(name: String, ports: [UInt16] = [], project: String? = nil, folder: String = "", command: String = "", title: String? = nil) {
      self.name = name
      self.ports = ports
      self.project = project
      self.folder = folder
      self.command = command
      self.title = title
    }
  }

  public struct Match: Equatable, Sendable {
    /// Lower is better: the name or port first, then the project, the page title, and last the folder or command.
    public let rank: Int
    /// The page title explains this match and the name doesn't, so a row shows the title instead of "v1".
    public let showsTitle: Bool
  }

  public static func words(_ query: String) -> [String] {
    fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
  }

  /// How `fields` matches `words`, or nil when a word isn't found.
  public static func match(_ f: Fields, words: [String]) -> Match? {
    guard !words.isEmpty else { return nil }
    let name = fold(f.name)
    let project = fold(f.project ?? "")
    let title = fold(f.title ?? "")
    let rest = fold(f.folder + "\n" + f.command)
    let ports = f.ports.map(String.init)

    func inName(_ w: String) -> Bool { name.contains(w) || ports.contains { $0.hasPrefix(w) } }
    func inLabel(_ w: String) -> Bool { inName(w) || project.contains(w) }
    guard words.allSatisfy({ inLabel($0) || title.contains($0) || rest.contains($0) }) else { return nil }

    let rank: Int
    if words.allSatisfy(inName) {
      rank = name.hasPrefix(words[0]) || ports.contains(words[0]) ? 0 : 1
    } else if words.allSatisfy(inLabel) {
      rank = 2
    } else if words.allSatisfy({ inLabel($0) || title.contains($0) }) {
      rank = 3
    } else {
      rank = 4
    }
    return Match(rank: rank, showsTitle: words.contains { !inLabel($0) && title.contains($0) })
  }

  private static func fold(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}
