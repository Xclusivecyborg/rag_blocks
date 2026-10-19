/// A piece of a document, ready to be embedded.
class Chunk {
  const Chunk({
    required this.text,
    required this.source,
    required this.index,
    this.start = 0,
    this.end = 0,
  });

  final String text;
  final String source; // file name
  final int index; // position within the file

  /// Character range `[start, end)` of this chunk in the file on disk.
  ///
  /// [text] can differ slightly from that range: whitespace between
  /// paragraphs is normalised, and it may begin with overlap copied from the
  /// previous chunk, which lies before [start].
  final int start;
  final int end;
}

/// Maximum characters per chunk (roughly 150 tokens).
///
/// Smaller chunks match short questions better, because each one is about
/// fewer things. Measured on a five-file test knowledge base:
///
/// | size | short questions retrieving | canonical hit@1 |
/// |------|----------------------------|-----------------|
/// | 1200 | 6/12                       | 11/12           |
/// | 600  | 10/12                      | 11/12           |
/// | 350  | 10/12                      | 12/12           |
///
/// The retrieval thresholds were measured at this size. Re-measure them (see
/// `RetrievalSettings.measuredThresholds`) if you change it.
const int defaultChunkSize = 600;

/// Characters repeated from the end of one chunk at the start of the next, so
/// a fact that straddles a boundary still appears whole in one chunk. Shrinks
/// when the next block leaves less room, so a chunk never exceeds its size.
const int defaultChunkOverlap = 200;

final RegExp _paragraphBreak = RegExp(r'\n\s*\n');

// After . ! or ? followed by whitespace, or at a single newline (CSV-derived
// text has one record per line).
final RegExp _sentenceBreak = RegExp(r'(?<=[.!?])\s+|\n');

/// Splits text into overlapping chunks of at most [chunkSize] characters.
///
/// Breaks on paragraphs first, then sentences, and cuts mid-word only when a
/// run of text has no break at all. Same idea and same name as LangChain's
/// `RecursiveCharacterTextSplitter`, except the overlap is filled as far as
/// room allows instead of being dropped when the last paragraph is too big.
///
/// ```dart
/// final splitter = RecursiveCharacterTextSplitter(chunkSize: 600);
/// final chunks = splitter.splitText(text, source: 'handbook.md');
/// ```
class RecursiveCharacterTextSplitter {
  const RecursiveCharacterTextSplitter({
    this.chunkSize = defaultChunkSize,
    this.chunkOverlap = defaultChunkOverlap,
  });

  final int chunkSize;
  final int chunkOverlap;

  List<Chunk> splitText(String text, {required String source}) => chunkDocument(
    text,
    source: source,
    chunkSize: chunkSize,
    chunkOverlap: chunkOverlap,
  );
}

/// [RecursiveCharacterTextSplitter.splitText] as a function, for one-off use.
///
/// Throws [ArgumentError] unless `0 < chunkSize` and
/// `0 <= chunkOverlap < chunkSize`.
List<Chunk> chunkDocument(
  String raw, {
  required String source,
  int chunkSize = defaultChunkSize,
  int chunkOverlap = defaultChunkOverlap,
}) {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
  }
  if (chunkOverlap < 0 || chunkOverlap >= chunkSize) {
    throw ArgumentError.value(
      chunkOverlap,
      'chunkOverlap',
      'must be at least 0 and less than chunkSize ($chunkSize)',
    );
  }
  final unified = raw.replaceAll('\r\n', '\n');
  final text = unified.trim();
  if (text.isEmpty) return const [];

  final leading = unified.length - unified.trimLeft().length;
  final droppedCarriageReturns = _droppedCarriageReturns(raw);
  int toFileOffset(int i) => _toFileOffset(i, leading, droppedCarriageReturns);

  final chunks = <Chunk>[];
  final buffer = StringBuffer();
  var start = 0, end = 0;
  var hasOwnText = false; // false while the buffer holds only overlap
  var overlap = ''; // end of the previous chunk, not yet written

  void finishChunk() {
    final body = buffer.toString().trim();
    buffer.clear();
    hasOwnText = false;
    overlap = '';
    if (body.isEmpty) return;
    chunks.add(
      Chunk(
        text: body,
        source: source,
        index: chunks.length,
        start: toFileOffset(start),
        end: toFileOffset(end),
      ),
    );
    if (chunkOverlap > 0 && body.length > chunkOverlap) {
      overlap = _lastChars(body, chunkOverlap);
    }
  }

  for (final block in _splitIntoBlocks(text, chunkSize)) {
    if (hasOwnText && buffer.length + block.text.length > chunkSize) {
      finishChunk();
    }
    if (!hasOwnText && overlap.isNotEmpty) {
      // Carry as much overlap as still leaves room for this block.
      final room = chunkSize - block.text.length - 2; // 2 for the '\n\n' join
      if (room > 0) {
        buffer
          ..write(overlap.length <= room ? overlap : _lastChars(overlap, room))
          ..write('\n\n');
      }
      overlap = '';
    }
    if (!hasOwnText) start = block.start;
    end = block.end;
    hasOwnText = true;
    buffer
      ..write(block.text)
      ..write('\n\n');
  }
  finishChunk();
  return chunks;
}

