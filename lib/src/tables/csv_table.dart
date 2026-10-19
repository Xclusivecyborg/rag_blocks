import 'dart:convert';

/// A CSV file kept as a table, so totals and averages can be computed exactly.
///
/// Retrieval only returns the few most similar chunks, but a total needs every
/// matching row. So CSV files are also indexed as prose (for lookups) and kept
/// here as tables (for arithmetic).
class CsvTable {
  CsvTable({required this.source, required this.columns, required this.rows});

  final String source;
  final List<CsvColumn> columns;
  final List<List<String>> rows; // raw cell text

  int get rowCount => rows.length;

  CsvColumn? column(String name) => columns
      .where((c) => c.name.toLowerCase() == name.toLowerCase())
      .firstOrNull;

  List<CsvColumn> get numericColumns =>
      columns.where((c) => c.kind == ColumnKind.number).toList();
  List<CsvColumn> get textColumns =>
      columns.where((c) => c.kind == ColumnKind.text).toList();
  CsvColumn? get dateColumn =>
      columns.where((c) => c.kind == ColumnKind.date).firstOrNull;

  String cell(int row, CsvColumn col) =>
      col.index < rows[row].length ? rows[row][col.index].trim() : '';

  num? number(int row, CsvColumn col) => num.tryParse(cell(row, col));

  DateTime? date(int row, CsvColumn col) => DateTime.tryParse(cell(row, col));

  /// Distinct non-empty values of a column, in their original casing.
  Set<String> distinctValues(CsvColumn col) => {
    for (var r = 0; r < rows.length; r++)
      if (cell(r, col).isNotEmpty) cell(r, col),
  };

  /// Parses [raw] and works out each column's kind.
  ///
  /// A column is numeric only if every non-empty cell is a number. One stray
  /// value makes it text, which is safer than averaging the cells that parsed.
  factory CsvTable.parse(String raw, {required String source}) {
    final grid = parseCsvGrid(raw);
    if (grid.isEmpty) {
      return CsvTable(source: source, columns: const [], rows: const []);
    }

    final header = grid.first;
    final body = [
      for (final row in grid.skip(1))
        if (!row.every((c) => c.trim().isEmpty)) row,
    ];

    final columns = <CsvColumn>[];
    for (var c = 0; c < header.length; c++) {
      var sawValue = false;
      var allNumbers = true;
      var allDates = true;
      for (final row in body) {
        final value = c < row.length ? row[c].trim() : '';
        if (value.isEmpty) continue;
        sawValue = true;
        if (num.tryParse(value) == null) allNumbers = false;
        if (DateTime.tryParse(value) == null) allDates = false;
        if (!allNumbers && !allDates) break;
      }
      final kind = !sawValue
          ? ColumnKind.text
          : allDates
          ? ColumnKind.date
          : allNumbers
          ? ColumnKind.number
          : ColumnKind.text;
      columns.add(CsvColumn(header[c].trim(), c, kind));
    }

    return CsvTable(source: source, columns: columns, rows: body);
  }

  /// Runs [query] over every row. Null if the query names an unknown column.
  QueryResult? aggregate(TableQuery query) {
    final isCount = query.aggregate == Aggregate.count;
    final metric = query.metric == null ? null : column(query.metric!);
    if (!isCount && metric == null) return null;
    final groupColumn = query.groupBy == null ? null : column(query.groupBy!);

    final matched = [
      for (var r = 0; r < rows.length; r++)
        if (_matches(r, query)) r,
    ];
    final values = <num>[];
    final groups = <String, num>{};
    for (final r in matched) {
      final n = isCount ? 1 : number(r, metric!);
      if (n == null) continue;
      values.add(n);
      if (groupColumn != null) {
        final key = cell(r, groupColumn);
        groups[key] = (groups[key] ?? 0) + n;
      }
    }

    final num value = values.isEmpty
        ? 0
        : switch (query.aggregate) {
            Aggregate.sum => values.reduce((a, b) => a + b),
            Aggregate.average => values.reduce((a, b) => a + b) / values.length,
            Aggregate.min => values.reduce((a, b) => a < b ? a : b),
            Aggregate.max => values.reduce((a, b) => a > b ? a : b),
            Aggregate.count => values.length,
          };

    return QueryResult(
      query: query,
      source: source,
      value: value,
      matchedRows: matched.length,
      totalRows: rows.length,
      groups: groupColumn == null ? null : groups,
    );
  }

