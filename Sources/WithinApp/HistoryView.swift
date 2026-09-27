import SwiftUI
import WithinCore

/// Retention choices as selectable capsules. Setup and Settings include Off; the opt-in card does not.
struct HistoryRetentionPicker: View {
    @Binding var selection: HistoryRetention
    var includeOff = true
    var body: some View {
        HStack(spacing: 8) {
            ForEach(HistoryRetention.allCases.filter { includeOff || $0 != .off }, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(option.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(selected ? Palette.canvas : Palette.text)
                        .background(selected ? AnyShapeStyle(Palette.text) : AnyShapeStyle(Palette.tint.opacity(0.7)), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Keep dictation history")
    }
}

/// Existing installs get the same explicit choice as setup; nothing is saved until it is made.
struct HistoryOptInCard: View {
    @ObservedObject var model: AppModel
    @State private var choice: HistoryRetention = .week
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Keep a history of your dictations?", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
            Text("Find and copy what you said later. History stays on this Mac, is left out of Time Machine backups and is never uploaded. You choose how long.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            HistoryRetentionPicker(selection: $choice, includeOff: false)
            HStack(spacing: 10) {
                Button("Keep history") { model.chooseHistoryRetention(choice) }.primaryAction()
                Button("Not now") { model.chooseHistoryRetention(.off) }.quietAction()
            }
        }.withinSurface(padding: 18)
    }
}

struct HistorySection: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void = {}
    @State private var query = ""
    private var keeping: Bool { model.historyRetention?.keepsHistory == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("History").font(Typography.display(22)).accessibilityAddTraits(.isHeader)
                if keeping {
                    Text(model.effectiveRetention == .forever ? "Kept until you delete it · on this Mac" : "Kept \(model.effectiveRetention.title) · on this Mac")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 8)
                if keeping && !model.history.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary).accessibilityHidden(true)
                        TextField("Search", text: $query).textFieldStyle(.plain).accessibilityLabel("Search history")
                    }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6).frame(width: 180)
                        .background(Palette.canvas.opacity(0.75), in: Capsule())
                }
            }
            if !model.historyMessage.isEmpty {
                Text(model.historyMessage).font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            if model.historyRetention == nil {
                HistoryOptInCard(model: model)
            } else if !keeping {
                HStack {
                    Text("History is off. Dictations aren’t saved.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("Turn on…", action: openSettings).quietAction()
                }
            } else if model.history.isEmpty {
                Text("Nothing here yet. Words you insert or copy will appear here.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.vertical, 6)
            } else {
                entries
            }
        }
    }

    @ViewBuilder private var entries: some View {
        let matches = HistoryPolicy.matching(model.history, query: query)
        let days = Dictionary(grouping: matches) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        if matches.isEmpty {
            Text("No dictations match “\(query)”.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        ForEach(days, id: \.key) { day, items in
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.title(for: day).uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.secondary).accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 84) }
                        HistoryRow(entry: entry, copy: { model.copyHistoryEntry(entry) }, delete: { model.deleteHistoryEntry(entry.id) })
                    }
                }.withinSurface(padding: 2)
            }
        }
    }

    static func title(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// Copy and Delete stay visible (dimmed until hover) so keyboard and VoiceOver users can reach them.
struct HistoryRow: View {
    let entry: HistoryEntry
    let copy: () -> Void
    let delete: () -> Void
    @State private var hovering = false
    var body: some View {
        let time = entry.date.formatted(date: .omitted, time: .shortened)
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(time).font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.secondary)
                .frame(width: 58, alignment: .leading)
            Text(entry.text).font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                Button(action: copy) { Image(systemName: "doc.on.doc").frame(width: 24, height: 22) }
                    .help("Copy").accessibilityLabel("Copy dictation from \(time)")
                Button(action: delete) { Image(systemName: "trash").frame(width: 24, height: 22) }
                    .help("Delete").accessibilityLabel("Delete dictation from \(time)")
            }.buttonStyle(.borderless).foregroundStyle(Palette.secondary).opacity(hovering ? 1 : 0.5)
        }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
    }
}
