import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_buddy/core/widgets/markdown_latex.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('内联 \$...\$ 公式渲染不崩', (tester) async {
    const md = MarkdownLatex(data: r'勾股定理: $a^2+b^2=c^2$ 恒成立。');
    await tester.pumpWidget(wrap(md));

    expect(tester.takeException(), isNull);
    expect(find.byType(MarkdownLatex), findsOneWidget);
  });

  testWidgets('块级 \$\$...\$\$ 公式渲染不崩', (tester) async {
    const md = MarkdownLatex(data: r'$$ T(n) =2T(n/2) + n $$');
    await tester.pumpWidget(wrap(md));

    expect(tester.takeException(), isNull);
    expect(find.byType(MarkdownLatex), findsOneWidget);
  });
}