import AppKit
import LocoCore
import SwiftUI

/// Frames of rows and buttons in the panel, for the input overlay to hit-test.
struct FrameKey: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue()) { $1 }
  }
}

extension View {
  func frameID(_ id: String) -> some View {
    background {
      GeometryReader { g in
        Color.clear.preference(key: FrameKey.self, value: [id: g.frame(in: .named(PanelRoot.space))])
      }
    }
  }
}

struct PanelRoot: View {
  static let space = "panel"
  let model: Model

  var body: some View {
    let rows = model.rows
    let shape = RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
    Group {
      if model.scrolls {
        ScrollView(.vertical) { content(rows) }
          .scrollIndicators(.automatic)
          .clipShape(shape)
          .frameID("clip")
      } else {
        content(rows)
      }
    }
    .frame(width: Metrics.width)
    .frame(maxHeight: .infinity, alignment: .top)
    .background { PanelSurface(transparent: model.transparent) }
    .padding(Metrics.margin)
    .coordinateSpace(.named(Self.space))
    .onPreferenceChange(FrameKey.self) { frames in
      MainActor.assumeIsolated { model.framesChanged(frames) }
    }
  }

  private func content(_ rows: Rows) -> some View {
    VStack(spacing: 0) {
      GroupHeader(
        title: rows.running.isEmpty ? "Nothing running" : "Running",
        count: rows.running.isEmpty ? nil : rows.running.count
      ) {
        IconButton(symbol: "ellipsis", weight: .medium, hot: model.hot == "menu" || model.moreMenuOpen)
          .frameID("menu")
          .padding(.trailing, -5)
          .accessibilityElement()
          .accessibilityLabel("Options")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { model.perform(.more) }
      }
      if let groups = rows.groups {
        ForEach(groups) { g in
          ProjectHeader(group: g, model: model)
            .padding(.top, g.id == groups.first?.id ? 0 : Metrics.projectGap)
          ForEach(g.rows) { RowView(row: $0, model: model, showProject: false) }
        }
      } else {
        ForEach(rows.running) { RowView(row: $0, model: model) }
      }
      if rows.running.isEmpty {
        SleepingOctopus()
          .stroke(Palette.tertiary, style: StrokeStyle(lineWidth: Metrics.octopusLine, lineCap: .round, lineJoin: .round))
          .frame(height: Metrics.octopusHeight)
          .frame(maxWidth: .infinity)
          .frame(height: Metrics.emptyHeight)
          .accessibilityHidden(true)
      }
      if rows.stoppedTotal > 0 {
        GroupHeader(title: "Stopped", count: rows.stoppedTotal) { EmptyView() }
          .padding(.top, Metrics.groupGap)
        ForEach(rows.stoppedItems) { item in
          switch item {
          case .row(let r):
            RowView(row: r, model: model)
          case .line(let line):
            ProjectLineView(line: line, model: model)
            ForEach(line.rows) { RowView(row: $0, model: model, showProject: false) }
            if line.hidden > 0 {
              MoreRow(id: line.moreID, highlighted: model.highlight == line.moreID, hidden: line.hidden) {
                model.perform(.primary(line.moreID))
              }
            }
          }
        }
        if rows.hasMore {
          MoreRow(id: Rows.more, highlighted: model.highlight == Rows.more, hidden: rows.hiddenServers) {
            model.perform(.primary(Rows.more))
          }
        }
      }
    }
    .padding(Metrics.padding)
  }
}

/// The panel's surface: solid with two hairlines, or glass when Transparent background is on. The preview card shares it.
struct PanelSurface: View {
  let transparent: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
    if transparent {
      PanelMaterial()
        .overlay {
          // Glass draws its own edge.
          if !PanelMaterial.isGlass {
            shape.strokeBorder(Palette.innerRing, lineWidth: 0.5)
              .background(
                RoundedRectangle(cornerRadius: Metrics.radius + 0.5, style: .continuous)
                  .strokeBorder(Palette.outerRing, lineWidth: 0.5)
                  .padding(-0.5))
          }
        }
    } else {
      shape.fill(Palette.surface)
        .overlay(shape.strokeBorder(Palette.innerRing, lineWidth: 0.5))
        .background(
          RoundedRectangle(cornerRadius: Metrics.radius + 0.5, style: .continuous)
            .fill(Palette.outerRing)
            .padding(-0.5))
    }
  }
}

