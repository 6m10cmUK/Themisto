import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:themisto/main.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ThemistoApp()));
    expect(find.text('Themisto - Hosts'), findsOneWidget);
  });
}
