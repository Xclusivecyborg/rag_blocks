import 'csv_grid.dart';

/// Rewrites CSV rows as labelled sentences, one record per paragraph.
///
/// A raw line like `SHO-114,Lagos,2026-03-02,48` gives an embedding model
/// almost nothing to match. `Region: Lagos. Units sold: 48.` does.
String csvToProse(String csv) {
  final rows = parseCsvGrid(csv);
  if (rows.isEmpty) return '';

  final header = rows.first;
  final buffer = StringBuffer();
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    final parts = [
      for (var c = 0; c < header.length && c < row.length; c++)
        if (header[c].trim().isNotEmpty && row[c].trim().isNotEmpty)
          '${header[c].trim()}: ${row[c].trim()}',
    ];
    if (parts.isEmpty) continue;
    buffer
      ..writeln('Record $r. ${parts.join('. ')}.')
      ..writeln();
  }
  return buffer.toString();
}