struct GroupHeader<Trailing: View>: View {
  let title: String
  let count: Int?
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 6) {
        Text(title).fontWeight(.semibold)
        if let count { Text(verbatim: "\(count)").monospacedDigit() }
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      trailing
    }
    .font(.system(size: 12))
    .foregroundStyle(Palette.secondary)
    .padding(.horizontal, Metrics.rowInset)
    .frame(height: Metrics.rowHeight)
  }
}

/// A project's tinted label. In rows it stops at a max width and ends in an ellipsis; headers show it whole.
struct ProjectLabel: View {
  let tag: ProjectTag
  var capped = true

  var body: some View {
    let colors = tag.tint.map { Palette.tags[$0 % Palette.tags.count] } ?? Palette.greyTag
    let label = Text(tag.name)
      .font(.system(size: 11, weight: .medium))
      .lineLimit(1)
      .truncationMode(.tail)
      .foregroundStyle(colors.ink)
      .padding(.horizontal, Metrics.tagPadding)
      .frame(height: Metrics.tagHeight)
      .background(RoundedRectangle(cornerRadius: Metrics.tagRadius, style: .continuous).fill(colors.fill))
    if capped { CapWidth(max: Metrics.tagMaxWidth) { label } } else { label.fixedSize() }
  }
}

/// Offers its child no more than a max width and takes the child's own size, unlike `.frame(maxWidth:)`, which grows to the max.
struct CapWidth: Layout {
  let max: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }

  private func capped(_ p: ProposedViewSize) -> ProposedViewSize {
    ProposedViewSize(width: Swift.min(p.width ?? max, max), height: p.height)
  }
}

/// Heads a project's servers when Running is grouped by project. On hover, Stop stops them all.
struct ProjectHeader: View {
  let group: ProjectGroup
  let model: Model

  var body: some View {
    let id = group.headerID
    let canStop = id != nil && group.rows.contains(where: \.canStop)
    let highlighted = id != nil && model.highlight == id && model.menuRow != id
    HStack(spacing: 0) {
      ProjectLabel(tag: group.tag, capped: false)
      Spacer(minLength: 0)
      if highlighted, canStop, let id {
        let button = "btn:\(id):stop"
        IconButton(symbol: RowAction.stop.symbol, size: RowAction.stop.symbolSize, width: Metrics.actionWidth, hot: model.hot == button)
          .frameID(button)
          .padding(.trailing, -5)
      }
    }
    .padding(.horizontal, Metrics.rowInset)
    .frame(height: Metrics.projectHeader)
    .background {
      if highlighted { RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Palette.hover) }
    }
    .modifier(FrameIDIf(id: id.map { "row:" + $0 }))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(group.tag.name)
    .accessibilityAddTraits(.isHeader)
    .accessibilityActions {
      if canStop, let id { Button("Stop all in \(group.tag.name)") { model.perform(.action(id, .stop)) } }
    }
  }
}

private struct FrameIDIf: ViewModifier {
  let id: String?
  func body(content: Content) -> some View {
    if let id { content.frameID(id) } else { content }
  }
}

/// Two or more stopped servers from one project, drawn like a Running project header: its label at the left edge,
/// the count and a chevron after it. Click to list them; on hover, Restart starts them all.
struct ProjectLineView: View {
  let line: ProjectLine
  let model: Model

