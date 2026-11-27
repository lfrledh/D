//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct CodeBlockView: View {

  @Environment(\.markdownConfig) private var config: MarkdownRenderConfig
  @Environment(\.colorScheme) private var colorScheme

  let language: String
  let code: String
  let onCodeCopied: (() -> Void)?

  @State var copied: Bool = false
  @State var attributedString: AttributedString?
  @StateObject private var taskManager: HighlightTaskManager = HighlightTaskManager()
  @State private var activeHighlight: HighlightRequest?

  private struct HighlightRequest: Hashable {
    let code: String
    let colors: HighlightColors
  }

  private var highlightRequest: HighlightRequest {
    HighlightRequest(code: code, colors: config.codeBlockConfig.theme.highlightColors(for: colorScheme))
  }

  init(language: String, code: String, onCodeCopied: (() -> Void)? = nil) {
    self.language = language
    self.code = code
    self.onCodeCopied = onCodeCopied
  }

  private func updateAttributedString(_ request: HighlightRequest) async {
    guard !Task.isCancelled else { return }
    activeHighlight = request
    await taskManager.enqueueCode(request.code, colors: request.colors) { newAttributedString in
      guard activeHighlight == request else { return }
      self.attributedString = newAttributedString
    }
  }

  private var backgroundColor: Color? {
    config.codeBlockConfig.backgroundColor
  }

  private var foregroundColor: Color {
    config.codeBlockConfig.foregroundColor ?? Color.Static.Stone.Stone350
  }

  @ViewBuilder
  private var codeText: some View {
    #if canImport(AppKit)
    CodeBlockNativeText(content: attributedString ?? AttributedString(code),
                        fonts: config.codeBlockConfig.codeTextFonts,
                        foreground: NSColor(foregroundColor))
    #else
    if #available(iOS 16.1, *) {
      Text(attributedString ?? AttributedString(code))
        .font(config.codeBlockConfig.codeTextFonts)
        .transition(.opacity)
    } else {
      Text(code)
        .font(config.codeBlockConfig.codeTextFonts)
        .foregroundStyle(Color.Theme.Component.CodeBlock.Foreground.FunctionParameter)
    }
    #endif
  }

  @ViewBuilder
  var codeblock: some View {
    Group {
      if config.codeBlockConfig.wrapsLines {
        codeText
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        ScrollView(.horizontal) { codeText.fixedSize(horizontal: true, vertical: false) }
      }
    }.transaction { $0.animation = nil }
      .padding(16)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        Text(language)
          .font(config.codeBlockConfig.chromeTextFonts)
          .foregroundStyle(foregroundColor)
        Spacer()
        Button {
          copied = true
          #if canImport(UIKit)
          UIPasteboard.general.string = code
          #elseif canImport(AppKit)
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
          #endif
          onCodeCopied?()
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 16)).foregroundStyle(foregroundColor).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .help(copied ? config.codeBlockConfig.copiedLabel : config.codeBlockConfig.copyLabel)
          .accessibilityLabel(copied ? config.codeBlockConfig.copiedLabel : config.codeBlockConfig.copyLabel)
      }.frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
          backgroundColor
            .clipShape(.rect(
              topLeadingRadius: 20,
              bottomLeadingRadius: 0,
              bottomTrailingRadius: 0,
              topTrailingRadius: 20
            ))
        )
      codeblock
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.automatic)
        .if(backgroundColor != nil, content: { view in
          let color = backgroundColor ?? Color.clear
          return view.background(color
            .clipShape(.rect(
              topLeadingRadius: 0,
              bottomLeadingRadius: 20,
              bottomTrailingRadius: 20,
              topTrailingRadius: 0
            ))
          )
        })
    }.onChange(of: copied, perform: { isCopied in
      if isCopied {
        Task {
          try await Task.sleep(seconds: 3)
          copied = false
        }
      }
    })
    // One resolved request replaces competing code/config/appearance callbacks.
    // Font, wrapping and chrome changes do not redo syntax highlighting.
    .task(id: highlightRequest) { await updateAttributedString(highlightRequest) }
    .onDisappear { activeHighlight = nil }
  }
}

#if canImport(AppKit)
/// Native attributed code text for selection and accessibility in the lazy
/// transcript. Measurement uses
/// a separate layout stack and never changes the displayed view's intrinsic size.
struct CodeBlockNativeText: NSViewRepresentable {
  let content: AttributedString
  let fonts: TextFonts
  let foreground: NSColor

  final class NativeText: NSTextView {
    override var intrinsicContentSize: NSSize {
      NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
  }

  func makeNSView(context: Context) -> NativeText {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.heightTracksTextView = false
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    let view = NativeText(frame: .zero, textContainer: container)
    view.isEditable = false
    view.isSelectable = true
    view.isRichText = true
    view.usesFontPanel = false
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.isVerticallyResizable = false
    view.isHorizontallyResizable = false
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: NativeText, context: Context) {
    let value = NSMutableAttributedString(attributedString: NSAttributedString(content))
    let range = NSRange(location: 0, length: value.length)
    value.addAttribute(.font, value: fonts.normal, range: range)
    if let spacing = fonts.preferredLetterSpacing {
      value.addAttribute(.kern, value: spacing, range: range)
    }
    if let lineHeight = fonts.preferredLineHeight, lineHeight > fonts.normal.lineHeight {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = lineHeight - fonts.normal.lineHeight
      value.addAttribute(.paragraphStyle, value: paragraph, range: range)
    }
    value.enumerateAttribute(.foregroundColor, in: range) { color, run, _ in
      if color == nil { value.addAttribute(.foregroundColor, value: foreground, range: run) }
    }
    guard view.attributedString() != value else { return }
    let sameText = view.string == value.string
    let selection = view.selectedRanges
    view.textStorage?.setAttributedString(value)
    if sameText { view.selectedRanges = selection }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeText, context: Context) -> CGSize? {
    let width = proposal.width ?? CGFloat.greatestFiniteMagnitude
    guard width > 0, width.isFinite else { return .zero }
    let storage = NSTextStorage(attributedString: nsView.attributedString())
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    return CGSize(width: ceil(used.width), height: ceil(used.height))
  }
}
#endif

#if DEBUG

#Preview {
  return LazyVStack {
    Spacer()
    CodeBlockView(language: "Python", code: "import random\n\ndef generate_and_add_numbers(num_numbers):\n    # Generate a list of random numbers random_numbers\n    random_numbers = [random.randint(1, 100) for _ in range(num_numbers)]\n\n\n    # Add the numbers together\n    sum_of_numbers = sum(random_numbers)\n\n    return random_numbers, sum_of_numbers\n\n# Example: Generate 5 random numbers and add them together\nnum_numbers = 5\nrandom_numbers, sum_of_numbers = generate_and_add_numbers(num_numbers)\nprint(f\"Generated numbers: {random_numbers}\")\nprint(f\"Sum of numbers: {sum_of_numbers}\")")
    Spacer()
  }.padding(24)
}

#endif
