//
//  EnterKeyTableView.swift
//  DefaultBrowser
//
//  Created by Cameron Little on 2/15/26.
//  Copyright © 2026 Cameron Little. All rights reserved.
//

import Cocoa

// Custom NSTableView that triggers doubleAction on Enter key
class EnterKeyTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { // Return or Enter
            if let action = doubleAction, selectedRow >= 0 {
                NSApp.sendAction(action, to: nil, from: self)
                return
            }
        }
        super.keyDown(with: event)
    }
}

// Custom NSTableView that triggers doubleAction on Enter key
class DeleteKeyTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 { // Delete
            if let action = doubleAction, selectedRow >= 0 {
                NSApp.sendAction(action, to: nil, from: self)
                return
            }
        }
        super.keyDown(with: event)
    }
}

// The markdown editor blocklist table: reuses DeleteKeyTableView's Delete-key handling as-is, and
// additionally treats every click as if ⌘ were held, so clicking a row toggles just that row's
// membership in the multi-selection instead of replacing the whole selection — more natural for a
// blocklist checklist than requiring ⌘-click for every row after the first.
class EditorBlocklistTableView: DeleteKeyTableView {
    override func mouseDown(with event: NSEvent) {
        guard let cgEvent = event.cgEvent?.copy() else {
            super.mouseDown(with: event)
            return
        }
        cgEvent.flags.insert(.maskCommand)
        if let toggledEvent = NSEvent(cgEvent: cgEvent) {
            super.mouseDown(with: toggledEvent)
        } else {
            super.mouseDown(with: event)
        }
    }
}
