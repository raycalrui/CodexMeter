import Foundation

enum PopoverContentSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case quotaWindows
    case resetCredits
    case quotaHistory
    case tokenActivity

    var id: String { rawValue }
}

/// Stores presentation-only choices for the menu-bar popover.
/// Hidden content continues to refresh and record history in the background.
struct PopoverContentConfiguration: Codable, Equatable, Sendable {
    var sectionOrder: [PopoverContentSection]
    var hiddenSections: Set<PopoverContentSection>
    var hiddenQuotaWindowIDs: Set<String>
    var menuBarQuotaWindowID: String?

    static let defaultValue = PopoverContentConfiguration(
        sectionOrder: PopoverContentSection.allCases,
        hiddenSections: [],
        hiddenQuotaWindowIDs: [],
        menuBarQuotaWindowID: nil
    )

    init(
        sectionOrder: [PopoverContentSection],
        hiddenSections: Set<PopoverContentSection>,
        hiddenQuotaWindowIDs: Set<String>,
        menuBarQuotaWindowID: String?
    ) {
        self.sectionOrder = sectionOrder
        self.hiddenSections = hiddenSections
        self.hiddenQuotaWindowIDs = hiddenQuotaWindowIDs
        self.menuBarQuotaWindowID = menuBarQuotaWindowID
        normalize()
    }

    func isSectionVisible(_ section: PopoverContentSection) -> Bool {
        !hiddenSections.contains(section)
    }

    mutating func setSection(_ section: PopoverContentSection, visible: Bool) {
        if visible {
            hiddenSections.remove(section)
        } else {
            hiddenSections.insert(section)
        }
    }

    func isQuotaWindowVisible(_ window: CodexUsageWindow) -> Bool {
        !hiddenQuotaWindowIDs.contains(window.historyID)
    }

    mutating func setQuotaWindow(_ window: CodexUsageWindow, visible: Bool) {
        if visible {
            hiddenQuotaWindowIDs.remove(window.historyID)
        } else {
            hiddenQuotaWindowIDs.insert(window.historyID)
        }
    }

    func visibleQuotaWindows(from windows: [CodexUsageWindow]) -> [CodexUsageWindow] {
        guard isSectionVisible(.quotaWindows) else { return [] }
        return windows.filter(isQuotaWindowVisible)
    }

    mutating func moveSection(_ section: PopoverContentSection, by offset: Int) {
        guard let sourceIndex = sectionOrder.firstIndex(of: section) else { return }
        let destinationIndex = sourceIndex + offset
        guard sectionOrder.indices.contains(destinationIndex) else { return }
        sectionOrder.swapAt(sourceIndex, destinationIndex)
    }

    func selectedMenuBarWindow(from windows: [CodexUsageWindow]) -> CodexUsageWindow? {
        if let menuBarQuotaWindowID,
           let selected = windows.first(where: { $0.historyID == menuBarQuotaWindowID }) {
            return selected
        }
        return QuotaWindowSelection.preferredDefault(from: windows)
    }

    func normalized() -> PopoverContentConfiguration {
        var copy = self
        copy.normalize()
        return copy
    }

    private mutating func normalize() {
        var seen: Set<PopoverContentSection> = []
        sectionOrder = sectionOrder.filter { seen.insert($0).inserted }
        sectionOrder.append(contentsOf: PopoverContentSection.allCases.filter { !seen.contains($0) })
    }

    private enum CodingKeys: String, CodingKey {
        case sectionOrder
        case hiddenSections
        case hiddenQuotaWindowIDs
        case menuBarQuotaWindowID
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.defaultValue
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sectionOrder = try container.decodeIfPresent(
            [PopoverContentSection].self,
            forKey: .sectionOrder
        ) ?? defaults.sectionOrder
        hiddenSections = try container.decodeIfPresent(
            Set<PopoverContentSection>.self,
            forKey: .hiddenSections
        ) ?? defaults.hiddenSections
        hiddenQuotaWindowIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .hiddenQuotaWindowIDs
        ) ?? defaults.hiddenQuotaWindowIDs
        menuBarQuotaWindowID = try container.decodeIfPresent(
            String.self,
            forKey: .menuBarQuotaWindowID
        )
        normalize()
    }
}
