import SwiftUI

// Passive, read-only banners that surface live interactive moments (polls,
// predictions, hype trains, creator goals) for the channel being watched, so
// couch viewers don't miss them. Non-interactive by design: Twitch exposes no
// viewer-side API to vote, and these never take focus or steal input.
extension PlayerView {
  @ViewBuilder
  func interactiveMomentBanner(_ moment: InteractiveMoment) -> some View {
    VStack {
      Group {
        switch moment {
        case .poll(let poll): pollBanner(poll)
        case .prediction(let prediction): predictionBanner(prediction)
        case .hypeTrain(let train): hypeTrainBanner(train)
        case .goal(let goal): goalBanner(goal)
        }
      }
      .frame(maxWidth: 560)
      .padding(.top, 60)
      Spacer()
    }
    .allowsHitTesting(false)
    .ignoresSafeArea()
  }

  // MARK: - Poll

  @ViewBuilder
  private func pollBanner(_ poll: LivePoll) -> some View {
    let ranked = poll.choices.sorted { $0.votes > $1.votes }.prefix(4)
    let leadingID = ranked.first?.id
    momentCard(
      glyph: .chartBar,
      kicker: poll.isActive ? "Live poll" : "Poll results",
      tint: Color(red: 0.65, green: 0.45, blue: 0.95),
      title: poll.title
    ) {
      ForEach(Array(ranked)) { choice in
        MomentBar(
          label: choice.title,
          trailing: Self.percentText(poll.fraction(of: choice)),
          fraction: poll.fraction(of: choice),
          tint: Color(red: 0.65, green: 0.45, blue: 0.95),
          emphasized: choice.id == leadingID)
      }
      Text("\(Self.compact(poll.totalVotes)) votes")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.6))
    }
  }

  // MARK: - Prediction

  @ViewBuilder
  private func predictionBanner(_ prediction: LivePrediction) -> some View {
    momentCard(
      glyph: .chartLine,
      kicker: Self.predictionKicker(prediction.status),
      tint: Color(red: 0.36, green: 0.42, blue: 0.95),
      title: prediction.title
    ) {
      ForEach(prediction.outcomes) { outcome in
        MomentBar(
          label: outcome.title,
          trailing: Self.percentText(prediction.fraction(of: outcome)),
          fraction: prediction.fraction(of: outcome),
          tint: Self.predictionColor(outcome.color),
          emphasized: outcome.id == prediction.winningOutcomeID,
          subtitle: "\(Self.compact(outcome.points)) pts · \(Self.compact(outcome.users)) users")
      }
    }
  }

  // MARK: - Hype train

  @ViewBuilder
  private func hypeTrainBanner(_ train: LiveHypeTrain) -> some View {
    let tint = Color(red: 0.95, green: 0.45, blue: 0.2)
    momentCard(
      glyph: .flame,
      kicker: train.isActive ? "Hype Train" : "Hype Train complete",
      tint: tint,
      title: "Level \(train.level)"
    ) {
      if train.goal > 0 {
        MomentBar(
          label: "Progress",
          trailing: Self.percentText(train.fraction),
          fraction: train.fraction,
          tint: tint,
          emphasized: true)
      }
    }
  }

  // MARK: - Goal

  @ViewBuilder
  private func goalBanner(_ goal: LiveGoal) -> some View {
    let tint = Color(red: 0.2, green: 0.78, blue: 0.55)
    momentCard(
      glyph: .targetArrow,
      kicker: goal.kindLabel,
      tint: tint,
      title: goal.description.isEmpty ? goal.kindLabel : goal.description
    ) {
      MomentBar(
        label: "\(Self.compact(goal.current)) / \(Self.compact(goal.target))",
        trailing: Self.percentText(goal.fraction),
        fraction: goal.fraction,
        tint: tint,
        emphasized: true)
    }
  }

  // MARK: - Shared card

  @ViewBuilder
  private func momentCard<Content: View>(
    glyph: Glyph,
    kicker: String,
    tint: Color,
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Icon(glyph: glyph, size: 26)
          .foregroundStyle(tint)
        Text(kicker.uppercased())
          .font(.caption).bold()
          .tracking(1.2)
          .foregroundStyle(tint)
        Spacer(minLength: 0)
      }
      Text(title)
        .font(.title3).bold()
        .foregroundStyle(.white)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
      VStack(alignment: .leading, spacing: 8) {
        content()
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .strokeBorder(tint.opacity(0.35), lineWidth: 1))
    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
  }

  // MARK: - Formatting helpers

  static func percentText(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
  }

  static func predictionKicker(_ status: LivePrediction.Status) -> String {
    switch status {
    case .active: return "Prediction open"
    case .locked: return "Prediction locked"
    case .resolved: return "Prediction result"
    case .canceled: return "Prediction canceled"
    }
  }

  /// Compact large counts: 2_444_810 → "2.4M", 12_300 → "12.3K".
  static func compact(_ value: Int) -> String {
    let v = Double(value)
    switch abs(value) {
    case 1_000_000...: return trimmed(v / 1_000_000) + "M"
    case 10_000...: return trimmed(v / 1_000) + "K"
    default: return value.formatted(.number.grouping(.automatic))
    }
  }

  private static func trimmed(_ d: Double) -> String {
    let s = String(format: "%.1f", d)
    return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
  }

  static func predictionColor(_ raw: String) -> Color {
    raw.uppercased() == "PINK"
      ? Color(red: 0.93, green: 0.28, blue: 0.6)
      : Color(red: 0.36, green: 0.55, blue: 0.98)
  }
}

/// A labelled horizontal progress bar used inside moment cards.
private struct MomentBar: View {
  let label: String
  let trailing: String
  let fraction: Double
  let tint: Color
  var emphasized: Bool = false
  var subtitle: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
          .font(.subheadline).fontWeight(emphasized ? .semibold : .regular)
          .foregroundStyle(.white)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(trailing)
          .font(.subheadline).bold()
          .foregroundStyle(.white.opacity(0.9))
          .monospacedDigit()
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.14))
          Capsule()
            .fill(tint.opacity(emphasized ? 1 : 0.75))
            .frame(width: max(6, geo.size.width * fraction))
        }
      }
      .frame(height: 8)
      if let subtitle {
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.6))
      }
    }
  }
}
