import Foundation
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class PlaceReviewModel {
    enum Outcome: Equatable {
        case submitted
        case failed(String)
    }

    var draft: PlaceReviewDraft
    private(set) var isSubmitting = false
    private(set) var outcome: Outcome?

    let placeName: String
    private let source: any PlaceReviewing
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(placeID: String, placeName: String, meetupID: String? = nil, source: any PlaceReviewing) {
        self.draft = PlaceReviewDraft(placeID: placeID, meetupID: meetupID)
        self.placeName = placeName
        self.source = source
    }

    var canSubmit: Bool { draft.canSubmit && !isSubmitting && outcome != .submitted }

    func toggle(tag: String) {
        if let index = draft.tags.firstIndex(of: tag) {
            draft.tags.remove(at: index)
        } else {
            draft.tags.append(tag)
        }
    }

    /// One submission at a time, taken before any suspension: a second tap
    /// arrives before the redraw that disables the button. The server also
    /// refuses a second review of the same place (`already-exists`), and its
    /// words are what is shown.
    func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        outcome = nil
        defer { isSubmitting = false }
        do {
            try await source.submitReview(draft)
            outcome = .submitted
        } catch {
            log.error("review failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(GatheringWords.message(for: error, fallback: String(localized: "Failed to submit review.")))
        }
    }
}

/// The web's rating sheet: an overall rating (required), three pet-friendly
/// scores, tags and a comment. No photos yet — they need the test Cloudinary
/// account.
struct PlaceReviewSheet: View {
    @State private var model: PlaceReviewModel
    @Environment(\.dismiss) private var dismiss
    private let onSubmitted: () -> Void

    init(model: PlaceReviewModel, onSubmitted: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onSubmitted = onSubmitted
    }

    var body: some View {
        Form {
            Section {
                Text(model.placeName)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Palette.primaryText)
                stars(String(localized: "Rate this place"), value: $model.draft.rating, identifier: "review.rating")
            }
            Section("Pet-friendly scores") {
                stars(String(localized: "🐾 Space for pets"), value: $model.draft.space, identifier: "review.space")
                stars(String(localized: "🛡️ Safety"), value: $model.draft.safety, identifier: "review.safety")
                stars(String(localized: "✨ Cleanliness"), value: $model.draft.cleanliness, identifier: "review.cleanliness")
            }
            Section("Tags") {
                FlowTags(options: PlaceReviewDraft.tagOptions, selected: model.draft.tags) { model.toggle(tag: $0) }
            }
            Section {
                TextField("Share your experience about this location...", text: $model.draft.comment, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("review.comment")
                Text("\(PlaceReviewDraft.maxComment - model.draft.commentLength)")
                    .font(Typography.caption)
                    .foregroundStyle(model.draft.commentLength > PlaceReviewDraft.maxComment ? Palette.danger : Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } footer: {
                if case .failed(let message) = model.outcome {
                    Text(message)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("review.error")
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(model.isSubmitting)
                    .accessibilityIdentifier("review.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        await model.submit()
                        if model.outcome == .submitted {
                            onSubmitted()
                            dismiss()
                        }
                    }
                } label: {
                    Text(model.isSubmitting ? String(localized: "Submitting...") : String(localized: "Submit Review"))
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("review.submit")
            }
        }
        .interactiveDismissDisabled(model.isSubmitting)
    }

    private func stars(_ title: String, value: Binding<Int>, identifier: String) -> some View {
        HStack {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
            Spacer(minLength: Spacing.s)
            ForEach(1...5, id: \.self) { score in
                Button { value.wrappedValue = score } label: {
                    Image(systemName: score <= value.wrappedValue ? "star.fill" : "star")
                        .foregroundStyle(score <= value.wrappedValue ? Palette.warning : Palette.tertiaryText)
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "\(score) out of 5"))
                .accessibilityAddTraits(score == value.wrappedValue ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Tag chips that wrap onto as many lines as they need.
private struct FlowTags: View {
    let options: [String]
    let selected: [String]
    let onToggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: Spacing.s) {
            ForEach(options, id: \.self) { tag in
                let isOn = selected.contains(tag)
                Button { onToggle(tag) } label: {
                    Text(PlaceReviewDraft.tagLabel(tag))
                        .font(Typography.caption)
                        .padding(.horizontal, Spacing.m)
                        .frame(minHeight: Layout.minTouchTarget)
                        .foregroundStyle(isOn ? Palette.textOnBrand : Palette.primaryText)
                        .background(isOn ? Palette.brandPrimary : Palette.secondaryBackground, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("review.tag.\(PlaceReviewDraft.tagOptions.firstIndex(of: tag) ?? 0)")
            }
        }
    }
}

/// Lays children out left to right, wrapping when a line is full.
/// `SwiftUI.Layout` by name: this app's own `Layout` holds the spacing
/// tokens and shadows the protocol.
private struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