  var body: some View {
    let highlighted = model.highlight == line.id && model.menuRow != line.id
    HStack(spacing: 0) {
      HStack(spacing: 6) {
        ProjectLabel(tag: line.tag, capped: false)
        Text(verbatim: "\(line.count)").monospacedDigit().font(.system(size: 12)).foregroundStyle(Palette.secondary)
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Palette.secondary)
          .rotationEffect(.degrees(line.open ? 90 : 0))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      ZStack(alignment: .trailing) {
        Color.clear.frame(width: Metrics.trailWidth, height: 0)
        if highlighted {
          let button = "btn:\(line.id):restart"
          IconButton(symbol: RowAction.restart.symbol, size: RowAction.restart.symbolSize, width: Metrics.actionWidth, hot: model.hot == button)
            .frameID(button)
            .padding(.trailing, -5)
        } else {
          Text(TimeText.short(line.time)).monospacedDigit().foregroundStyle(Palette.secondary)
            .frame(height: Metrics.buttonHeight)
        }
      }
      .fixedSize()
      .padding(.leading, Metrics.trailGap)
    }
    .font(.system(size: 13))
    .padding(.horizontal, Metrics.rowInset)
    .frame(height: Metrics.rowHeight)
    .background {
      if highlighted { RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Palette.hover) }
    }
    .frameID("row:" + line.id)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(line.tag.name), \(line.count) stopped servers, \(line.open ? "open" : "closed")")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.perform(.primary(line.id)) }
    .accessibilityActions {
      Button("Restart all in \(line.tag.name)") { model.perform(.action(line.id, .restart)) }
    }
  }
}

struct RowView: View {
  let row: Row
  let model: Model
  /// Off inside a project group, whose header already names it.
  var showProject = true

  var body: some View {
    let highlighted = model.highlight == row.id
    let showButtons = highlighted && model.menuRow != row.id
    HStack(spacing: 0) {
      Text(verbatim: "\(row.port)")
        .monospacedDigit()
        .foregroundStyle(Palette.secondary)
        .frame(width: Metrics.portWidth, alignment: .leading)
      Text(row.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(row.state == .idle ? Palette.label : Palette.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      if showProject, let project = row.project {
        ProjectLabel(tag: project)
          .padding(.leading, Metrics.tagGap)
          .layoutPriority(1)
      }
      // At least the slot's width, so the label stays put when buttons replace the time. Longer text still fits.
      ZStack(alignment: .trailing) {
        Color.clear.frame(width: Metrics.trailWidth, height: 0)
        trailing(showButtons: showButtons).fixedSize()
      }
      .fixedSize()
      .padding(.leading, Metrics.trailGap)
    }
    .font(.system(size: 13))
    .padding(.horizontal, Metrics.rowInset)
    .frame(height: Metrics.rowHeight)
    .background {
      if highlighted {
        RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Palette.hover)
      }
    }
    .frameID("row:" + row.id)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(model.accessibilityDetail(row))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.perform(.primary(row.id)) }
    .accessibilityActions {
      if row.canStop { Button("Stop") { model.perform(.action(row.id, .stop)) } }
      if row.canRestart { Button("Restart") { model.perform(.action(row.id, .restart)) } }
      if row.state == .force { Button("Force stop") { model.perform(.action(row.id, .force)) } }
      if row.hasLog { Button("Show log") { model.perform(.action(row.id, .log)) } }
      if row.canRemove { Button(RowAction.remove.title) { model.perform(.action(row.id, .remove)) } }
      Button("Show menu") { model.perform(.menu(row.id, nil)) }
    }
  }

  @ViewBuilder
  private func trailing(showButtons: Bool) -> some View {
    switch row.state {
    case .stopping, .starting:
      Spinner().frame(height: Metrics.buttonHeight)
    case .queued:
      Text("Queued").foregroundStyle(Palette.secondary).frame(height: Metrics.buttonHeight)
    case .force:
      let id = "btn:\(row.id):force"
      ForceStopButton(hot: model.hot == id).frameID(id)
    case .idle:
      if showButtons, !row.actions.isEmpty {
        HStack(spacing: 2) {
          ForEach(row.actions, id: \.self) { action in
            let id = "btn:\(row.id):\(action.rawValue)"
            IconButton(symbol: action.symbol, size: action.symbolSize, width: Metrics.actionWidth, hot: model.hot == id).frameID(id)
          }
        }
        .padding(.trailing, -5)
      } else if let failure = row.failure {
        Text(failure).foregroundStyle(Palette.red).frame(height: Metrics.buttonHeight)
      } else {
        Text(TimeText.short(row.time)).monospacedDigit().foregroundStyle(Palette.secondary)
          .frame(height: Metrics.buttonHeight)
      }
    }
  }
}

