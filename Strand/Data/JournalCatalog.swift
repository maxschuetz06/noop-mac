import Foundation

/// The user's custom journal questions plus the starter behaviour catalog. Question strings are
/// opaque exact-match labels to BehaviorInsights, so imported question strings (merged in at load
/// time, ahead of these) always take precedence — adopting the export's exact wording is what
/// joins a logged day and an imported day into one behaviour. UserDefaults-backed (single user).
@MainActor
final class JournalCatalogStore: ObservableObject {

    /// Mirrors Android STARTER_JOURNAL_QUESTIONS value-for-value (JournalLog.kt). These are DATA,
    /// not UI literals — stored verbatim in the journal table and rendered verbatim, so they must
    /// never be localised (a translated key would start a new, disconnected behaviour).
    nonisolated static let starterQuestions: [String] = [
        "Did you drink any alcohol?",
        "Did you have caffeine late in the day?",
        "Did you view a screen in bed?",
        "Did you eat close to bedtime?",
        "Did you feel stressed?",
        "Did you use a sauna?",
        "Did you share your bed?",
        "Did you feel sick or ill?",
        "Did you take magnesium?",
        "Did you read before bed?",
    ]

    @Published var customQuestions: [String] { didSet { d.set(customQuestions, forKey: K.custom) } }
    /// Questions the user has hidden from the catalog — starter or imported ones they don't want to
    /// see. Stored verbatim (case-insensitive match at merge). Custom questions are *deleted* outright
    /// rather than hidden, so they never live here. Restorable from the journal's edit mode.
    @Published var hiddenQuestions: [String] { didSet { d.set(hiddenQuestions, forKey: K.hidden) } }

    private let d = UserDefaults.standard
    private enum K {
        static let custom = "journal.customQuestions"
        static let hidden = "journal.hiddenQuestions"
    }

    init() {
        customQuestions = d.stringArray(forKey: K.custom) ?? []
        hiddenQuestions = d.stringArray(forKey: K.hidden) ?? []
    }

    /// Dedup/identity key for a question. Normalises ALL whitespace — leading/trailing AND internal
    /// runs collapse to a single space (not just ASCII space/tab) — then lowercases. A WHOOP export
    /// commonly leaves a trailing newline or non-breaking space on a journal cell, which a bare
    /// `.whitespaces` trim leaves in place: that's what let "Did you take magnesium?\n" (imported)
    /// sit beside the starter "Did you take magnesium?" as two rows (#224). Collapsing here folds
    /// them onto one key. The DISPLAYED string is still the original verbatim text — only the match
    /// key is normalised — so the stored behaviour key (which the effects engine joins on) is intact.
    /// Kept value-for-value in step with Android `normJournalKey` (JournalLog.kt).
    private nonisolated static func norm(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// imported > starter > custom; case-insensitive dedupe, first casing wins, with `hidden`
    /// questions filtered out. Imported questions lead so the export's exact strings (which the
    /// effects engine keys on) survive verbatim and pull the matching starter/custom out of the list.
    nonisolated static func mergeCatalog(imported: [String], custom: [String],
                                         hidden: [String] = []) -> [String] {
        let hiddenSet = Set(hidden.map(norm))
        var seen = Set<String>()
        var out: [String] = []
        for q in imported + starterQuestions + custom {
            // Display text trims surrounding whitespace/newlines; the dedup key normalises ALL
            // whitespace (see `norm`) so an imported "…magnesium?\n" folds onto the starter (#224).
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = norm(q)
            if !t.isEmpty, !hiddenSet.contains(key), seen.insert(key).inserted { out.append(t) }
        }
        return out
    }

    /// True when `q` is a user-added custom question (not a starter/imported one).
    func isCustom(_ q: String) -> Bool {
        customQuestions.contains { Self.norm($0) == Self.norm(q) }
    }

    /// Remove `q` from the journal: a custom question is deleted outright; a starter/imported one is
    /// hidden (restorable). Either way it leaves the merged catalog.
    func remove(_ q: String) {
        let key = Self.norm(q)
        if isCustom(q) {
            customQuestions.removeAll { Self.norm($0) == key }
        } else if !hiddenQuestions.contains(where: { Self.norm($0) == key }) {
            hiddenQuestions.append(q.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Un-hide a previously hidden starter/imported question.
    func restore(_ q: String) {
        let key = Self.norm(q)
        hiddenQuestions.removeAll { Self.norm($0) == key }
    }
}
