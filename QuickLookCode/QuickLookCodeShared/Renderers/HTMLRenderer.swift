//
//  HTMLRenderer.swift
//  QuickLookCodeShared
//
//  Token span type shared between MarkdownRenderer's fenced-code-block highlighter
//  and SourceCodeRenderer's tokenization output.
//

import Foundation

public enum HTMLRenderer {

    // MARK: - Public Types

    public struct TokenSpan {
        public let text: String
        public let color: String?       // hex e.g. "#569cd6", nil = use foreground default
        public let isBold: Bool
        public let isItalic: Bool
        public let isUnderline: Bool

        public init(text: String, color: String?, fontStyle: String?) {
            self.text = text
            self.color = color
            let style = fontStyle ?? ""
            self.isBold      = style.contains("bold")
            self.isItalic    = style.contains("italic")
            self.isUnderline = style.contains("underline")
        }
    }
}