struct MoreRow: View {
  /// `Rows.more` for Stopped, or a project line's More.
  let id: String
  let highlighted: Bool
  let hidden: Int
  let expand: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .medium))
        .frame(width: Metrics.portWidth, alignment: .leading)
      Text("More").frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 13))
    .foregroundStyle(Palette.secondary)
    .padding(.horizontal, Metrics.rowInset)
    .frame(height: Metrics.rowHeight)
    .background {
      if highlighted {
        RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Palette.hover)
      }
    }
    .frameID("row:" + id)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(hidden == 1 ? "More, 1 stopped server" : "More, \(hidden) stopped servers")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { expand() }
  }
}

struct IconButton: View {
  let symbol: String
  var size: CGFloat = 13
  var weight: Font.Weight = .regular
  var width: CGFloat?
  let hot: Bool

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size, weight: weight))
      .foregroundStyle(hot ? Palette.label : Palette.secondary)
      .padding(.horizontal, width == nil ? 5 : 0)
      .frame(width: width, height: Metrics.buttonHeight)
      .background {
        if hot { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.press) }
      }
  }
}

struct ForceStopButton: View {
  let hot: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
    Text("Force stop")
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(Palette.label)
      .padding(.horizontal, 8)
      .frame(height: Metrics.buttonHeight)
      .background {
        shape.fill(Palette.surface)
          .overlay { if hot { shape.fill(Palette.press) } }
          .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(Palette.buttonRing).padding(-0.5))
          .shadow(color: Palette.buttonShadow, radius: 1, y: 1)
      }
  }
}

/// The system's 12-spoke activity indicator, drawn at 14pt like the mockup.
struct Spinner: View {
  var size: CGFloat = 14

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
      let step = Int(context.date.timeIntervalSinceReferenceDate * 12) % 12
      Canvas { g, sz in
        let s = sz.width / 32
        let mid = CGPoint(x: sz.width / 2, y: sz.height / 2)
        for i in 0..<12 {
          var c = g
          c.translateBy(x: mid.x, y: mid.y)
          c.rotate(by: .degrees(Double(step - i) * 30))
          c.translateBy(x: -mid.x, y: -mid.y)
          c.opacity = 1 - Double(i) * 0.068
          let spoke = CGRect(x: 14.4 * s, y: 1.5 * s, width: 3.2 * s, height: 8.6 * s)
          c.fill(Path(roundedRect: spoke, cornerRadius: 1.6 * s), with: .foreground)
        }
      }
      .frame(width: size, height: size)
    }
    .foregroundStyle(Palette.secondary)
    .accessibilityHidden(true)
  }
}

/// The transparent background: Liquid Glass on macOS 26, the menu's blur before it.
struct PanelMaterial: NSViewRepresentable {
  static var isGlass: Bool {
    if #available(macOS 26.0, *) { true } else { false }
  }

  func makeNSView(context: Context) -> NSView {
    if #available(macOS 26.0, *) {
      // Glass casts a faint shadow past its edges. Left in, it fills the window's corners and macOS gives the
      // window a square shadow and outline, so clip it to the panel's shape.
      let clip = NSView()
      clip.wantsLayer = true
      clip.layer?.cornerRadius = Metrics.radius
      clip.layer?.cornerCurve = .continuous
      clip.layer?.masksToBounds = true
      let glass = NSGlassEffectView(frame: clip.bounds)
      glass.cornerRadius = Metrics.radius
      glass.autoresizingMask = [.width, .height]
      clip.addSubview(glass)
      return clip
    }
    let blur = NSVisualEffectView()
    blur.material = .menu
    blur.blendingMode = .behindWindow
    blur.state = .active
    let r = Metrics.radius
    let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
      return true
    }
    mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    mask.resizingMode = .stretch
    blur.maskImage = mask
    return blur
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
