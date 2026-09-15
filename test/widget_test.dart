import 'package:flutter_test/flutter_test.dart';
import 'package:geopasto/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('abre o cadastro do Geopasto', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const GeopastoApp());
    await tester.pumpAndSettle();
    expect(find.text('Cadastro da propriedade'), findsOneWidget);
  });
}
