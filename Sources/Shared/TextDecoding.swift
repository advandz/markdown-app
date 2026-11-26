//
//  TextDecoding.swift
//  Markdown
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

/// Reads text files whose encoding isn't declared anywhere.
///
/// UTF-16 and UTF-32 are only recognised by their byte-order mark: decoding
/// without one accepts almost any bytes and turns legacy 8-bit files into
/// nonsense. Everything else is UTF-8, then Windows-1252 (which most "ANSI"
/// files are), then Latin-1, which accepts any byte.
enum TextDecoding {
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf32) {
            return (text, .utf32)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return (text, .utf16)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return (text, .windowsCP1252)
        }
        return (String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self), .isoLatin1)
    }
}