  bool _matches(int row, TableQuery query) {
    for (final filter in query.filters) {
      final col = column(filter.column);
      if (col == null) return false;
      if (cell(row, col).toLowerCase() != filter.value.toLowerCase()) {
        return false;
      }
    }
    final range = query.range;
    if (range != null) {
      final col = dateColumn;
      final d = col == null ? null : date(row, col);
      if (d == null || d.isBefore(range.start) || !d.isBefore(range.end)) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'source': source,
    'columns': [
      for (final c in columns)
        {'name': c.name, 'index': c.index, 'kind': c.kind.name},
    ],
    'rows': rows,
  };

  factory CsvTable.fromJson(Map<String, dynamic> json) => CsvTable(
    source: json['source'] as String,
    columns: [
      for (final c in (json['columns'] as List).cast<Map<String, dynamic>>())
        CsvColumn(
          c['name'] as String,
          c['index'] as int,
          ColumnKind.values.byName(c['kind'] as String),
        ),
    ],
    rows: [for (final r in (json['rows'] as List)) (r as List).cast<String>()],
  );

  static String encodeAll(List<CsvTable> tables) => jsonEncode({
    'version': 1,
    'tables': [for (final t in tables) t.toJson()],
  });

  /// Empty if [raw] is corrupt or from an older format; the user re-indexes.
  static List<CsvTable> decodeAll(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return [
        for (final t in (json['tables'] as List).cast<Map<String, dynamic>>())
          CsvTable.fromJson(t),
      ];
    } on Object {
      return const [];
    }
  }
}

enum ColumnKind { text, number, date }

class CsvColumn {
  const CsvColumn(this.name, this.index, this.kind);
  final String name;
  final int index;
  final ColumnKind kind;

  /// The words in the column name: `revenue_ngn` gives {revenue, ngn}. Used to
  /// match columns against the words in a question.
  Set<String> get nameWords => name
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toSet();

  @override
  String toString() => '$name (${kind.name})';
}

enum Aggregate { sum, average, count, min, max }

class ColumnFilter {
  const ColumnFilter(this.column, this.value);
  final String column;
  final String value;
}

class DateRange {
  const DateRange(this.start, this.end, this.label);
  final DateTime start; // inclusive
  final DateTime end; // exclusive
  final String label;
}

class TableQuery {
  const TableQuery({
    required this.aggregate,
    this.metric,
    this.filters = const [],
    this.range,
    this.groupBy,
  });

  final Aggregate aggregate;
  final String? metric; // the column being summed, averaged, etc.
  final List<ColumnFilter> filters;
  final DateRange? range;
  final String? groupBy;

  /// The query in plain words, so the answer can say what was computed.
  String describe() {
    final verb = switch (aggregate) {
      Aggregate.sum => 'Total',
      Aggregate.average => 'Average',
      Aggregate.count => 'Number of records',
      Aggregate.min => 'Minimum',
      Aggregate.max => 'Maximum',
    };
    final what = metric == null ? '' : ' $metric';
    final where = filters.isEmpty
        ? ''
        : ' for ${filters.map((f) => '${f.column}=${f.value}').join(', ')}';
    final when = range == null ? '' : ' in ${range!.label}';
    return '$verb$what$where$when';
  }
}

class QueryResult {
  const QueryResult({
    required this.query,
    required this.source,
    required this.value,
    required this.matchedRows,
    required this.totalRows,
    this.groups,
  });

  final TableQuery query;
  final String source;
  final num value;
  final int matchedRows;
  final int totalRows;
  final Map<String, num>? groups;

  bool get isEmpty => matchedRows == 0;

  /// Formats with thousands separators, e.g. 71882000 as 71,882,000.
  static String formatNumber(num n) {
    final rounded = n is int || n == n.roundToDouble()
        ? n.round().toString()
        : n.toStringAsFixed(2);
    final parts = rounded.split('.');
    final digits = parts.first.replaceFirst('-', '');
    final buffer = StringBuffer(rounded.startsWith('-') ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    if (parts.length > 1) buffer.write('.${parts[1]}');
    return buffer.toString();
  }

  /// The figure and what it covers, as given to the chat model.
  String toPromptBlock() {
    final buffer = StringBuffer()
      ..writeln('${query.describe()}: ${formatNumber(value)}')
      ..writeln(
        'Computed over $matchedRows matching row(s) '
        'out of $totalRows in $source.',
      );
    final g = groups;
    if (g != null && g.isNotEmpty) {
      buffer.writeln('Breakdown:');
      for (final key in g.keys.toList()..sort()) {
        buffer.writeln('  $key: ${formatNumber(g[key]!)}');
      }
    }
    return buffer.toString();
  }
}

/// Minimal RFC 4180 parser: handles quoted fields, embedded commas,
/// embedded newlines, and "" escapes.
List<List<String>> parseCsvGrid(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    switch (ch) {
      case '"':
        inQuotes = true;
      case ',':
        row.add(field.toString());
        field.clear();
      case '\r':
        break;
      case '\n':
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
      default:
        field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}
