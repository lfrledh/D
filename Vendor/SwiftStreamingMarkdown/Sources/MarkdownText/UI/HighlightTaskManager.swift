//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift

actor HighlightTaskManager: ObservableObject {
  /// Shared Highlight instance to avoid creating multiple JSContext/HLJS instances.
  /// Each Highlight() creates its own JSContext and evaluates highlight.min.js (~600KB).
  /// When multiple CodeBlockViews render concurrently, N separate JSContexts cause
  /// JavaScriptCore OOM crashes (COPILOT-IOS-3F9C, 3F7Z, 3FSQ).
  private static let sharedHighlight = Highlight()

  private struct Request {
    let code: String
    let colors: HighlightColors
    let completion: @MainActor @Sendable (AttributedString) -> Void
  }
  private var latestRequest: Request?
  private var isProcessing = false
  private let highlight: @Sendable (String, HighlightColors) async -> AttributedString?

  init(highlight: @escaping @Sendable (String, HighlightColors) async -> AttributedString? = {
    try? await HighlightTaskManager.sharedHighlight.attributedText($0, colors: $1)
  }) {
    self.highlight = highlight
  }

  func enqueueCode(_ code: String, colors: HighlightColors, completion: @escaping @MainActor @Sendable (AttributedString) -> Void) {
    latestRequest = Request(code: code, colors: colors, completion: completion)

    if !isProcessing {
      Task {
        await processQueue()
      }
    }
  }

  private func processQueue() async {
    guard !isProcessing else { return }

    isProcessing = true

    while let request = latestRequest {
      latestRequest = nil

      if let result = await highlight(request.code, request.colors) {
        await request.completion(result)
      }
    }

    isProcessing = false
  }
}