/// A piece of text and its offsets in the normalised document.
class _Block {
  const _Block(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

/// Paragraphs, with any paragraph longer than [maxLength] split by sentence.
List<_Block> _splitIntoBlocks(String text, int maxLength) => [
  for (final paragraph in _splitOn(text, _paragraphBreak, 0))
    if (paragraph.text.length <= maxLength)
      paragraph
    else
      ..._splitSentences(paragraph, maxLength),
];

/// Groups the sentences of [paragraph] into blocks of at most [maxLength],
/// hard-cutting any single sentence that is longer.
List<_Block> _splitSentences(_Block paragraph, int maxLength) {
  final blocks = <_Block>[];
  final buffer = StringBuffer();
  var start = 0, end = 0;
  var hasText = false;

  void finishBlock() {
    if (!hasText) return;
    final body = buffer.toString().trim();
    buffer.clear();
    hasText = false;
    if (body.isNotEmpty) blocks.add(_Block(body, start, end));
  }

  final sentences = _splitOn(paragraph.text, _sentenceBreak, paragraph.start);
  for (final sentence in sentences) {
    if (sentence.text.length > maxLength) {
      finishBlock();
      for (var i = 0; i < sentence.text.length; i += maxLength) {
        final stop = (i + maxLength).clamp(0, sentence.text.length);
        blocks.add(
          _Block(
            sentence.text.substring(i, stop),
            sentence.start + i,
            sentence.start + stop,
          ),
        );
      }
      continue;
    }
    if (hasText && buffer.length + sentence.text.length > maxLength) {
      finishBlock();
    }
    if (!hasText) start = sentence.start;
    end = sentence.end;
    hasText = true;
    buffer
      ..write(sentence.text)
      ..write(' ');
  }
  finishBlock();
  return blocks;
}

/// Splits [text] on [pattern] into trimmed pieces, each with its offset.
/// [base] is added to every offset, so a paragraph split into sentences still
/// reports positions in the whole document.
List<_Block> _splitOn(String text, RegExp pattern, int base) {
  final pieces = <_Block>[];

  void add(int from, int to) {
    final slice = text.substring(from, to);
    final body = slice.trim();
    if (body.isEmpty) return;
    final at = base + from + slice.length - slice.trimLeft().length;
    pieces.add(_Block(body, at, at + body.length));
  }

  var cursor = 0;
  for (final match in pattern.allMatches(text)) {
    add(cursor, match.start);
    cursor = match.end;
  }
  add(cursor, text.length);
  return pieces;
}

/// Roughly the last [n] characters of [text], starting at a word boundary.
String _lastChars(String text, int n) {
  final slice = text.substring(text.length - n);
  final space = slice.indexOf(' ');
  return space == -1 ? slice : slice.substring(space + 1);
}

/// Offsets in the normalised text where a `\r` was removed from a `\r\n`.
List<int> _droppedCarriageReturns(String raw) {
  if (!raw.contains('\r')) return const [];
  final positions = <int>[];
  for (var i = 0; i + 1 < raw.length; i++) {
    if (raw.codeUnitAt(i) == 0x0D && raw.codeUnitAt(i + 1) == 0x0A) {
      positions.add(i - positions.length);
    }
  }
  return positions;
}

/// Maps an offset in the trimmed, normalised text back to the file on disk,
/// counting every `\r` removed strictly before it.
int _toFileOffset(int offset, int leading, List<int> droppedCarriageReturns) {
  final untrimmed = offset + leading;
  // Binary search: how many dropped positions are before `untrimmed`.
  var lo = 0, hi = droppedCarriageReturns.length;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (droppedCarriageReturns[mid] < untrimmed) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return untrimmed + lo;
}
