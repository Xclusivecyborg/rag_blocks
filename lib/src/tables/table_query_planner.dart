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

  /// "Excluding Heritage", "except Online", "didn't come from Lekki".
  static final RegExp _negation = RegExp(
    r"\b(excluding|exclude|excludes|except|other than|apart from|aside from|"
    r"besides|without|minus|not|non)\b|n't\b",
    caseSensitive: false,
  );

  /// A condition on a number: "weeks with at least 40 units", "above 1m".
  static final RegExp _condition = RegExp(
    r'\b(more|less|fewer|greater|higher|lower|bigger|smaller) than\b|'
    r'\bat (least|most)\b|\b(above|below|exceed|exceeds|exceeded|exceeding|'
    r'or more|or less|or fewer)\b|[<>]',
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

  /// Short forms people type, in [_months] order. Without them "jan 2026"
  /// finds only the year, and the whole year gets totalled as January.
  static const List<List<String>> _monthAbbreviations = [
    ['jan'],
    ['feb'],
    ['mar'],
    ['apr'],
    [],
    ['jun'],
    ['jul'],
    ['aug'],
    ['sep', 'sept'],
    ['oct'],
    ['nov'],
    ['dec'],
  ];

  /// Every word that names month `i`, full name first.
  static List<String> _monthNames(int i) => [
    _months[i],
    ..._monthAbbreviations[i],
  ];

  /// Question words mapped to column-name words, so "sales" can reach a
  /// `revenue` column. Kept short on purpose: every synonym is another
  /// question the planner might wrongly claim.
  ///
  /// Pass your own `synonyms` to [answer] or [planFor] for the words your
  /// users and columns use, such as `{'naira': ['ngn']}`.
  static const Map<String, List<String>> defaultSynonyms = {
    'sales': ['revenue'],
    'earned': ['revenue'],
    'income': ['revenue'],
    'turnover': ['revenue'],
    'sold': ['units', 'sold'],
    'returns': ['returned'],
    'refunds': ['returned'],
  };

  /// Answers an aggregation question ("total revenue in January") exactly
  /// from the first of [tables] that can. Null when none can answer or no
  /// rows matched, so the caller falls back to retrieval.
  static QueryResult? answer(
    List<CsvTable> tables,
    String question, {
    Map<String, List<String>> synonyms = defaultSynonyms,
  }) {
    for (final table in tables) {
      final query = planFor(table, question, synonyms: synonyms);
      final result = query == null ? null : table.aggregate(query);
      if (result != null && !result.isEmpty) return result;
    }
    return null;
  }

  /// The query [question] asks of [table], or null when it is not clearly a
  /// calculation over one of its columns. See [answer].
  static TableQuery? planFor(
    CsvTable table,
    String question, {
    Map<String, List<String>> synonyms = defaultSynonyms,
  }) {
    if (table.rowCount == 0) return null;
    final q = question.toLowerCase();

    // Each of these changes which rows count in a way a [TableQuery] cannot
    // express. Leaving it out gives a confident wrong number ("excluding
    // Heritage" summing only Heritage), so decline and let retrieval try.
    if (_negation.hasMatch(q) || _condition.hasMatch(q)) return null;
    if (_hasUnplacedDate(q)) return null;

    final aggregate = _findAggregate(q);
    if (aggregate == null) return null;

    final metric = aggregate == Aggregate.count
        ? null
        : _findMetricColumn(table, q, synonyms);
    // "How much annual leave do staff get?" has an aggregation word but no
    // matching column, so it is not a table question.
    if (aggregate != Aggregate.count && metric == null) return null;

    final filters = _findFilters(table, question);
    // "Heritage and Formal" names two values of one column, and a filter
    // holds one. Using the first would drop the other half.
    if (filters == null) return null;
    // "How many records for Lekki?" asks about a place this table does not
    // have. Ignoring the name would count every row, so decline instead.
    if (_namesSomethingMissing(table, question, synonyms)) return null;
    // "Revenue for Ikeja" means `Ikeja City Mall`, but only the whole name
    // becomes a filter. Ignoring the part would total every location.
    if (_namesPartOfAValue(table, question, filters)) return null;
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
  static CsvColumn? _findMetricColumn(
    CsvTable table,
    String q,
    Map<String, List<String>> synonyms,
  ) {
    final words = q.split(RegExp(r'[^a-z0-9]+')).toSet();
    final expanded = {...words, for (final w in words) ...?synonyms[w]};

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

  /// Text-column values that appear in the question, one per column. Null
  /// when a column has two, since a filter matches a single value.
  static List<ColumnFilter>? _findFilters(CsvTable table, String question) {
    final filters = <ColumnFilter>[];
    for (final col in table.textColumns) {
      ColumnFilter? found;
      for (final value in table.distinctValues(col)) {
        if (value.length < 3) continue; // too short to match reliably
        final pattern = RegExp(
          r'\b' + RegExp.escape(value) + r'\b',
          caseSensitive: false,
        );
        if (!pattern.hasMatch(question)) continue;
        if (found != null) return null;
        found = ColumnFilter(col.name, value);
      }
      if (found != null) filters.add(found);
    }
    return filters;
  }

  /// Words too common to say which value a question means: "the" in
  /// `The Palms` does not make every question about The Palms.
  static const Set<String> _commonWords = {'the', 'and', 'for', 'with'};

  /// True if [question] uses a word from a multi-word value without naming
  /// the whole value, like "Ikeja" for `Ikeja City Mall` or "Abuja" for
  /// `Wuse 2 Abuja`. Only whole values become filters (see [_findFilters]).
  static bool _namesPartOfAValue(
    CsvTable table,
    String question,
    List<ColumnFilter> filters,
  ) {
    final asked = _words(question).toSet();
    final ignored = {
      ..._commonWords,
      for (final f in filters) ..._words(f.value),
      for (final col in table.columns) ...col.nameWords,
    };
    for (final col in table.textColumns) {
      for (final value in table.distinctValues(col)) {
        final parts = _words(value).toList();
        if (parts.length < 2) continue; // a one-word value is all or nothing
        final partial = parts.any(
          (w) => w.length >= 3 && !ignored.contains(w) && asked.contains(w),
        );
        if (partial) return true;
      }
    }
    return false;
  }

  /// A capitalised name after "for", "in", "at" or "from", as in "revenue
  /// for Lekki" or "sales at Port Harcourt". This is where questions name
  /// the rows they want, so a name found there must match something in the
  /// table. Names elsewhere ("Acme's revenue") are not checked, and neither
  /// are lower-case ones, which cannot be told apart from ordinary words.
  static final RegExp _namedAfterPreposition = RegExp(
    r'\b(?:[Ff]or|[Ii]n|[Aa]t|[Ff]rom)\s+(?:the\s+)?([A-Z][A-Za-z0-9-]*)',
  );

  /// True if [question] names something, the way [_namedAfterPreposition]
  /// describes, that is not a value, column, month or quarter in [table].
  static bool _namesSomethingMissing(
    CsvTable table,
    String question,
    Map<String, List<String>> synonyms,
  ) {
    final names = [
      for (final m in _namedAfterPreposition.allMatches(question)) m.group(1)!,
    ];
    if (names.isEmpty) return false;
    final known = <String>{
      ..._months,
      for (final short in _monthAbbreviations) ...short,
      'q1',
      'q2',
      'q3',
      'q4',
      for (final col in table.columns) ...col.nameWords,
      for (final col in table.textColumns)
        for (final value in table.distinctValues(col)) ..._words(value),
      for (final MapEntry(:key, :value) in synonyms.entries) ...[key, ...value],
    };
    return names.any((name) => !_words(name).every(known.contains));
  }

  static Iterable<String> _words(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty);

  static final RegExp _year = RegExp(r'\b(20\d{2})\b');
  static final RegExp _quarter = RegExp(r'\bq([1-4])\b');

  /// "Last month", "this year", "so far", "the most recent week".
  static final RegExp _relativeDate = RegExp(
    r'\b(last|this|next|previous|past|current)\s+(week|month|quarter|year)s?\b|'
    r'\b(ytd|year to date|to date|so far|today|yesterday|recent|recently|'
    r'latest)\b',
  );

  /// Words that make a span the planner cannot build: "since February",
  /// "between January and March".
  static final RegExp _rangeWord = RegExp(
    r'\b(since|until|till|through|thru|between|before|after)\b',
  );

  /// Periods written in words rather than as a month or `q1`: "the first
  /// quarter", "H1", "FY26".
  static final RegExp _periodInWords = RegExp(
    r'\b(quarter|quarters|half|h1|h2|fiscal|fy\d*)\b',
  );

  /// "01/2026", "2026-02", "jan '26".
  static final RegExp _numericDate = RegExp(
    r"\b\d{1,2}/\d{2,4}\b|\b\d{4}[-/]\d{1,2}\b|'\d{2}\b",
  );

  /// A single day, "5 january" or "jan 5th", which a month range overstates.
  static final RegExp _dayOfMonth = () {
    final names = [for (var i = 0; i < 12; i++) ..._monthNames(i)].join('|');
    return RegExp(
      '\\b\\d{1,2}(st|nd|rd|th)?\\s+(of\\s+)?($names)\\b|'
      '\\b($names)\\.?\\s+\\d{1,2}(st|nd|rd|th)?\\b',
    );
  }();

  /// Indexes into [_months] of every month [q] names.
  static Set<int> _monthsIn(String q) => {
    for (var i = 0; i < _months.length; i++)
      if (_monthNames(i).any((n) => RegExp('\\b$n\\b').hasMatch(q))) i,
  };

  /// True if [q] talks about time in a way [_findDateRange] cannot turn into
  /// one range. Without this, "january" with no year, "last month" or "jan to
  /// feb 2026" each fall back to a wider range and total the wrong rows.
  static bool _hasUnplacedDate(String q) {
    if (_relativeDate.hasMatch(q) || _rangeWord.hasMatch(q)) return true;
    if (_periodInWords.hasMatch(q) || _numericDate.hasMatch(q)) return true;
    if (_dayOfMonth.hasMatch(q)) return true;

    final months = _monthsIn(q).length;
    final quarters = {for (final m in _quarter.allMatches(q)) m[1]}.length;
    final years = {for (final m in _year.allMatches(q)) m[1]}.length;
    if (months + quarters > 1 || years > 1) return true;
    // A month or quarter needs a year, or it would span every year.
    return years == 0 && months + quarters > 0;
  }

  /// "january 2026", "jan 2026", "q1 2026" or "2026". Assumes
  /// [_hasUnplacedDate] passed, so there is at most one month or quarter.
  static DateRange? _findDateRange(String q) {
    final yearMatch = _year.firstMatch(q);
    if (yearMatch == null) return null;
    final year = int.parse(yearMatch.group(1)!);

    // DateTime rolls month 13 over into January of the next year.
    for (final i in _monthsIn(q)) {
      final name = _months[i];
      return DateRange(
        DateTime(year, i + 1),
        DateTime(year, i + 2),
        '${name[0].toUpperCase()}${name.substring(1)} $year',
      );
    }

    final quarterMatch = _quarter.firstMatch(q);
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
