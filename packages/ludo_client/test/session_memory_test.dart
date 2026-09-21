// Store tests for last successful create defaults: a later load on a
// fresh SessionMemory must return the name and seat count that
// recordSuccessfulCreate wrote. HomeScreen reads this store on launch.

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'recordSuccessfulCreate is returned by a later SessionMemory.load',
    () async {
      await SessionMemory.recordSuccessfulCreate(name: 'Priya', seats: 2);

      final SessionMemory relaunched = await SessionMemory.load();
      expect(
        relaunched.lastName,
        'Priya',
        reason:
            'a later load must return the name recordSuccessfulCreate wrote; '
            'got "${relaunched.lastName}"',
      );
      expect(
        relaunched.lastSeats,
        2,
        reason:
            'a later load must return the seat count recordSuccessfulCreate '
            'wrote; got ${relaunched.lastSeats}',
      );
      expect(
        relaunched.hasLastTable,
        isTrue,
        reason:
            'after recordSuccessfulCreate, hasLastTable must be true so Home '
            'can show home-last-table-chip',
      );
    },
  );
}
