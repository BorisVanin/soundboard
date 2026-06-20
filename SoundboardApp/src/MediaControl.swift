//  MediaControl.swift
//
//  Drives system playback transport by posting the hardware media keys
//  (NX_KEYTYPE_PLAY / _NEXT / _PREVIOUS) as system-defined NSEvents. These reach
//  whatever app currently owns "Now Playing" (Music, Spotify, browsers, …), so
//  the buttons aren't tied to any one player.
//
//  This is the audio-silent sink for the media `MIDIButton` triggers — the
//  composition root injects `playPause`/`next`/`previous` as their `onAction`.
//
//  NOTE: posting HID events may require the app to be granted Accessibility /
//  Input-Monitoring permission the first time; macOS prompts as needed.

import AppKit
import CoreGraphics

enum MediaControl {

    // From IOKit/hidsystem/ev_keymap.h
    private static let keyPlayPause: Int32 = 16   // NX_KEYTYPE_PLAY
    private static let keyNext: Int32      = 17   // NX_KEYTYPE_NEXT
    private static let keyPrevious: Int32  = 18   // NX_KEYTYPE_PREVIOUS

    static func playPause() { tap(keyPlayPause) }
    static func next() { tap(keyNext) }
    static func previous() { tap(keyPrevious) }

    /// Post a media key as a down+up pair, the way the keyboard's own media keys do.
    private static func tap(_ keyCode: Int32) {
        post(keyCode, down: true)
        post(keyCode, down: false)
    }

    private static func post(_ keyCode: Int32, down: Bool) {
        let state: Int32 = down ? 0xA : 0xB                 // NX key-down / key-up
        let data1 = Int((keyCode << 16) | (state << 8))
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,                                     // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
