import AppKit
import LocoCore
import SwiftUI

/// What the preview window shows: the card for the row in `model.preview`, or nothing.
struct PreviewRoot: View {
  let model: Model

  var body: some View {
    if let id = model.preview, let row = model.rows.row(id), let entryID = row.entryID, let e = model.history[entryID] {
      PreviewCard(
        row: row, entry: e, image: SnapshotImages.image(for: entryID, taken: e.snapshotAt),
        needs: model.needs(of: entryID), neededBy: model.neededBy(entryID), transparent: model.transparent)
        .padding(Metrics.margin)
    }
  }
}

/// A snapshot of the page, its title and address, then the servers it needs and the ones that need it.
struct PreviewCard: View {
  let row: Row
  let entry: HistoryEntry
  let image: NSImage?
  let needs: [Model.Need]
  let neededBy: [Model.Need]
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
        Text(entry.title ?? row.name)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Palette.label)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(verbatim: "localhost:\(row.port)\(entry.snapshotPath ?? "")")
          .font(.system(size: 12))
          .monospacedDigit()
          .foregroundStyle(Palette.secondary)
      }
      .padding(.horizontal, Metrics.previewInset)
      .padding(.top, image == nil ? Metrics.previewInset : 8)
      .padding(.bottom, 2)
      list("Needed by", neededBy)
      list("Needs", needs)
    }
    .padding(Metrics.padding)
    .frame(width: Metrics.previewWidth, alignment: .leading)
    .background { PanelSurface(transparent: transparent) }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func list(_ title: String, _ items: [Model.Need]) -> some View {
    if !items.isEmpty {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, Metrics.previewInset)
        .frame(height: Metrics.rowHeight, alignment: .center)
      ForEach(items) { n in
        HStack(spacing: 0) {
          Text(verbatim: "\(n.port)")
            .monospacedDigit()
            .foregroundStyle(Palette.secondary)
            .fixedSize()
            .frame(minWidth: Metrics.previewPortWidth, alignment: .leading)
            .padding(.trailing, 4)
          Text(n.name ?? "")
            .foregroundStyle(Palette.label)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(n.running ? "Running" : "Stopped")
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
