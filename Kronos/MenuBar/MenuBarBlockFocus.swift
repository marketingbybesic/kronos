// Kronos/MenuBar/MenuBarBlockFocus.swift — "the menu bar follows the current time block".
//
// A known gap this file fixes: on the Time Blocks view, the top menu bar item did not
// change and stayed per-project regardless of the active block. Foundation-only precedence
// rule, no KronosCore, no AppModel: `MenuBarOrdoController`/`PopoverContent` supply real task
// IDs from `TimeBlocksModel`/`CoachModel.todaysBlocks`; `scripts/menubar-blockfocus-selftest.swift`
// hand-tables it against IDs alone, same shape as `TimeBlockSelection`/`MenuBarHitRegion`.
//
// Rule (brief verbatim): when the Time blocks view is enabled AND a calendar block is current
// AND it has linked open tasks, Ordo (menu-bar title + popover order) shows that block's first
// open task and lists the block's tasks first; otherwise the existing behaviour.
import Foundation

enum MenuBarBlockFocus {
    /// `blockTaskIDs` is the current block's OPEN tasks, already in the order the block screen
    /// shows them (`TimeBlocksModel.tasks(for:)`'s own sort) — this function never reorders
    /// them itself, it only decides whether they take precedence. `settingOn` is Settings >
    /// Coach's "Menu bar follows the current time block" (default on); `viewEnabled` is
    /// `TimeBlocksPrefs.isEnabled`; `hasCurrentBlock` is whether a calendar block is current
    /// right now (`TimeBlockSelection.currentIndex` resolved something, not merely non-empty).
    static func appliesBlockPrecedence(settingOn: Bool, viewEnabled: Bool, hasCurrentBlock: Bool, blockTaskIDs: [UUID]) -> Bool {
        settingOn && viewEnabled && hasCurrentBlock && !blockTaskIDs.isEmpty
    }

    /// The task ID the bar/popover treat as THE focus when block precedence applies (the
    /// block's own first open task) — nil when it does not apply, so the caller falls back to
    /// its existing `ordoFocus`/pin resolution untouched.
    static func focusTaskID(settingOn: Bool, viewEnabled: Bool, hasCurrentBlock: Bool, blockTaskIDs: [UUID]) -> UUID? {
        guard appliesBlockPrecedence(settingOn: settingOn, viewEnabled: viewEnabled, hasCurrentBlock: hasCurrentBlock, blockTaskIDs: blockTaskIDs) else { return nil }
        return blockTaskIDs.first
    }

    /// Reorders `listIDs` (the popover's normal Next-rows order) so every block task appears
    /// first, in the block's own order, followed by the remaining list rows in their existing
    /// order with block tasks and the given `focusID` removed (the focus row is rendered
    /// separately, never duplicated into Next) — a plain stable partition, no resort.
    static func reordered(listIDs: [UUID], blockTaskIDs: [UUID], focusID: UUID?) -> [UUID] {
        let blockSet = Set(blockTaskIDs)
        let rest = listIDs.filter { $0 != focusID && !blockSet.contains($0) }
        let blockRest = blockTaskIDs.filter { $0 != focusID }
        return blockRest + rest
    }
}
