import SwiftUI

/// The Places tab: places by category, sorted, or searched by name, and a
/// place added from Apple Maps.
struct PlacesView: View {
    @State private var model: PlacesModel
    @State private var query = ""
    @State private var isAdding = false
    /// Adding a place, starting from what was searched for, if anything.
    private let makeAddPlace: (String) -> AddPlaceModel
    private let onOpen: (String) -> Void

    init(model: PlacesModel, makeAddPlace: @escaping (String) -> AddPlaceModel, onOpen: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.makeAddPlace = makeAddPlace
        self.onOpen = onOpen
    }

    var body: some View {
        List {
            Section {
                categories
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            content
        }
        .listStyle(.plain)
        .background(Palette.background)
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search places"))
        .onSubmit(of: .search) { model.search(query) }
        .onChange(of: query) { _, text in
            if text.isEmpty { model.search("") }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Add a Place")
                .accessibilityIdentifier("places.add")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(PlaceSort.allCases, id: \.self) { sort in
                            Text(sort.label)
                                .accessibilityIdentifier("places.sort.\(sort.rawValue)")
                                .tag(sort)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Sort by")
                .accessibilityValue(model.sort.label)
                .accessibilityIdentifier("places.sort")
            }
        }
        .task { if model.items.isEmpty { await model.load() } }
        .refreshable { await model.load() }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                AddPlaceSheet(model: makeAddPlace(query)) { placeID in
                    onOpen(placeID)
                    // So that back from it, the list has it: first, as the
                    // newest.
                    Task { await model.load() }
                }
            }
        }
    }

    private var categories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                chip(String(localized: "All"), selected: model.category == nil) { model.category = nil }
                    .accessibilityIdentifier("places.category.all")
                ForEach(PlaceCategory.filters, id: \.self) { category in
                    chip("\(category.emoji) \(category.filterLabel)", selected: model.category == category) {
                        model.category = category
                    }
                    .accessibilityIdentifier("places.category.\(category.rawValue)")
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.s)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Layout.minTouchTarget)
                .foregroundStyle(selected ? Palette.textOnBrand : Palette.primaryText)
                .background(selected ? Palette.brandPrimary : Palette.secondaryBackground, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading where model.items.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("places.loading")
        case .failed(let message) where model.items.isEmpty:
            FeedErrorView(message: message) { Task { await model.load() } }
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("places.error")
        default:
            if model.items.isEmpty {
                VStack(spacing: Spacing.m) {
                    VStack(spacing: Spacing.s) {
                        Text("No places found")
                            .font(Typography.sectionTitle)
                            .foregroundStyle(Palette.primaryText)
                        Text("Be the first to recommend one!")
                            .font(Typography.body)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("places.empty")
                    // The web's action, outside the words so it is its own
                    // button.
                    Button("Add a Place") { isAdding = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.brandPrimary)
                        .accessibilityIdentifier("places.empty.add")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
                .listRowSeparator(.hidden)
            } else {
                ForEach(model.items) { place in
                    PlaceRow(place: place, name: model.lookups.name(of: place)) { onOpen(place.id) }
                        .onAppear {
                            if place.id == model.items.last?.id { Task { await model.loadMore() } }
                        }
                }
                if model.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct PlaceRow: View {
    let place: Place
    /// The place's own name, or Apple's for one from Apple Maps.
    let name: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Spacing.m) {
                PlaceThumbnail(place: place, side: 72)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(name)
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                    Text("\(place.category.emoji) \(place.category.label)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                    if let rating = place.ratingLine {
                        Text("⭐ \(rating)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.primaryText)
                    } else {
                        Text("No reviews yet")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    if place.totalCheckins > 0 {
                        Text("\(place.totalCheckins) check-ins")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    if place.verifiedByCheckins {
                        Text("✓ Verified")
                            .font(Typography.caption.weight(.semibold))
                            .foregroundStyle(Palette.success)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Layout.minTouchTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("place.\(place.id)")
    }
}

/// The place's first photo, or its category's emoji on the brand gradient —
/// the web's placeholder.
struct PlaceThumbnail: View {
    let place: Place
    let side: CGFloat

    var body: some View {
        Group {
            if let photo = place.photos.first {
                RemoteImage(url: photo, aspectRatio: 1, cornerRadius: Radius.control, size: .thumbnail)
            } else {
                LinearGradient(
                    colors: [Palette.brandGradientStart, Palette.brandGradientEnd],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay { Text(place.category.emoji).font(Typography.pageTitle) }
                .clipShape(.rect(cornerRadius: Radius.control))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
