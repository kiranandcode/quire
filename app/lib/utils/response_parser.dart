/// Parses a Claude response into segments: markdown text, LaTeX code blocks, SVG blocks.
library;

class ResponseSegment {
  final String type; // 'markdown', 'latex', 'svg'
  final String content;

  ResponseSegment({required this.type, required this.content});
}

/// Parse Claude's response text into segments.
///
/// Splits on ```latex and ```svg code blocks.
/// Everything else is treated as markdown text.
List<ResponseSegment> parseResponse(String text) {
  final segments = <ResponseSegment>[];
  // Match both closed ```...``` and unclosed ``` blocks (truncated responses)
  // Do NOT use multiLine — it makes $ match end-of-line, truncating multi-line blocks
  final codeBlockPattern = RegExp(
    r'```(latex|svg)\n([\s\S]*?)(?:```|$)',
  );

  int lastEnd = 0;
  for (final match in codeBlockPattern.allMatches(text)) {
    // Add markdown segment before this code block
    if (match.start > lastEnd) {
      final md = text.substring(lastEnd, match.start).trim();
      if (md.isNotEmpty) {
        segments.add(ResponseSegment(type: 'markdown', content: md));
      }
    }

    // Add the code block segment
    final blockType = match.group(1)!; // 'latex' or 'svg'
    final blockContent = match.group(2)!.trim();
    if (blockContent.isNotEmpty) {
      segments.add(ResponseSegment(type: blockType, content: blockContent));
    }

    lastEnd = match.end;
  }

  // Add trailing markdown after last code block
  if (lastEnd < text.length) {
    final md = text.substring(lastEnd).trim();
    if (md.isNotEmpty) {
      segments.add(ResponseSegment(type: 'markdown', content: md));
    }
  }

  return segments;
}

/// Check if a response contains any renderable code blocks.
bool hasRenderableBlocks(String text) {
  return RegExp(r'```(latex|svg)\n').hasMatch(text);
}
