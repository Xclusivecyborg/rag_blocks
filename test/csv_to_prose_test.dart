import 'package:test/test.dart';
import 'package:rag_blocks/rag_blocks.dart';

void main() {
  group('csvToProse', () {
    test('labels each cell with its column header', () {
      const csv = 'region,units\nLagos,48\nAbuja,12\n';
      final prose = csvToProse(csv);
      expect(prose, contains('region: Lagos'));
      expect(prose, contains('units: 48'));
      expect(prose, contains('region: Abuja'));
    });

    test('handles quoted fields containing commas', () {
      const csv = 'name,note\n"Ade, O.","sold 3, returned 1"\n';
      final prose = csvToProse(csv);
      expect(prose, contains('name: Ade, O.'));
      expect(prose, contains('note: sold 3, returned 1'));
    });

    test('handles escaped double quotes', () {
      const csv = 'name,note\nAde,"he said ""yes"""\n';
      final prose = csvToProse(csv);
      expect(prose, contains('he said "yes"'));
    });

    test('skips blank rows', () {
      const csv = 'a,b\n1,2\n\n3,4\n';
      final prose = csvToProse(csv);
      expect('Record'.allMatches(prose).length, 2);
    });

    test('returns empty string for empty input', () {
      expect(csvToProse(''), isEmpty);
    });
  });
}
