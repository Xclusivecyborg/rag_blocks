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
      final query = TableQueryPlanner.planFor(
        sales,
        "How much was Stridewell's revenue in ngn in january 2026?",
      )!;
      final result = sales.aggregate(query)!;

      expect(result.value, kJanuaryRevenue);
      expect(result.matchedRows, kJanuaryRows);
      expect(result.totalRows, kTotalRows);
      // Retrieval saw 2 of 43 CSV chunks and answered 7,663,000.
      expect(result.value, greaterThan(9 * 7663000));
    });

    test('whole-quarter total', () {
      final query = TableQueryPlanner.planFor(
        sales,
        'What was our total revenue in Q1 2026?',
      )!;
      expect(sales.aggregate(query)!.value, kQ1Revenue);
    });

    test('a filter narrows the rows', () {
      final query = TableQueryPlanner.planFor(
        sales,
        'total revenue for Heritage in 2026',
      )!;
      final result = sales.aggregate(query)!;

      expect(result.matchedRows, lessThan(kTotalRows));
      expect(result.value, lessThan(kQ1Revenue));
      expect(query.filters.single.value, 'Heritage');
    });

    test('the sum of every month equals the quarter', () {
      var total = 0.0;
      for (final month in ['january', 'february', 'march']) {
        final q = TableQueryPlanner.planFor(
          sales,
          'total revenue in $month 2026',
        )!;
        total += sales.aggregate(q)!.value;
      }
      expect(total, kQ1Revenue);
    });

    test('average is the mean of matched rows, not of all rows', () {
      final avg = sales.aggregate(
        TableQueryPlanner.planFor(sales, 'average revenue in january 2026')!,
      )!;
      expect(avg.matchedRows, kJanuaryRows);
      expect(avg.value, closeTo(kJanuaryRevenue / kJanuaryRows, 0.01));
    });

    test('a range matching nothing returns zero over zero rows', () {
      final query = TableQueryPlanner.planFor(
        sales,
        'total revenue in january 2019',
      )!;
      final result = sales.aggregate(query)!;
      expect(result.matchedRows, 0);
      expect(result.value, 0);
      expect(result.isEmpty, isTrue);
    });

    test('breakdown groups add up to the ungrouped total', () {
      final grouped = sales.aggregate(
        TableQueryPlanner.planFor(
          sales,
          'total revenue by location in january 2026',
        )!,
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

  group('the planner declines when it should', () {
    test('prose questions are not aggregations', () {
      for (final q in [
        'What is the warranty on the Heritage line?',
        'Where is the Abuja branch located?',
        'Who makes our Heritage leather shoes?',
        'What are the payment terms with the Italian supplier?',
      ]) {
        expect(TableQueryPlanner.planFor(sales, q), isNull, reason: q);
      }
    });

    test('an aggregation word over a column we do not have is declined', () {
      // "How much" is a sum intent, but no numeric column matches "leave".
      // Answering this with a sales figure is the failure mode.
      expect(
        TableQueryPlanner.planFor(
          sales,
          'How much annual leave do full-time staff get?',
        ),
        isNull,
      );
      expect(
        TableQueryPlanner.planFor(
          sales,
          'What discount do employees get on Heritage shoes?',
        ),
        isNull,
      );
    });

    test('greetings are declined', () {
      for (final q in ['Hello', 'thanks!', 'how are you doing today?']) {
        expect(TableQueryPlanner.planFor(sales, q), isNull, reason: q);
      }
    });

    test('an ambiguous metric is declined rather than guessed', () {
      // "price" matches unit_price_ngn; a bare "ngn" matches both that and
      // revenue_ngn equally, and picking either would be a coin flip.
      final t = CsvTable.parse(
        'week_starting,revenue_ngn,unit_price_ngn\n2026-01-05,10,2\n',
        source: 'x.csv',
      );
      expect(TableQueryPlanner.planFor(t, 'total ngn in 2026'), isNull);
    });

    test('an empty table is declined', () {
      final t = CsvTable.parse('a,b\n', source: 'empty.csv');
      expect(TableQueryPlanner.planFor(t, 'total a'), isNull);
    });
  });

  group('date ranges', () {
    test('a month needs a year to be unambiguous', () {
      final withYear = TableQueryPlanner.planFor(
        sales,
        'total revenue in january 2026',
      )!;
      expect(withYear.range, isNotNull);

      final without = TableQueryPlanner.planFor(
        sales,
        'total revenue in january',
      )!;
      expect(
        without.range,
        isNull,
        reason: 'a bare month must not silently span every year',
      );
    });

    test('december rolls into the next year', () {
      final q = TableQueryPlanner.planFor(
        sales,
        'total revenue in december 2026',
      )!;
      expect(q.range!.start, DateTime(2026, 12));
      expect(q.range!.end, DateTime(2027, 1));
    });

    test('quarters and bare years', () {
      final q1 = TableQueryPlanner.planFor(sales, 'total revenue q1 2026')!;
      expect(q1.range!.start, DateTime(2026, 1));
      expect(q1.range!.end, DateTime(2026, 4));

      final year = TableQueryPlanner.planFor(sales, 'total revenue in 2026')!;
      expect(year.range!.start, DateTime(2026));
      expect(year.range!.end, DateTime(2027));
    });
  });

  group('presentation', () {
    test('numbers are grouped for reading', () {
      expect(QueryResult.formatNumber(71882000), '71,882,000');
      expect(QueryResult.formatNumber(999), '999');
      expect(QueryResult.formatNumber(-1234), '-1,234');
    });

    test('the prompt block states the coverage, not just the figure', () {
      final result = sales.aggregate(
        TableQueryPlanner.planFor(sales, 'total revenue in january 2026')!,
      )!;
      final block = result.toPromptBlock();

      expect(block, contains('71,882,000'));
      expect(block, contains('January 2026'));
      // The model must be told this covers everything, or it hedges anyway.
      expect(block, contains('$kJanuaryRows matching row'));
      expect(block, contains('$kTotalRows'));
    });
  });
}
