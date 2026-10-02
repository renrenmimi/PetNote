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
    /// The web's photos, sent before the review.
    let photos = PickedPhotos(limit: PlaceReviewDraft.maxPhotos)

    let placeName: String
    private let source: any PlaceReviewing
    private let uploader: any MediaUploading
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "places")

    init(
        placeID: String, placeName: String, meetupID: String? = nil, source: any PlaceReviewing,
        uploader: any MediaUploading
    ) {
        self.draft = PlaceReviewDraft(placeID: placeID, meetupID: meetupID)
        self.placeName = placeName
        self.source = source
        self.uploader = uploader
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
    /// words are what is shown. The web's order: the photos first, so a
    /// review is never sent without the ones meant to go with it.
    func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        photos.isLocked = true
        outcome = nil
        defer {
            isSubmitting = false
            photos.isLocked = false
        }
        do {
            draft.photos = try await photos.upload(with: uploader)
        } catch {
            log.error("photos for a review failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(Self.photoWording(for: error))
            return
        }
        do {
            try await source.submitReview(draft)
            outcome = .submitted
        } catch {
            log.error("review failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(GatheringWords.message(for: error, fallback: String(localized: "Failed to submit review.")))
        }
    }

    /// The pet editor's words for a photo that did not go, with the review in
    /// them where those name the pet: nothing was sent.
    static func photoWording(for error: Error) -> String {
        if let upload = error as? UploadError {
            switch upload {
            case .timedOut: return String(localized: "The photo upload timed out. Your review was not sent.")
            case .transport: return String(localized: "The photo could not be uploaded. Your review was not sent.")
            default: break
            }
        } else if !(error is UploadPreparation.PreparationError) {
            return String(localized: "The photo could not be uploaded. Your review was not sent.")
        }
        return PetEditorViewModel.photoWording(for: error)
    }
}

/// The web's rating sheet: an overall rating (required), three pet-friendly
/// scores, tags, up to three photos and a comment.
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
                StarRatingRow(title: String(localized: "Rate this place"), value: $model.draft.rating, identifier: "review.rating")
            }
            Section("Pet-friendly scores") {
                StarRatingRow(title: String(localized: "🐾 Space for pets"), value: $model.draft.space, identifier: "review.space")
                StarRatingRow(title: String(localized: "🛡️ Safety"), value: $model.draft.safety, identifier: "review.safety")
                StarRatingRow(title: String(localized: "✨ Cleanliness"), value: $model.draft.cleanliness, identifier: "review.cleanliness")
            }
            Section("Tags") {
                FlowTags(options: PlaceReviewDraft.tagOptions, selected: model.draft.tags) { model.toggle(tag: $0) }
            }
            Section {
                PickedPhotosRows(photos: model.photos)
            } header: {
                Text("Add photos (optional)")
            } footer: {
                Text(verbatim: "\(model.photos.items.count)/\(PlaceReviewDraft.maxPhotos)")
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
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("review.submit")
            }
        }
        .interactiveDismissDisabled(model.isSubmitting)
    }
}

/// One to five stars, each a button: a review's rating and its pet-friendly
/// scores, and the rating that can go with a place being added.
struct StarRatingRow: View {
    let title: String
    @Binding var value: Int
    let identifier: String

    var body: some View {
        HStack {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
            Spacer(minLength: Spacing.s)
            ForEach(1...5, id: \.self) { score in
                Button { value = score } label: {
                    Image(systemName: score <= value ? "star.fill" : "star")
                        .foregroundStyle(score <= value ? Palette.warning : Palette.tertiaryText)
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "\(score) out of 5"))
                .accessibilityAddTraits(score == value ? .isSelected : [])
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
        FlowLayout {
            ForEach(options, id: \.self) { tag in
                ChoiceChip(title: PlaceReviewDraft.tagLabel(tag), isSelected: selected.contains(tag)) { onToggle(tag) }
                    .accessibilityIdentifier("review.tag.\(PlaceReviewDraft.tagOptions.firstIndex(of: tag) ?? 0)")
            }
        }
    }
}
