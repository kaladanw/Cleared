import SwiftUI
import UIKit

private enum LabelPalette {
    static let muslin = Color(red: 0.957, green: 0.941, blue: 0.902)
    static let ink = Color(red: 0.11, green: 0.14, blue: 0.20)
    static let soft = Color(red: 0.35, green: 0.38, blue: 0.46)
    static let thread = Color(red: 0.82, green: 0.21, blue: 0.16)
    static let green = Color(red: 0.23, green: 0.49, blue: 0.36)
    static let line = Color(red: 0.78, green: 0.74, blue: 0.66)
}

struct CareLabelView: View {
    let report: CheckReport

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VerdictSection(verdict: report.verdict)
                LabelDivider()
                PriceSection(facts: report.listingFacts, price: report.priceRead)

                if hasTrustContent {
                    LabelDivider()
                    TrustSection(trust: report.listingTrust)
                }

                if report.authFlag.applicable {
                    LabelDivider()
                    AuthSection(flag: report.authFlag)
                }

                LabelDivider()
                FactsSection(facts: report.listingFacts)
            }
            .padding(22)
            .background(LabelPalette.muslin)
            .foregroundStyle(LabelPalette.ink)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(LabelPalette.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
            .padding(16)
        }
        .background(Color(red: 0.918, green: 0.898, blue: 0.851))
    }

    private var hasTrustContent: Bool {
        !report.listingTrust.missingInfo.isEmpty ||
            !report.listingTrust.concerns.isEmpty ||
            !report.listingTrust.questionsToAsk.isEmpty
    }
}

private struct VerdictSection: View {
    let verdict: Verdict

    var body: some View {
        VStack(spacing: 8) {
            Text("CLEARED")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .tracking(3)
                .foregroundStyle(LabelPalette.green)

            Text(verdict.recommendation?.rawValue.uppercased() ?? "NO VERDICT")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(verdictColor)

            Text(verdict.oneLine)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verdict: \(verdict.recommendation?.rawValue ?? "unavailable"). \(verdict.oneLine)")
    }

    private var verdictColor: Color {
        switch verdict.recommendation {
        case .buy: LabelPalette.green
        case .negotiate: .orange
        case .skip: LabelPalette.thread
        case nil: LabelPalette.soft
        }
    }
}

private struct PriceSection: View {
    let facts: ListingFacts
    let price: PriceRead

    var body: some View {
        LabelSection(title: "Price read") {
            HStack(alignment: .top, spacing: 10) {
                PriceMetric(label: "Asking", value: money(facts.askingPrice))
                PriceMetric(label: "Retail", value: money(price.retailEstimate, approximate: true))
                PriceMetric(label: "Used", value: range(price.usedEstimateLow, price.usedEstimateHigh))
            }

            LabelRow(label: "Market read", value: price.fairness?.rawValue.capitalized ?? "Couldn't verify")
            LabelRow(label: "Suggested offer", value: range(price.suggestedOfferLow, price.suggestedOfferHigh))

            Text(price.reasoning)
                .font(.footnote)
                .foregroundStyle(LabelPalette.soft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func money(_ value: Double?, approximate: Bool = false) -> String {
        guard let value else { return "Couldn't verify" }
        return "\(approximate ? "~" : "")\(value.formatted(.currency(code: facts.currency).precision(.fractionLength(value.rounded() == value ? 0 : 2))))"
    }

    private func range(_ low: Double?, _ high: Double?) -> String {
        switch (low, high) {
        case let (low?, high?): "\(money(low))–\(money(high))"
        case let (low?, nil): "From \(money(low))"
        case let (nil, high?): "Up to \(money(high))"
        case (nil, nil): "Couldn't verify"
        }
    }
}

private struct TrustSection: View {
    let trust: ListingTrust
    @State private var copiedQuestion: String?

    var body: some View {
        LabelSection(title: "Listing trust") {
            BulletGroup(title: "Missing", items: trust.missingInfo, symbol: "minus.circle", color: .orange)
            BulletGroup(title: "Concerns", items: trust.concerns, symbol: "exclamationmark.triangle", color: LabelPalette.thread)

            if !trust.questionsToAsk.isEmpty {
                Text("QUESTIONS TO ASK · TAP TO COPY")
                    .labelEyebrow()
                ForEach(trust.questionsToAsk, id: \.self) { question in
                    Button {
                        UIPasteboard.general.string = question
                        copiedQuestion = question
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: copiedQuestion == question ? "checkmark" : "doc.on.doc")
                                .frame(width: 18)
                            Text(question)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                        .padding(10)
                        .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Copies this question")
                }
            }
        }
    }
}

private struct AuthSection: View {
    let flag: AuthFlag

    var body: some View {
        LabelSection(title: "Authenticity check", tint: LabelPalette.thread) {
            Text("Judgment assist only — not an authentication verdict.")
                .font(.caption)
                .foregroundStyle(LabelPalette.soft)
            if let confidence = flag.confidence {
                LabelRow(label: "Confidence", value: confidence.capitalized)
            }
            BulletGroup(title: "Red flags", items: flag.redFlags, symbol: "flag.fill", color: LabelPalette.thread)
            BulletGroup(title: "Inspect before buying", items: flag.whatToInspect, symbol: "magnifyingglass", color: LabelPalette.ink)
        }
    }
}

private struct FactsSection: View {
    let facts: ListingFacts
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 8) {
                OptionalRow(label: "Brand", value: facts.brand)
                OptionalRow(label: "Item", value: facts.modelOrName)
                OptionalRow(label: "Category", value: facts.category)
                OptionalRow(label: "Size", value: facts.size)
                OptionalRow(label: "Condition", value: facts.listedCondition)
                BulletGroup(title: "Seen in photos", items: facts.photoObservations, symbol: "eye", color: LabelPalette.soft)
            }
            .padding(.top, 10)
        } label: {
            Text("LISTING FACTS")
                .labelEyebrow()
        }
        .tint(LabelPalette.ink)
    }
}

private struct LabelSection<Content: View>: View {
    let title: String
    var tint: Color = LabelPalette.ink
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(tint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PriceMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).labelEyebrow()
            Text(value).font(.system(.callout, design: .monospaced, weight: .semibold))
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LabelRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(LabelPalette.soft)
            Spacer(minLength: 12)
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

private struct OptionalRow: View {
    let label: String
    let value: String?
    var body: some View {
        if let value, !value.isEmpty { LabelRow(label: label, value: value) }
    }
}

private struct BulletGroup: View {
    let title: String
    let items: [String]
    let symbol: String
    let color: Color

    var body: some View {
        if !items.isEmpty {
            Text(title.uppercased()).labelEyebrow()
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }
}

private struct LabelDivider: View {
    var body: some View {
        Rectangle().fill(LabelPalette.line).frame(height: 1).padding(.vertical, 16)
    }
}

private extension View {
    func labelEyebrow() -> some View {
        font(.system(.caption2, design: .monospaced, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(LabelPalette.soft)
    }
}
