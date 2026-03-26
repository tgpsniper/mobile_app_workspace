import 'package:flutter_test/flutter_test.dart';

import 'package:workspace_project/main.dart';

void main() {
  testWidgets('App renders login page', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Workspace by J2 Network'), findsOneWidget);
  });
}
