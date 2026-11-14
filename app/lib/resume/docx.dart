// Word files for the builder, written by hand so they stay simple: one column, Arial 11pt, real bullets, dates on a
// right tab stop, no tables, text boxes, headers or footers (applicant tracking systems read those badly).
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'cv.dart';

const _a4Width = 11906, _a4Height = 16838;

String _esc(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

String _run(String text, {bool bold = false, bool italic = false, int? size}) {
  if (text.isEmpty) return '';
  final props = [if (bold) '<w:b/>', if (italic) '<w:i/>', if (size != null) '<w:sz w:val="$size"/><w:szCs w:val="$size"/>'];
  return '<w:r>${props.isEmpty ? '' : '<w:rPr>${props.join()}</w:rPr>'}<w:t xml:space="preserve">${_esc(text)}</w:t></w:r>';
}

const _tab = '<w:r><w:tab/></w:r>';

String _p(String runs, {String align = 'left', int after = 80, int before = 0, bool keepNext = false, String extra = ''}) =>
    '<w:p><w:pPr>${keepNext ? '<w:keepNext/>' : ''}$extra'
    '<w:spacing w:before="$before" w:after="$after"/>${align == 'left' ? '' : '<w:jc w:val="$align"/>'}</w:pPr>$runs</w:p>';

String _bullet(String text) => '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>'
    '<w:spacing w:before="0" w:after="40"/><w:ind w:left="357" w:hanging="227"/></w:pPr>${_run(text)}</w:p>';

String _heading(String text) => _p(_run(text, bold: true, size: 24),
    before: 200,
    after: 80,
    keepNext: true,
    extra: '<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="404040"/></w:pBdr>');

String _section(CvSection sec, int textWidth) {
  final b = StringBuffer(_heading(sec.heading));
  for (final para in sec.paragraphs) {
    b.write(_p(_run(para), after: 100));
  }
  for (final g in sec.groups) {
    if (g.text.isNotEmpty) {
      b.write(_p('${_run(g.label.isEmpty ? '' : '${g.label}: ', bold: true)}${_run(g.text)}', after: 60));
    } else if (g.label.isNotEmpty) {
      b.write(_p(_run(g.label, bold: true), after: 40, before: 60, keepNext: true));
    }
    for (final x in g.bullets) {
      b.write(_bullet(x));
    }
  }
  for (final e in sec.entries) {
    final head = e.title.isNotEmpty ? e.title : e.org;
    final rest = [if (e.title.isNotEmpty) e.org, e.location].where((x) => x.isNotEmpty).join(', ');
    b.write(_p(
      '${_run(head, bold: true)}${_run(rest.isEmpty ? '' : ', $rest')}${e.dates.isEmpty ? '' : '$_tab${_run(e.dates)}'}',
      before: 100,
      after: 40,
      keepNext: e.lines.isNotEmpty || e.bullets.isNotEmpty,
      extra: '<w:tabs><w:tab w:val="right" w:pos="$textWidth"/></w:tabs>',
    ));
    for (final l in e.lines) {
      b.write(_p(_run(l), after: 40));
    }
    for (final x in e.bullets) {
      b.write(_bullet(x));
    }
  }
  for (final x in sec.bullets) {
    b.write(_bullet(x));
  }
  return b.toString();
}

String _document(String body, int margin) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>$body'
    '<w:sectPr><w:pgSz w:w="$_a4Width" w:h="$_a4Height"/>'
    '<w:pgMar w:top="$margin" w:right="$margin" w:bottom="$margin" w:left="$margin" w:header="0" w:footer="0" w:gutter="0"/>'
    '</w:sectPr></w:body></w:document>';

const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/>'
    '<w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-GB"/></w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr><w:spacing w:after="80" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>'
    '<w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>'
    '</w:styles>';

const _numbering = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>'
    '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/>'
    '<w:pPr><w:ind w:left="357" w:hanging="227"/></w:pPr><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/></w:rPr></w:lvl>'
    '</w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>';

Uint8List _package(String document, String title, String author) {
  final now = DateTime.now().toUtc().toIso8601String().split('.').first;
  final files = {
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>',
    'word/_rels/document.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
        '</Relationships>',
    'word/document.xml': document,
    'word/styles.xml': _styles,
    'word/numbering.xml': _numbering,
    'docProps/core.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${_esc(title)}</dc:title><dc:creator>${_esc(author)}</dc:creator>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">${now}Z</dcterms:created>'
        '<dcterms:modified xsi:type="dcterms:W3CDTF">${now}Z</dcterms:modified></cp:coreProperties>',
  };
  final archive = Archive();
  files.forEach((name, content) => archive.addFile(ArchiveFile.string(name, content)));
  return ZipEncoder().encodeBytes(archive);
}

/// Narrow margins for one-page CVs, 2 cm otherwise.
int cvMargin(String type) => isOnePage(type) ? 720 : 1134;

Uint8List cvDocx(CvDoc doc) {
  final margin = cvMargin(doc.type);
  final width = _a4Width - 2 * margin;
  final body = StringBuffer()
    ..write(_p(_run(doc.name, bold: true, size: 36), align: 'center', after: 40))
    ..write(_p(_run(doc.contact.join('  |  ')), align: 'center', after: 120));
  for (final sec in doc.sections) {
    body.write(_section(sec, width));
  }
  return _package(_document(body.toString(), margin), '${doc.name} CV', doc.name);
}

Uint8List letterDocx(LetterDoc l) {
  final body = StringBuffer();
  for (final line in l.yourAddress) {
    body.write(_p(_run(line), align: 'right', after: 0));
  }
  body.write(_p(_run(l.date), before: l.yourAddress.isEmpty ? 0 : 240, after: 240));
  for (final line in l.recipient) {
    body.write(_p(_run(line), after: 0));
  }
  body.write(_p(_run(l.greeting), before: 240, after: 160));
  for (final para in l.paragraphs) {
    body.write(_p(_run(para), after: 160));
  }
  body
    ..write(_p(_run(l.signOff), before: 80, after: 600))
    ..write(_p(_run(l.name), after: 0));
  return _package(_document(body.toString(), 1440), '${l.name} cover letter', l.name);
}
