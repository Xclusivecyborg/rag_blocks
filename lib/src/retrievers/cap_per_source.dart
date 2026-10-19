import '../vector_stores/vector_store.dart';

/// The first [k] of [sorted], taking at most [maxPerSource] from any one
/// file. Stops one large file (like a 240-row CSV) filling every slot;
/// on the test knowledge base a cap of 2 lifts hit@1 from 83% to 100%.
///
/// In plain English, imagine a search over lots of documents.
/// If one file is huge—like a giant CSV with 240 rows—it may contain many matches.
///Without a limit, the algorithm could keep returning results
///from that one file and ignore other useful files.
List<ScoredChunk> capPerSource(
  List<ScoredChunk> sorted,
  int k,
  int? maxPerSource,
) {
  if (maxPerSource == null) return sorted.take(k).toList();
  final perSource = <String, int>{};
  final kept = <ScoredChunk>[];
  for (final hit in sorted) {
    final used = perSource[hit.chunk.source] ?? 0;
    if (used >= maxPerSource) continue;
    perSource[hit.chunk.source] = used + 1;
    kept.add(hit);
    if (kept.length >= k) break;
  }
  return kept;
}
