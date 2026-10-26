import SwiftUI
import StrandDesign

/// Native journal logging — yes/no chips for the merged behaviour catalog plus a custom-question
/// field, hosted at the top of Insights. Answers write under `Repository.journalDeviceId`
/// ("noop-journal"), NEVER the imported source, so a CSV re-import can't clobber them and clearing
/// is safe (imported rows are never touched). Tri-state: tapping the selected chip again clears the
/// answer. Day attribution follows the importer's wake-day convention — answers describe the night
/// and day leading into the selected morning, so logged days line up with imported history.
struct JournalLogCard: View {
    @EnvironmentObject var repo: Repository
    /// The custom-question catalog is single-user state owned here (UserDefaults-backed), so hosting
    /// the card needs no app-level injection.
    @StateObject private var catalog = JournalCatalogStore()

    /// Distinct imported question strings (from InsightsView's load) — adopted into the catalog so
    /// logged answers and imported history group under the same behaviour.
    let importedQuestions: [String]
    /// question → answeredYes for the selected day, native rows only (drives the chip state).
    let answers: [String: Bool]
    @Binding var dayOffset: Int            // -1 = tomorrow, 0 = today, 1 = yesterday
    let onChanged: () -> Void              // parent re-runs load() after a write

    @State private var customDraft = ""
    /// Edit mode: swaps the Yes/No chips for a Remove control and reveals the hidden-questions list.
    @State private var editing = false

    private var dayKey: String {
        Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .center) {
                SectionHeader("Journal", overline: "Log")
                Spacer()
                if editing {
                    pillButton("Done", selected: true) { editing = false }
                } else {
                    pillButton("Edit", selected: false) { editing = true }
                    dayPill("Tomorrow", offset: -1)
                    dayPill("Today", offset: 0)
                    dayPill("Yesterday", offset: 1)
                }
            }
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing
                         ? "Remove a question to tidy your list. Custom questions are deleted; the built-in ones are hidden and can be restored below."
                         : dayOffset == -1
                         ? "Logging ahead for tomorrow: today's activities inform tomorrow's recovery, just as yesterday's are reflected in today's. Tomorrow's answers line up with tomorrow's morning."
                         : "Answers are about the night and day leading into this morning — the same attribution a WHOOP export uses, so logged and imported days line up.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(JournalCatalogStore.mergeCatalog(imported: importedQuestions,
                                                             custom: catalog.customQuestions,
                                                             hidden: catalog.hiddenQuestions),
                            id: \.self) { q in
                        HStack {
                            Text(verbatim: q)   // data, not a UI literal — stays out of the catalog
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            if editing {
                                removeButton(q: q)
                            } else {
                                answerPill("Yes", q: q, value: true)
                                answerPill("No", q: q, value: false)
                            }
                        }
                    }
                    // Hidden built-in questions — only shown while editing, with a restore action.
                    if editing, !catalog.hiddenQuestions.isEmpty {
                        Divider().overlay(StrandPalette.hairline)
                        Text("Hidden")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        ForEach(catalog.hiddenQuestions, id: \.self) { q in
                            HStack {
                                Text(verbatim: q)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                Spacer()
                                pillButton("Restore", selected: false) { catalog.restore(q) }
                            }
                        }
                    }
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        TextField("Add a custom question…", text: $customDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let t = customDraft.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            catalog.customQuestions.append(t)
                            customDraft = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func dayPill(_ label: LocalizedStringKey, offset: Int) -> some View {
        pillButton(label, selected: dayOffset == offset) {
            dayOffset = offset
            onChanged()   // reload the selected day's answers
        }
    }

    private func answerPill(_ label: LocalizedStringKey, q: String, value: Bool) -> some View {
        let selected = answers[q] == value
        return pillButton(label, selected: selected) {
            Task {
                // Tri-state: re-tapping the filled chip clears the answer (natural-key delete,
                // scoped to "noop-journal" — imported rows can never be removed this way).
                if selected {
                    await repo.clearJournalAnswer(day: dayKey, question: q)
                } else {
                    await repo.saveJournalAnswer(day: dayKey, question: q, answeredYes: value)
                }
                onChanged()
            }
        }
    }

    /// Edit-mode control: delete a custom question / hide a built-in one. Tinted red to read as removal.
    private func removeButton(q: String) -> some View {
        Button { catalog.remove(q) } label: {
            Image(systemName: "minus.circle.fill")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.statusCritical)
        }
        .buttonStyle(.plain)
        .help(catalog.isCustom(q) ? "Delete this custom question" : "Hide this question")
        .accessibilityLabel(catalog.isCustom(q) ? "Delete \(q)" : "Hide \(q)")
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? StrandPalette.restColor : StrandPalette.surfaceInset,
                            in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.restColor : StrandPalette.hairline,
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
