import Foundation

/// A fixed app resource; no CDN, npm, external diagrams or host bridge.
enum ChatMermaidDocument {
    static func librarySource() throws -> String {
        guard let url = Bundle.module.url(forResource: "mermaid-11.12.1.min", withExtension: "js", subdirectory: "Mermaid") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func document(_ source: String) throws -> String {
        guard source.utf8.count <= 65_536 else { throw ChatArtifactWebPreviewError.sourceTooLarge }
        // JSON is data, not HTML or executable interpolation. Escape '<' so a
        // diagram cannot terminate the containing script element.
        let bytes = try JSONEncoder().encode(source)
        let literal = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
        <div id="diagram"></div><pre id="diagram-error"></pre>
        <script>
        (async () => {
          try {
            mermaid.initialize({startOnLoad:false, securityLevel:'strict',
              maxTextSize:65536, maxEdges:500, suppressErrorRendering:true,
              secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','suppressErrorRendering'],
              flowchart:{htmlLabels:false}});
            const result = await mermaid.render('d-diagram', \(literal));
            document.getElementById('diagram').innerHTML = result.svg;
            document.getElementById('diagram').dataset.ready = 'yes';
          } catch (error) {
            document.getElementById('diagram-error').textContent = String(error);
          }
        })();
        </script>
        """
    }
}
