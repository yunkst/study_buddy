import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

/// 行内 `$...$` 与块级 `$$...$$` 的 LaTeX 解析。
///
/// 将匹配到的公式生成为 `latex` 元素并标记 `MathStyle` 属性，
/// 由 [_LatexElementBuilder] 渲染为 [Math.tex]。
class _LatexInlineSyntax extends md.InlineSyntax {
  _LatexInlineSyntax()
      : super(r'\$\$?([^$\n]+?)\$\$?', startCharacter: r'$'.codeUnitAt(0));

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match.group(0)!;
    final isDisplay = raw.startsWith(r'$$');
    final element = md.Element.text('latex', match.group(1)!.trim());
    element.attributes['MathStyle'] = isDisplay ? 'display' : 'text';
    parser.addNode(element);
    return true;
  }
}

/// 块级 `$$...$$` 解析：支持单行 `$$ expr $$` 与多行围栏。
///
/// 产出 `Element('p', [Element.text('latex', expr)])`，使公式作为
/// 段落内的行内元素渲染，避免 latex 成为块级标签。
class _LatexBlockSyntax extends md.BlockSyntax {
  static final RegExp _openPattern = RegExp(r'^\$\$');

  @override
  RegExp get pattern => _openPattern;

  @override
  md.Node? parse(md.BlockParser parser) {
    final buffer = StringBuffer();
    var content = parser.current.content.trim();
    content = content.replaceFirst(RegExp(r'^\$\$'), '').trimLeft();

    // 单行闭合：`$$ expr $$`
    if (content.endsWith(r'$$')) {
      buffer.write(content.substring(0, content.length - 2).trim());
      parser.advance();
      return _latexParagraph(buffer.toString().trim());
    }

    // 多行围栏：收集直到遇到 `$$` 结束行
    buffer.write(content);
    parser.advance();
    while (!parser.isDone) {
      final line = parser.current.content.trim();
      parser.advance();
      if (line.endsWith(r'$$')) {
        final rest = line.substring(0, line.length - 2).trim();
        if (rest.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.write('\n');
          buffer.write(rest);
        }
        break;
      }
      if (line.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line);
      }
    }
    return _latexParagraph(buffer.toString().trim());
  }

  md.Node _latexParagraph(String content) {
    final element = md.Element.text('latex', content);
    element.attributes['MathStyle'] = 'display';
    return md.Element('p', [element]);
  }
}

/// 将 `latex` 元素渲染为 [Math.tex]。
class _LatexElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent.trim();
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final isDisplay = element.attributes['MathStyle'] == 'display';
    final baseStyle = TextStyle(color: scheme.onSurface);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.antiAlias,
      child: Math.tex(
        text,
        mathStyle: isDisplay ? MathStyle.display : MathStyle.text,
        textStyle: baseStyle,
        onErrorFallback: (error) => Text(
          text,
          style: TextStyle(color: scheme.error),
        ),
      ),
    );
  }
}

/// 统一的 Markdown + LaTeX 渲染组件。
///
/// 支持 GitHub 风格 Markdown 以及行内 `$...$` / 块级 `$$...$$` 公式。
/// 后续阶段（AI 对话输出、知识点详情、复习翻转卡）均复用此组件。
class MarkdownLatex extends StatelessWidget {
  const MarkdownLatex({super.key, required this.data, this.selectable = false});

  /// Markdown / LaTeX 源文本。
  final String data;

  /// 是否允许文本选择。
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: selectable,
      builders: {'latex': _LatexElementBuilder()},
      blockSyntaxes: [_LatexBlockSyntax()],
      inlineSyntaxes: [_LatexInlineSyntax()],
      // 注：markdown 7.x 已将 ExtensionSet.gitHub 拆分更名为
      // gitHubWeb / gitHubFlavored，此处用 gitHubFlavored（与 MarkdownBody 默认一致）。
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
  }
}
