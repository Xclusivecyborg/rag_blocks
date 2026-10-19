import 'csv_table.dart';

/// Turns a question into a [TableQuery], or returns null when it is not one.
///
/// Returning null matters most: a planner that always answers would reply to
/// "how much annual leave do staff get?" with the sum of a sales column. So a
/// query is only produced when the question clearly names an aggregation and
/// a column that exists; otherwise the caller falls back to retrieval.
///
/// Rule-based rather than a model call, so it is fast and testable.
abstract final class TableQueryPlanner {
  static final RegExp _sumIntent = RegExp(
    r'\b(total|totals|sum|combined|altogether|overall|how much|revenue for|'
    r'how many)\b',
    caseSensitive: false,
  );

  static final RegExp _averageIntent = RegExp(
    r'\b(average|avg|mean|typical|per week|per month)\b',
    caseSensitive: false,
  );

  static final RegExp _maxIntent = RegExp(
    r'\b(highest|most|maximum|max|best|top|largest)\b',
    caseSensitive: false,
  );

  static final RegExp _minIntent = RegExp(
    r'\b(lowest|least|minimum|min|worst|smallest|fewest)\b',
    caseSensitive: false,
  );

  static final RegExp _countIntent = RegExp(
    r'\b(how many (records|rows|entries|transactions|weeks)|number of '
    r'(records|rows|entries|transactions))\b',
    caseSensitive: false,
  );

  static final RegExp _breakdownIntent = RegExp(
    r'\b(by|per|each|breakdown|broken down)\b',
    caseSensitive: false,
  );

  static const List<String> _months = [
    'january',
    'february',
    'march',
    'april',
    'may',
    'june',
    'july',
    'august',
    'september',
    'october',
    'november',
    'december',
  ];

  /// Question words mapped to column-name words, so "sales" can reach a
  /// `revenue_ngn` column. Kept short on purpose: every synonym is another
  /// question the planner might wrongly claim.
  static const Map<String, List<String>> _synonyms = {
    'sales': ['revenue'],
    'earned': ['revenue'],
    'income': ['revenue'],
    'turnover': ['revenue'],
    'naira': ['ngn'],
    'sold': ['units', 'sold'],
    'returns': ['returned'],
    'refunds': ['returned'],
    'price': ['price'],
  };

  /// Answers an aggregation question ("total revenue in January") exactly
  /// from the first of [tables] that can. Null when none can answer or no
  /// rows matched, so the caller falls back to retrieval.
  static QueryResult? answer(List<CsvTable> tables, String question) {
    for (final table in tables) {
      final query = planFor(table, question);
      final result = query == null ? null : table.aggregate(query);
      if (result != null && !result.isEmpty) return result;
    }
    return null;
  }

  static TableQuery? planFor(CsvTable table, String question) {
    if (table.rowCount == 0) return null;
    final q = question.toLowerCase();

    final aggregate = _findAggregate(q);
    if (aggregate == null) return null;

    final metric = aggregate == Aggregate.count
        ? null
        : _findMetricColumn(table, q);
    // "How much annual leave do staff get?" has an aggregation word but no
    // matching column, so it is not a table question.
    if (aggregate != Aggregate.count && metric == null) return null;

    final filters = _findFilters(table, question);
    return TableQuery(
      aggregate: aggregate,
      metric: metric?.name,
      filters: filters,
      range: table.dateColumn == null ? null : _findDateRange(q),
      groupBy: _findGroupBy(table, q, filters),
    );
  }

  static Aggregate? _findAggregate(String q) {
    // Order matters: "lowest total" is a min, not a sum.
    if (_countIntent.hasMatch(q)) return Aggregate.count;
    if (_minIntent.hasMatch(q)) return Aggregate.min;
    if (_maxIntent.hasMatch(q)) return Aggregate.max;
    if (_averageIntent.hasMatch(q)) return Aggregate.average;
    if (_sumIntent.hasMatch(q)) return Aggregate.sum;
    return null;
  }

  /// The numeric column whose name best matches the question. Null on a tie,
  /// because guessing between `revenue_ngn` and `unit_price_ngn` gives a
  /// plausible, wrong number.
  static CsvColumn? _findMetricColumn(CsvTable table, String q) {
    final words = q.split(RegExp(r'[^a-z0-9]+')).toSet();
    final expanded = {...words, for (final w in words) ...?_synonyms[w]};

    CsvColumn? best;
    var bestScore = 0;
    var tied = false;
    for (final col in table.numericColumns) {
      final score = col.nameWords.where(expanded.contains).length;
      if (score == 0) continue;
      if (score > bestScore) {
        best = col;
        bestScore = score;
        tied = false;
      } else if (score == bestScore) {
        tied = true;
      }
    }
    return tied ? null : best;
  }

  /// Text-column values that appear in the question, at most one per column.
  static List<ColumnFilter> _findFilters(CsvTable table, String question) {
    final filters = <ColumnFilter>[];
    for (final col in table.textColumns) {
      for (final value in table.distinctValues(col)) {
        if (value.length < 3) continue; // too short to match reliably
        final pattern = RegExp(
          r'\b' + RegExp.escape(value) + r'\b',
          caseSensitive: false,
        );
        if (pattern.hasMatch(question)) {
          filters.add(ColumnFilter(col.name, value));
          break;
        }
      }
    }
    return filters;
  }

  /// "january 2026", "q1 2026" or "2026". A year is required, so a bare month
  /// never silently covers every year in the data.
  static DateRange? _findDateRange(String q) {
    final yearMatch = RegExp(r'\b(20\d{2})\b').firstMatch(q);
    if (yearMatch == null) return null;
    final year = int.parse(yearMatch.group(1)!);

    // DateTime rolls month 13 over into January of the next year.
    for (var i = 0; i < _months.length; i++) {
      final name = _months[i];
      if (!RegExp('\\b$name\\b').hasMatch(q)) continue;
      return DateRange(
        DateTime(year, i + 1),
        DateTime(year, i + 2),
        '${name[0].toUpperCase()}${name.substring(1)} $year',
      );
    }

    final quarterMatch = RegExp(r'\bq([1-4])\b').firstMatch(q);
    if (quarterMatch != null) {
      final quarter = int.parse(quarterMatch.group(1)!);
      final firstMonth = (quarter - 1) * 3 + 1;
      return DateRange(
        DateTime(year, firstMonth),
        DateTime(year, firstMonth + 3),
        'Q$quarter $year',
      );
    }

    return DateRange(DateTime(year), DateTime(year + 1), '$year');
  }

  /// A text column to break the result down by, when the question asks for a
  /// breakdown and names a column that is not already filtered on.
  static String? _findGroupBy(
    CsvTable table,
    String q,
    List<ColumnFilter> filters,
  ) {
    if (!_breakdownIntent.hasMatch(q)) return null;
    final filtered = filters.map((f) => f.column.toLowerCase()).toSet();
    for (final col in table.textColumns) {
      if (filtered.contains(col.name.toLowerCase())) continue;
      if (col.nameWords.any((w) => RegExp('\\b$w\\b').hasMatch(q))) {
        return col.name;
      }
    }
    return null;
  }
}
