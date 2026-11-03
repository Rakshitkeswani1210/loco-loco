import AppKit
import LocoCore
import SwiftUI

/// What the preview window shows: the card for the row or link in `model.preview`, or nothing.
struct PreviewRoot: View {
  let model: Model

  var body: some View {
    if let link = model.link(model.preview) {
      let local = model.localEntry(for: link)
      let own = SnapshotImages.image(for: link.id, taken: link.snapshotAt)
      PreviewCard(
        title: link.title,
        address: link.shortURL + (link.deployedAt.map { " · " + TimeText.short($0) } ?? ""),
        image: own ?? local.flatMap { SnapshotImages.image(for: $0.id, taken: $0.snapshotAt) },
        lists: local.map { e in
          [("Local", [PreviewCard.Line(id: "\(e.port)", port: e.port, name: e.name, trailing: model.isUp(e) ? "Running" : "Stopped")])]
        } ?? [],
        transparent: model.transparent)
        .padding(Metrics.margin)
    } else if let id = model.preview, let row = model.rows.row(id), let entryID = row.entryID, let e = model.history[entryID] {
      let hosted = model.hostedLink(for: e)
      PreviewCard(
        title: e.title ?? row.name,
        address: "localhost:\(row.port)\(e.snapshotPath ?? "")",
        image: SnapshotImages.image(for: entryID, taken: e.snapshotAt),
        lists: [
          ("Needed by", model.neededBy(entryID).map(PreviewCard.Line.init(need:))),
          ("Needs", model.needs(of: entryID).map(PreviewCard.Line.init(need:))),
          ("Hosted", hosted.map { [PreviewCard.Line(id: $0.url, port: nil, name: $0.title, trailing: $0.deployedAt.map { TimeText.short($0) } ?? "")] } ?? []),
        ],
        transparent: model.transparent)
        .padding(Metrics.margin)
    }
  }
}

/// A snapshot of the page, its title and address, then short lists: what it needs, the server or link behind it.
struct PreviewCard: View {
  struct Line: Identifiable {
    let id: String
    let port: UInt16?
    let name: String
    let trailing: String

    init(id: String, port: UInt16?, name: String, trailing: String) {
      self.id = id
      self.port = port
      self.name = name
      self.trailing = trailing
    }

    init(need n: Model.Need) {
      self.init(id: "\(n.port)", port: n.port, name: n.name ?? "", trailing: n.running ? "Running" : "Stopped")
    }
  }

  let title: String
  let address: String
  let image: NSImage?
  let lists: [(String, [Line])]
  let transparent: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: Metrics.snapshotSize.width, height: Metrics.snapshotSize.height, alignment: .topLeading)
          .clipShape(RoundedRectangle(cornerRadius: Metrics.snapshotRadius, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Metrics.snapshotRadius, style: .continuous)
              .strokeBorder(Palette.outerRing, lineWidth: 0.5))
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Palette.label)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(verbatim: address)
          .font(.system(size: 12))
          .monospacedDigit()
          .foregroundStyle(Palette.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .padding(.horizontal, Metrics.previewInset)
      .padding(.top, image == nil ? Metrics.previewInset : 8)
      .padding(.bottom, 2)
      ForEach(lists, id: \.0) { list($0.0, $0.1) }
    }
    .padding(Metrics.padding)
    .frame(width: Metrics.previewWidth, alignment: .leading)
    .background { PanelSurface(transparent: transparent) }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func list(_ title: String, _ items: [Line]) -> some View {
    if !items.isEmpty {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, Metrics.previewInset)
        .frame(height: Metrics.rowHeight, alignment: .center)
      ForEach(items) { n in
        HStack(spacing: 0) {
          if let port = n.port {
            Text(verbatim: "\(port)")
              .monospacedDigit()
              .foregroundStyle(Palette.secondary)
              .fixedSize()
              .frame(minWidth: Metrics.previewPortWidth, alignment: .leading)
              .padding(.trailing, 4)
          }
          Text(n.name)
            .foregroundStyle(Palette.label)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(n.trailing)
            .foregroundStyle(Palette.secondary)
            .padding(.leading, Metrics.trailGap)
        }
        .font(.system(size: 13))
        .padding(.horizontal, Metrics.previewInset)
        .frame(height: Metrics.previewRow)
      }
    }
  }
}

/// Snapshots read from disk once per picture.
@MainActor
enum SnapshotImages {
  private static var cache: [UUID: (taken: Date?, image: NSImage?)] = [:]

  static func image(for id: UUID, taken: Date?) -> NSImage? {
    if let hit = cache[id], hit.taken == taken { return hit.image }
    let image = NSImage(contentsOf: Snapshotter.file(for: id))
    cache[id] = (taken, image)
    return image
  }
}
