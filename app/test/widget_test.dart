import 'package:flutter_test/flutter_test.dart';

import 'package:exemplo_quatro/main.dart';

void main() {
  testWidgets('mostra a tela de contatos', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Contatos'), findsOneWidget);
  });
}
