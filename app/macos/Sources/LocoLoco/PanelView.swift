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
    .background {
      shape.fill(Palette.surface)
        .overlay(shape.strokeBorder(Palette.innerRing, lineWidth: 0.5))
        .background(
          RoundedRectangle(cornerRadius: Metrics.radius + 0.5, style: .continuous)
            .fill(Palette.outerRing)
            .padding(-0.5))
    }
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
          ProjectHeader(tag: g.tag)
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
        ForEach(rows.stopped) { RowView(row: $0, model: model) }
        if rows.hasMore {
          MoreRow(highlighted: model.highlight == Rows.more, hidden: rows.stoppedTotal - rows.stopped.count) {
            model.perform(.primary(Rows.more))
          }
        }
      }
    }
    .padding(Metrics.padding)
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

/// Heads a project's servers when Running is grouped by project.
struct ProjectHeader: View {
  let tag: ProjectTag

  var body: some View {
    HStack(spacing: 0) {
      ProjectLabel(tag: tag, capped: false)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Metrics.rowInset)
    .frame(height: Metrics.projectHeader)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tag.name)
    .accessibilityAddTraits(.isHeader)
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
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { model.perform(.primary(row.id)) }
    .accessibilityActions {
      if row.canStop { Button("Stop") { model.perform(.action(row.id, .stop)) } }
      if row.canRestart { Button("Restart") { model.perform(.action(row.id, .restart)) } }
      if row.state == .force { Button("Force stop") { model.perform(.action(row.id, .force)) } }
      if row.hasLog { Button("Show log") { model.perform(.action(row.id, .log)) } }
      Button("Show menu") { model.perform(.menu(row.id, nil)) }
    }
  }

  @ViewBuilder
  private func trailing(showButtons: Bool) -> some View {
    switch row.state {
    case .stopping, .starting:
      Spinner().frame(height: Metrics.buttonHeight)
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
    .frameID("row:" + Rows.more)
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
