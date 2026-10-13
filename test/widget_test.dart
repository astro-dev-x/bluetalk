import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:test_app/main.dart';

void main() {
  testWidgets('Home screen shows BLUETALK', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => RoomState(),
        child: const BlueTalkApp(),
      ),
    );

    expect(find.text('BLUETALK'), findsOneWidget);
  });
}
