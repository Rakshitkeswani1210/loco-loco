import Foundation

/// A demo hosted on the web. Found from Rayfin's deploy files, or added by hand.
public struct HostedLink: Codable, Sendable, Identifiable, Hashable {
  /// Names the link's snapshot. The URL is what makes two links the same.
  public var id = UUID()
  public var url: String
  public var name: String
  /// The name you chose, which a new deploy leaves alone.
  public var customName: String?
  /// The project that deploys it. Kept when the folder goes.
  public var folder: String?
  public var deployedAt: Date?
  /// The item in Fabric.
  public var fabricLink: String?
  /// Local ports from `rayfin.yml`.
  public var ports: [UInt16]?
  public var hidden: Bool?
  /// The built site inside `folder`, from `rayfin.yml`, which the card's snapshot comes from.
  public var buildFolder: String?
  public var snapshotAt: Date?

  public var title: String { customName ?? name }
  /// "brave-otter-12ab34cd56…example.net", without the region in the middle.
  public var shortURL: String {
    guard let host = URL(string: url)?.host else { return url }
    let parts = host.split(separator: ".")
    guard host.count > 40, parts.count > 1, let label = parts.first else { return host }
    return "\(label.split(separator: "-").dropLast().joined(separator: "-"))…\(parts.suffix(2).joined(separator: "."))"
  }

  public init(url: String, name: String, folder: String? = nil) {
    self.url = url
    self.name = name
    self.folder = folder
  }
}

/// Reads Rayfin's files. Only the fields below: never `rayfin/.env`, `~/.rayfin/auth.json` or the keys in `.deployments.json`.
public enum Hosted {
  static let skipped: Set<String> = ["node_modules", ".git", ".next", "dist", "build", "out", ".venv", "venv", "__pycache__", "Library"]
  /// Vite's defaults, which nearly every rayfin.yml lists. They say nothing about which server it is.
  public static let genericPorts: Set<UInt16> = [5173, 5174]

  private struct File: Decodable {
    struct Deployment: Decodable {
      var hostingUrl: String?
      var fabricDeepLink: String?
      var deployedAt: String?
    }
    var deployments: [String: Deployment]
  }

  private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// The links in one project's `.deployments.json` and `rayfin.yml`. Deployments with no URL are skipped.
  public static func links(deployments: Data, yaml: String, folder: String) -> [HostedLink] {
    guard let file = try? JSONDecoder().decode(File.self, from: deployments) else { return [] }
    let name = value("name", in: yaml) ?? value("id", in: yaml) ?? (folder as NSString).lastPathComponent
    let ports = Needs.ports(in: yaml).reduce(into: [UInt16]()) { if !$0.contains($1) { $0.append($1) } }
    let build = yaml.range(of: #"(?m)^\s+folder:\s*\S+"#, options: .regularExpression).map {
      yaml[$0].split(separator: ":")[1].trimmingCharacters(in: .whitespaces)
    }
    return file.deployments.values.compactMap { d in
      guard let url = d.hostingUrl, !url.isEmpty else { return nil }
      var link = HostedLink(url: url, name: name, folder: folder)
      link.fabricLink = d.fabricDeepLink
      link.deployedAt = d.deployedAt.flatMap { try? dateStyle.parse($0) }
      link.ports = ports
      link.buildFolder = build
      return link
    }
  }

  /// A top-level `key: value` in YAML.
  static func value(_ key: String, in yaml: String) -> String? {
    for line in yaml.split(separator: "\n") where line.hasPrefix(key + ":") {
      let v = line.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'\t\r"))
      if !v.isEmpty { return v }
    }
    return nil
  }

  /// The links in one project folder.
  public static func read(folder: String) -> [HostedLink] {
    guard let data = FileManager.default.contents(atPath: folder + "/rayfin/.deployments.json") else { return [] }
    let yaml = (try? String(contentsOfFile: folder + "/rayfin/rayfin.yml", encoding: .utf8)) ?? ""
    return links(deployments: data, yaml: yaml, folder: folder)
  }

  /// Every project under a folder with a deploy file. Takes a few seconds, so never on the main thread.
  public static func find(under root: String) -> [HostedLink] {
    guard let walk = FileManager.default.enumerator(
      at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]
    ) else { return [] }
    var out: [HostedLink] = []
    for case let url as URL in walk {
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
      if skipped.contains(url.lastPathComponent) { walk.skipDescendants(); continue }
      if url.lastPathComponent == "rayfin" {
        out += read(folder: url.deletingLastPathComponent().path)
        walk.skipDescendants()
      }
    }
    return out
  }

  /// Adds what was found to the saved list. One link per URL, the newest deploy wins. Saved links that weren't found stay,
  /// so a link outlives its folder. A new deploy brings back a hidden link.
  public static func merge(saved: [HostedLink], found: [HostedLink]) -> [HostedLink] {
    var out = saved
    let newest: (HostedLink, HostedLink) -> Bool = { ($0.deployedAt ?? .distantPast) > ($1.deployedAt ?? .distantPast) }
    for f in found.sorted(by: newest).reversed() {
      guard let i = out.firstIndex(where: { $0.url == f.url }) else { out.append(f); continue }
      if let was = out[i].deployedAt, let now = f.deployedAt, now < was { continue }
      if let was = out[i].deployedAt, let now = f.deployedAt, now > was { out[i].hidden = nil }
      out[i].name = f.name
      out[i].folder = f.folder
      out[i].deployedAt = f.deployedAt ?? out[i].deployedAt
      out[i].fabricLink = f.fabricLink ?? out[i].fabricLink
      out[i].ports = f.ports
      out[i].buildFolder = f.buildFolder
    }
    return out
  }

  // MARK: File

  public static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Loco Loco/links.json")
  }

  public static func load(from url: URL = defaultURL) -> [HostedLink] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { try dateStyle.parse($0.singleValueContainer().decode(String.self)) }
    return (try? decoder.decode([HostedLink].self, from: data)) ?? []
  }

  public static func save(_ links: [HostedLink], to url: URL = defaultURL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(dateStyle.format(date))
    }
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(links).write(to: url, options: .atomic)
  }
}
