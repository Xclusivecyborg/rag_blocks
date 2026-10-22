import 'dart:io';

import 'package:test/test.dart';
import 'package:rag_blocks/rag_blocks.dart';

/// Ground truth computed independently from test/fixtures/sales_q1_2026.csv.
/// If these ever disagree with the app, the app is wrong.
const int kTotalRows = 240;
const int kJanuaryRevenue = 71882000;
const int kQ1Revenue = 204740500;
const int kJanuaryRows = 80;

late CsvTable sales;

/// A month of 2026, as a date range.
DateRange month2026(int month, String name) =>
    DateRange(DateTime(2026, month), DateTime(2026, month + 1), '$name 2026');

final january = month2026(1, 'January');
final q1 = DateRange(DateTime(2026), DateTime(2026, 4), 'Q1 2026');

TableQuery revenue({
  Aggregate aggregate = Aggregate.sum,
  DateRange? range,
  List<ColumnFilter> filters = const [],
  String? groupBy,
}) => TableQuery(
  aggregate: aggregate,
  metric: 'revenue_ngn',
  range: range,
  filters: filters,
  groupBy: groupBy,
);

void main() {
  setUpAll(() {
    sales = CsvTable.parse(
      File('test/fixtures/sales_q1_2026.csv').readAsStringSync(),
      source: 'sales_q1_2026.csv',
    );
  });

  group('parsing', () {
    test('reads every data row', () {
      expect(sales.rowCount, kTotalRows);
    });

    test('infers column kinds', () {
      expect(sales.column('week_starting')!.kind, ColumnKind.date);
      expect(sales.column('revenue_ngn')!.kind, ColumnKind.number);
      expect(sales.column('units_sold')!.kind, ColumnKind.number);
      expect(sales.column('location')!.kind, ColumnKind.text);
      expect(sales.column('product_line')!.kind, ColumnKind.text);
    });

    test('a column with one non-numeric cell stays text', () {
      // Safer than averaging over whichever rows happened to parse.
      final t = CsvTable.parse('a,b\n1,2\n3,unknown\n', source: 'x.csv');
      expect(t.column('a')!.kind, ColumnKind.number);
      expect(t.column('b')!.kind, ColumnKind.text);
    });

    test('large whole numbers are numbers, not dates', () {
      // DateTime.tryParse reads 8 digits like 71882000 as a year and month.
      final t = CsvTable.parse(
        'location,revenue\nIkeja,71882000\nLekki,12000000\n',
        source: 'x.csv',
      );
      expect(t.column('revenue')!.kind, ColumnKind.number);
      final total = t.aggregate(
        const TableQuery(aggregate: Aggregate.sum, metric: 'revenue'),
      )!;
      expect(total.value, 83882000);
    });

    test('handles quoted fields with commas', () {
      final t = CsvTable.parse('name,note\n"Doe, Jane",hi\n', source: 'x.csv');
      expect(t.rows.single.first, 'Doe, Jane');
    });

    test('survives a round trip through JSON', () {
      final restored = CsvTable.decodeAll(CsvTable.encodeAll([sales])).single;
      expect(restored.rowCount, sales.rowCount);
      expect(restored.column('revenue_ngn')!.kind, ColumnKind.number);
    });

    test('corrupt JSON yields nothing rather than throwing', () {
      expect(CsvTable.decodeAll('{not json'), isEmpty);
    });
  });

  group('arithmetic is exact', () {
    test('January 2026 revenue — the question that started this', () {
      final result = sales.aggregate(revenue(range: january))!;

      expect(result.value, kJanuaryRevenue);
      expect(result.matchedRows, kJanuaryRows);
      expect(result.totalRows, kTotalRows);
      // Retrieval saw 2 of 43 CSV chunks and answered 7,663,000.
      expect(result.value, greaterThan(9 * 7663000));
    });

    test('whole-quarter total', () {
      expect(sales.aggregate(revenue(range: q1))!.value, kQ1Revenue);
    });

    test('a filter narrows the rows', () {
      final result = sales.aggregate(
        revenue(filters: [ColumnFilter('product_line', 'Heritage')]),
      )!;

      expect(result.matchedRows, lessThan(kTotalRows));
      expect(result.value, lessThan(kQ1Revenue));
    });

    test('the sum of every month equals the quarter', () {
      var total = 0.0;
      for (final (i, name) in ['January', 'February', 'March'].indexed) {
        final range = month2026(i + 1, name);
        total += sales.aggregate(revenue(range: range))!.value;
      }
      expect(total, kQ1Revenue);
    });

    test('average is the mean of matched rows, not of all rows', () {
      final avg = sales.aggregate(
        revenue(aggregate: Aggregate.average, range: january),
      )!;
      expect(avg.matchedRows, kJanuaryRows);
      expect(avg.value, closeTo(kJanuaryRevenue / kJanuaryRows, 0.01));
    });

    test('a range matching nothing returns zero over zero rows', () {
      final result = sales.aggregate(
        revenue(
          range: DateRange(DateTime(2019), DateTime(2019, 2), 'January 2019'),
        ),
      )!;
      expect(result.matchedRows, 0);
      expect(result.value, 0);
      expect(result.isEmpty, isTrue);
    });

    test('breakdown groups add up to the ungrouped total', () {
      final grouped = sales.aggregate(
        revenue(range: january, groupBy: 'location'),
      )!;
      expect(grouped.groups, isNotNull);
      final sum = grouped.groups!.values.fold<num>(0, (a, b) => a + b);
      expect(sum, kJanuaryRevenue);
    });
  });

  group('breakdowns use the same aggregate as the headline', () {
    final t = CsvTable.parse(
      'location,revenue\nIkeja,10\nIkeja,20\nLekki,15\n',
      source: 'x.csv',
    );
    Map<String, num>? groupsFor(Aggregate aggregate) => t
        .aggregate(
          TableQuery(
            aggregate: aggregate,
            metric: aggregate == Aggregate.count ? null : 'revenue',
            groupBy: 'location',
          ),
        )!
        .groups;

    test('average', () {
      expect(groupsFor(Aggregate.average), {'Ikeja': 15, 'Lekki': 15});
    });

    test('max and min', () {
      expect(groupsFor(Aggregate.max), {'Ikeja': 20, 'Lekki': 15});
      expect(groupsFor(Aggregate.min), {'Ikeja': 10, 'Lekki': 15});
    });

    test('count', () {
      expect(groupsFor(Aggregate.count), {'Ikeja': 2, 'Lekki': 1});
    });
  });

  group('min and max say which row they came from', () {
    final t = CsvTable.parse(
      'location,revenue\nIkeja,10\nLekki,30\nYaba,20\n',
      source: 'x.csv',
    );

    test('the highest row is reported', () {
      final result = t.aggregate(
        const TableQuery(aggregate: Aggregate.max, metric: 'revenue'),
      )!;
      expect(result.value, 30);
      expect(result.extremeRow, {'location': 'Lekki', 'revenue': '30'});
      expect(result.toPromptBlock(), contains('location=Lekki'));
    });

    test('the lowest row is reported', () {
      final result = t.aggregate(
        const TableQuery(aggregate: Aggregate.min, metric: 'revenue'),
      )!;
      expect(result.extremeRow!['location'], 'Ikeja');
    });

    test('other aggregates have no single row', () {
      final result = t.aggregate(
        const TableQuery(aggregate: Aggregate.sum, metric: 'revenue'),
      )!;
      expect(result.extremeRow, isNull);
    });
  });

  group('presentation', () {
    test('numbers are grouped for reading', () {
      expect(QueryResult.formatNumber(71882000), '71,882,000');
      expect(QueryResult.formatNumber(999), '999');
      expect(QueryResult.formatNumber(-1234), '-1,234');
    });

    test('the prompt block states the coverage, not just the figure', () {
      final block = sales.aggregate(revenue(range: january))!.toPromptBlock();

      expect(block, contains('71,882,000'));
      expect(block, contains('January 2026'));
      // The model must be told this covers everything, or it hedges anyway.
      expect(block, contains('$kJanuaryRows matching row'));
      expect(block, contains('$kTotalRows'));
    });
  });
}
