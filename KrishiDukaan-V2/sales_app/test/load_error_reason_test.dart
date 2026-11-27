import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:flutter_test/flutter_test.dart';
import 'package:krishidukaan_sales/core/widgets/state_views.dart';

void main() {
  test('Firestore codes get a plain reason with the code', () {
    expect(loadErrorReason(FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied')),
        contains('(permission-denied)'));
    expect(loadErrorReason(FirebaseException(plugin: 'cloud_firestore', code: 'unavailable')),
        'No connection to the server right now. (unavailable)');
    expect(loadErrorReason(FirebaseException(plugin: 'cloud_firestore', code: 'aborted')), 'Reason: aborted');
  });
  test('other errors are shown short', () {
    expect(loadErrorReason(StateError('x' * 300)).length, lessThan(140));
  });
}
