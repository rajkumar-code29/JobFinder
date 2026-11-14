// PDFs for the builder: the same layout as the Word file, in Liberation Sans (metrically the same as Arial,
// SIL Open Font License, bundled in assets/fonts).
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'cv.dart';

pw.ThemeData? _theme;

Future<pw.ThemeData> _fonts() async {
  if (_theme != null) return _theme!;
  Future<pw.Font> load(String name) async => pw.Font.ttf(await rootBundle.load('assets/fonts/LiberationSans-$name.ttf'));
  return _theme = pw.ThemeData.withFont(
    base: await load('Regular'),
    bold: await load('Bold'),
    italic: await load('Italic'),
  ).copyWith(defaultTextStyle: const pw.TextStyle(fontSize: 11, lineSpacing: 1.5));
}

const _grey = PdfColor.fromInt(0xff404040);

pw.Widget _heading(String text) => pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 10, bottom: 5),
      padding: const pw.EdgeInsets.only(bottom: 2),
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _grey, width: 0.75))),
      child: pw.Text(text, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
    );

pw.Widget _bullet(String text) => pw.Padding(
      padding: const pw.EdgeInsets.only(left: 6, bottom: 2),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.SizedBox(width: 11, child: pw.Text('•')),
        pw.Expanded(child: pw.Text(text)),
      ]),
    );

List<pw.Widget> _section(CvSection sec) => [
      _heading(sec.heading),
      for (final p in sec.paragraphs) pw.Padding(padding: const pw.EdgeInsets.only(bottom: 5), child: pw.Text(p)),
      for (final g in sec.groups) ...[
        if (g.text.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 3),
            child: pw.RichText(
              text: pw.TextSpan(children: [
                if (g.label.isNotEmpty) pw.TextSpan(text: '${g.label}: ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                pw.TextSpan(text: g.text),
              ]),
            ),
          )
        else if (g.label.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 3, bottom: 2),
            child: pw.Text(g.label, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          ),
        for (final x in g.bullets) _bullet(x),
      ],
      for (final e in sec.entries) ...[
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 5, bottom: 2),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              child: pw.RichText(
                text: pw.TextSpan(children: [
                  pw.TextSpan(
                      text: e.title.isNotEmpty ? e.title : e.org, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.TextSpan(
                      text: () {
                        final rest = [if (e.title.isNotEmpty) e.org, e.location].where((x) => x.isNotEmpty).join(', ');
                        return rest.isEmpty ? '' : ', $rest';
                      }()),
                ]),
              ),
            ),
            if (e.dates.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(left: 10), child: pw.Text(e.dates)),
          ]),
        ),
        for (final l in e.lines) pw.Padding(padding: const pw.EdgeInsets.only(bottom: 2), child: pw.Text(l)),
        for (final x in e.bullets) _bullet(x),
      ],
      for (final x in sec.bullets) _bullet(x),
    ];

/// (bytes, number of pages)
Future<(Uint8List, int)> cvPdf(CvDoc doc) async {
  final theme = await _fonts();
  final margin = isOnePage(doc.type) ? 36.0 : 56.7; // narrow (1.27 cm) or 2 cm
  final pdf = pw.Document(title: '${doc.name} CV', author: doc.name, creator: 'Pounce');
  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.copyWith(
        marginLeft: margin, marginRight: margin, marginTop: margin, marginBottom: margin),
    theme: theme,
    build: (_) => [
      pw.Center(child: pw.Text(doc.name, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))),
      pw.SizedBox(height: 3),
      pw.Center(child: pw.Text(doc.contact.join('  |  '), textAlign: pw.TextAlign.center)),
      pw.SizedBox(height: 4),
      for (final sec in doc.sections) ..._section(sec),
    ],
  ));
  final bytes = await pdf.save();
  return (bytes, pdf.document.pdfPageList.pages.length);
}

Future<Uint8List> letterPdf(LetterDoc l) async {
  final theme = await _fonts();
  final pdf = pw.Document(title: '${l.name} cover letter', author: l.name, creator: 'Pounce');
  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 72, marginRight: 72, marginTop: 72, marginBottom: 72),
    theme: theme,
    build: (_) => [
      for (final line in l.yourAddress) pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text(line)),
      pw.SizedBox(height: l.yourAddress.isEmpty ? 0 : 12),
      pw.Text(l.date),
      pw.SizedBox(height: 12),
      for (final line in l.recipient) pw.Text(line),
      pw.SizedBox(height: 12),
      pw.Text(l.greeting),
      pw.SizedBox(height: 8),
      for (final p in l.paragraphs) pw.Padding(padding: const pw.EdgeInsets.only(bottom: 8), child: pw.Text(p)),
      pw.SizedBox(height: 4),
      pw.Text(l.signOff),
      pw.SizedBox(height: 30),
      pw.Text(l.name),
    ],
  ));
  return pdf.save();
}
