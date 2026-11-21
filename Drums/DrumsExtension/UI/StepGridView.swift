//
//  StepGridView.swift
//  Renders 10 voice rows × 16 step cells, with the live playhead column
//  highlighted via a red overlay.
//

import AppKit

final class StepGridView: NSView {
    /// True = step is active (lit).
    var pattern: [[Bool]] = Array(repeating: Array(repeating: false, count: 16), count: 10) { didSet { needsDisplay = true } }
    /// Current playhead column 0..15. Set from parent on a timer.
    var playhead: Int = -1 { didSet { needsDisplay = true } }
    /// Voice names rendered on the far left of each row.
    var voiceNames: [String] = ["KICK", "SNARE", "CLAP", "RIM", "TOM 1", "TOM 2", "TOM 3", "HAT C", "HAT O", "CRASH"]
    /// Called when the user clicks a cell — (voice, step, newState).
    var onCellToggle: ((Int, Int, Bool) -> Void)?

    private let cream = Palette.cream
    private let cellOff = NSColor(calibratedWhite: 0.84, alpha: 1)
    private let cellOn  = Palette.accent
    private let inkDark = Palette.inkDark
    private let inkMid  = Palette.inkMid

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let labelW: CGFloat = 60
        let rowH = b.height / 10
        let gridX = b.minX + labelW
        let gridW = b.width - labelW
        let cellGap: CGFloat = 1.5
        let groupGap: CGFloat = 5
        let extraGapTotal = groupGap * 3                  // 3 group gaps for 4 groups of 4
        let cellW = (gridW - cellGap * 12 - extraGapTotal) / 16

        // Playhead column band first (so cells sit on top)
        if playhead >= 0 && playhead < 16 {
            let col = playhead
            let group = col / 4
            let x = gridX + CGFloat(col) * cellW + CGFloat(col) * cellGap + CGFloat(group) * groupGap
            ctx.setFillColor(cellOn.withAlphaComponent(0.10).cgColor)
            ctx.fill(NSRect(x: x - 1, y: b.minY, width: cellW + 2, height: b.height))
        }

        for row in 0..<10 {
            let y = b.maxY - CGFloat(row + 1) * rowH
            // Voice name
            let nameAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: inkDark, .kern: 0.5]
            NSString(string: voiceNames[row]).draw(at: NSPoint(x: 6, y: y + rowH * 0.5 - 6), withAttributes: nameAttr)

            // Cells
            for col in 0..<16 {
                let group = col / 4
                let x = gridX + CGFloat(col) * cellW + CGFloat(col) * cellGap + CGFloat(group) * groupGap
                let cellRect = NSRect(x: x, y: y + 4, width: cellW, height: rowH - 8)
                let lit = (row < pattern.count && col < pattern[row].count) ? pattern[row][col] : false
                ctx.setFillColor((lit ? cellOn : cellOff).cgColor); ctx.fill(cellRect)
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.4); ctx.stroke(cellRect)
            }
            // Row separator hairline
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.15).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: b.minX, y: y)); ctx.addLine(to: NSPoint(x: b.maxX, y: y)); ctx.strokePath()
        }

        // Bar labels under the grid
        let barAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid]
        for g in 0..<4 {
            let firstColInGroup = g * 4
            let x = gridX + CGFloat(firstColInGroup) * cellW + CGFloat(firstColInGroup) * cellGap + CGFloat(g) * groupGap + cellW * 2
            NSString(string: "\(g + 1)").draw(at: NSPoint(x: x - 3, y: b.minY - 8), withAttributes: barAttr)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let b = bounds
        let labelW: CGFloat = 60
        let rowH = b.height / 10
        let gridX = b.minX + labelW
        let gridW = b.width - labelW
        let cellGap: CGFloat = 1.5
        let groupGap: CGFloat = 5
        let cellW = (gridW - cellGap * 12 - groupGap * 3) / 16

        // Which row?
        let row = Int((b.maxY - p.y) / rowH)
        guard row >= 0 && row < 10 else { return }

        // Which column? Walk left to right.
        var x = gridX
        for col in 0..<16 {
            let group = col / 4
            let cellX = gridX + CGFloat(col) * cellW + CGFloat(col) * cellGap + CGFloat(group) * groupGap
            let cellRect = NSRect(x: cellX, y: b.maxY - CGFloat(row + 1) * rowH + 4, width: cellW, height: rowH - 8)
            if cellRect.contains(p) {
                let now = !pattern[row][col]
                pattern[row][col] = now
                onCellToggle?(row, col, now)
                return
            }
            _ = x
        }
    }
}
