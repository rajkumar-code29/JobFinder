// CV model shared by the builder screens, the preview and the DOCX/PDF writers.
//
// Answers are kept as plain JSON (the same shape the resume-ai function reads and returns), and a CV is a header
// plus sections. Which sections appear, in what order and under which heading depends on the CV type, following
// UK university careers guidance (one column, standard headings, newest first).

typedef Json = Map<String, dynamic>;

class CvTarget {
  const CvTarget(this.id, this.label, this.description, this.defaultType);
  final String id;
  final String label;
  final String description;
  final String defaultType;
}

const cvTargets = [
  CvTarget('part_time', 'Part-time job', 'Retail, hospitality, call centre and similar work alongside your studies',
      'part_time'),
  CvTarget('internship', 'Internship or placement', 'Summer internships, placements and work experience while studying',
      'skills'),
  CvTarget('graduate', 'Graduate job', 'Graduate jobs and schemes, for final-year students and recent graduates',
      'chronological'),
  CvTarget('professional', 'Professional role', 'Full-time roles when you already have work experience',
      'experience_first'),
];

CvTarget targetById(String? id) => cvTargets.firstWhere((t) => t.id == id, orElse: () => cvTargets[2]);

const cvTypes = {
  'chronological': ('Chronological', 'Education near the top, then experience, newest first. The usual choice for '
      'students and graduates.'),
  'skills': ('Skills-based', 'Evidence grouped under the skills the job asks for. Good when you have little directly '
      'relevant experience.'),
  'experience_first': ('Experience first', 'Relevant experience before education. For postgraduates and people with '
      'work experience.'),
  'one_page': ('One page', 'Only what matters for this role, on a single page.'),
  'part_time': ('Part-time job', 'One page: experience first, education kept short, availability up front.'),
};

bool isOnePage(String type) => type == 'one_page' || type == 'part_time';

/// One section in a CV type's layout. [guide] tells the AI how to write it, [kinds] which experience entries it
/// takes.
class SectionSpec {
  const SectionSpec(this.key, this.heading, {String? guide, this.kinds = const []}) : guide = guide ?? key;
  final String key;
  final String heading;
  final String guide;
  final List<String> kinds;
}

const _profile = SectionSpec('profile', 'Profile');
const _education = SectionSpec('education', 'Education');
const _techSkills = SectionSpec('tech_skills', 'Skills', guide: 'skills_list');
const _relevant = SectionSpec('experience_relevant', 'Relevant Experience', kinds: ['relevant']);
const _other = SectionSpec('experience_other', 'Other Work Experience', guide: 'experience_other', kinds: ['other']);
const _volunteering = SectionSpec('volunteering', 'Volunteering', kinds: ['volunteering']);
const _projects = SectionSpec('projects', 'Projects');
const _achievements = SectionSpec('achievements', 'Achievements');
const _certifications = SectionSpec('certifications', 'Certifications');
const _languages = SectionSpec('languages', 'Languages');
const _interests = SectionSpec('interests', 'Interests');
const _additional = SectionSpec('additional', 'Additional Information');
const references = SectionSpec('references', 'References');
const referencesText = 'References available upon request';

List<SectionSpec> layoutFor(String type) => switch (type) {
      'skills' => const [
          SectionSpec('profile', 'Personal Statement'),
          _education,
          SectionSpec('skills', 'Skills', guide: 'skills_evidence'),
          SectionSpec('tech_skills', 'IT and Technical Skills', guide: 'skills_list'),
          _languages,
          _relevant,
          SectionSpec('experience_other', 'Employment', guide: 'experience_other', kinds: ['other']),
          _volunteering,
          _projects,
          _achievements,
          _interests,
          _additional,
          references,
        ],
      'experience_first' => const [
          _profile,
          _relevant,
          _education,
          _other,
          _techSkills,
          _projects,
          _certifications,
          _volunteering,
          _achievements,
          _languages,
          _interests,
          _additional,
          references,
        ],
      'one_page' => const [
          _profile,
          SectionSpec('tech_skills', 'Key Skills', guide: 'skills_list'),
          _education,
          SectionSpec('experience_relevant', 'Experience', kinds: ['relevant']),
          SectionSpec('experience_other', 'Other Experience', guide: 'experience_other', kinds: ['other']),
          _projects,
          _certifications,
          _achievements,
          SectionSpec('volunteering', 'Extracurricular Activities', kinds: ['volunteering']),
          references,
        ],
      'part_time' => const [
          SectionSpec('profile', 'Personal Profile'),
          SectionSpec('experience_relevant', 'Work Experience', kinds: ['relevant', 'other']),
          _volunteering,
          _education,
          _achievements,
          _techSkills,
          _interests,
          _additional,
          references,
        ],
      _ => const [
          _profile,
          _education,
          _techSkills,
          _relevant,
          _other,
          _volunteering,
          _projects,
          _achievements,
          _certifications,
          _languages,
          _interests,
          _additional,
          references,
        ],
    };

// answers

Json emptyAnswers() => {
      'contact': <String, dynamic>{},
      'about': '',
      'education': <dynamic>[],
      'experience': <dynamic>[],
      'projects': <dynamic>[],
      'skills': <String, dynamic>{},
      'achievements': '',
      'certifications': '',
      'languages': '',
      'interests': '',
      'additional': '',
    };

/// Answers with every list and map in place and mutable, ready for the forms.
Json normaliseAnswers(Json raw) {
  final a = {...emptyAnswers(), ...raw};
  a['contact'] = obj(a['contact']);
  a['skills'] = obj(a['skills']);
  for (final k in ['education', 'experience', 'projects']) {
    a[k] = objs(a[k]);
  }
  return a;
}

String s(Object? v) => v is String ? v.trim() : (v == null ? '' : '$v'.trim());
Json obj(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Json> objs(Object? v) => v is List ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : [];

/// Lines of a free-text answer, without bullet characters.
List<String> lines(Object? v) => s(v)
    .split(RegExp(r'\n|;'))
    .map((l) => l.trim().replaceFirst(RegExp(r'^[-•*·–]\s*'), '').trim())
    .where((l) => l.isNotEmpty)
    .toList();

String dates(Object? start, Object? end, {bool current = true}) {
  final a = s(start), b = s(end);
  if (a.isEmpty) return b;
  return '$a – ${b.isEmpty && current ? 'Present' : b}';
}

/// Whether the answers have anything for this section.
bool hasContent(SectionSpec spec, Json answers) {
  final skills = obj(answers['skills']);
  return switch (spec.key) {
    'profile' => s(answers['about']).isNotEmpty,
    'education' => objs(answers['education']).isNotEmpty,
    'skills' => s(skills['soft']).isNotEmpty,
    'tech_skills' => s(skills['technical']).isNotEmpty || s(skills['it']).isNotEmpty,
    'projects' => objs(answers['projects']).isNotEmpty,
    'references' => true,
    _ when spec.kinds.isNotEmpty => objs(answers['experience']).any((e) => spec.kinds.contains(s(e['kind']).isEmpty ? 'other' : s(e['kind']))),
    _ => s(answers[spec.key]).isNotEmpty,
  };
}

/// Sections this CV will have, in order. With AI, a profile can be written from the rest of the answers.
List<SectionSpec> sectionsToBuild(String type, Json answers, {required bool ai, required String role}) => [
      for (final spec in layoutFor(type))
        if (hasContent(spec, answers) || (ai && spec.key == 'profile' && role.isNotEmpty)) spec,
    ];

// generated CV

class CvEntry {
  CvEntry({this.title = '', this.org = '', this.location = '', this.dates = '', List<String>? lines, List<String>? bullets})
      : lines = lines ?? [],
        bullets = bullets ?? [];
  String title, org, location, dates;
  List<String> lines, bullets;

  factory CvEntry.fromJson(Json j) => CvEntry(
        title: s(j['title']),
        org: s(j['org']),
        location: s(j['location']),
        dates: s(j['dates']),
        lines: _strs(j['lines']),
        bullets: _strs(j['bullets']),
      );
  Json toJson() => {'title': title, 'org': org, 'location': location, 'dates': dates, 'lines': lines, 'bullets': bullets};
}

class CvGroup {
  CvGroup({this.label = '', this.text = '', List<String>? bullets}) : bullets = bullets ?? [];
  String label, text;
  List<String> bullets;

  factory CvGroup.fromJson(Json j) => CvGroup(label: s(j['label']), text: s(j['text']), bullets: _strs(j['bullets']));
  Json toJson() => {'label': label, 'text': text, 'bullets': bullets};
}

List<String> _strs(Object? v) => v is List ? v.map(s).where((x) => x.isNotEmpty).toList() : [];

class CvSection {
  CvSection({
    required this.key,
    required this.heading,
    List<String>? paragraphs,
    List<String>? bullets,
    List<CvGroup>? groups,
    List<CvEntry>? entries,
  })  : paragraphs = paragraphs ?? [],
        bullets = bullets ?? [],
        groups = groups ?? [],
        entries = entries ?? [];

  final String key;
  String heading;
  List<String> paragraphs, bullets;
  List<CvGroup> groups;
  List<CvEntry> entries;

  bool get isEmpty => paragraphs.isEmpty && bullets.isEmpty && groups.isEmpty && entries.isEmpty;

  factory CvSection.fromJson(String key, String heading, Json j) => CvSection(
        key: key,
        heading: s(j['heading']).isNotEmpty ? s(j['heading']) : heading,
        paragraphs: _strs(j['paragraphs']),
        bullets: _strs(j['bullets']),
        groups: objs(j['groups']).map(CvGroup.fromJson).toList(),
        entries: objs(j['entries']).map(CvEntry.fromJson).toList(),
      );

  Json toJson() => {
        'heading': heading,
        'paragraphs': paragraphs,
        'bullets': bullets,
        'groups': [for (final g in groups) g.toJson()],
        'entries': [for (final e in entries) e.toJson()],
      };

  CvSection copy() => CvSection.fromJson(key, heading, toJson());

  /// Plain text, for the cover letter prompt and tests.
  String get text {
    final b = StringBuffer();
    for (final p in paragraphs) {
      b.writeln(p);
    }
    for (final g in groups) {
      if (g.text.isNotEmpty) b.writeln('${g.label}: ${g.text}');
      if (g.text.isEmpty && g.label.isNotEmpty) b.writeln(g.label);
      for (final x in g.bullets) {
        b.writeln('- $x');
      }
    }
    for (final e in entries) {
      b.writeln([e.title, e.org, e.location, e.dates].where((x) => x.isNotEmpty).join(', '));
      for (final x in [...e.lines, ...e.bullets.map((x) => '- $x')]) {
        b.writeln(x);
      }
    }
    for (final x in bullets) {
      b.writeln('- $x');
    }
    return b.toString().trim();
  }
}

class CvDoc {
  CvDoc({required this.name, required this.contact, required this.sections, required this.type});
  final String name;
  final List<String> contact;
  final List<CvSection> sections;
  final String type;

  String get text => [
        name,
        contact.join(' | '),
        for (final sec in sections) '\n${sec.heading.toUpperCase()}\n${sec.text}',
      ].join('\n');
}

/// The contact line: location, email, phone, links (and availability on a part-time CV).
List<String> contactLine(Json answers, String type) {
  final c = obj(answers['contact']);
  return [
    s(c['location']),
    s(c['email']),
    s(c['phone']),
    s(c['linkedin']),
    s(c['website']),
    if (type == 'part_time' && s(c['availability']).isNotEmpty) 'Available: ${s(c['availability'])}',
  ].where((x) => x.isNotEmpty).toList();
}

/// A section built straight from the answers, with no AI: the "My own words" mode and the "Use my words" button.
CvSection ownWords(SectionSpec spec, Json answers) {
  final sec = CvSection(key: spec.key, heading: spec.heading);
  final skills = obj(answers['skills']);
  switch (spec.key) {
    case 'profile':
      sec.paragraphs = s(answers['about']).split(RegExp(r'\n\s*\n')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    case 'references':
      sec.paragraphs = [referencesText];
    case 'education':
      sec.entries = [
        for (final e in objs(answers['education']))
          CvEntry(
            title: [s(e['qualification']), if (s(e['grade']).isNotEmpty) '(${s(e['grade'])})'].join(' ').trim(),
            org: s(e['institution']),
            location: s(e['location']),
            dates: dates(e['start'], e['end']),
            lines: [if (s(e['modules']).isNotEmpty) 'Relevant modules: ${s(e['modules'])}'],
            bullets: lines(e['details']),
          ),
      ];
    case 'skills':
      // "Teamwork: ran the rota at the café" becomes a Teamwork group with that line as evidence
      final groups = <String, CvGroup>{};
      for (final line in lines(skills['soft'])) {
        final i = line.indexOf(':');
        final label = i > 0 && i < 40 ? line.substring(0, i).trim() : '';
        final rest = i > 0 && i < 40 ? line.substring(i + 1).trim() : line;
        groups.putIfAbsent(label, () => CvGroup(label: label)).bullets.add(rest);
      }
      sec.groups = groups.values.toList();
    case 'tech_skills':
      sec.groups = [
        if (s(skills['technical']).isNotEmpty) CvGroup(label: 'Technical', text: s(skills['technical'])),
        if (s(skills['it']).isNotEmpty) CvGroup(label: 'IT', text: s(skills['it'])),
      ];
    case 'projects':
      sec.entries = [
        for (final p in objs(answers['projects']))
          CvEntry(title: s(p['name']), org: s(p['context']), dates: s(p['dates']), bullets: lines(p['details'])),
      ];
    default:
      if (spec.kinds.isNotEmpty) {
        sec.entries = [
          for (final e in objs(answers['experience']))
            if (spec.kinds.contains(s(e['kind']).isEmpty ? 'other' : s(e['kind'])))
              CvEntry(
                title: s(e['title']),
                org: s(e['organisation']),
                location: s(e['location']),
                dates: dates(e['start'], e['end']),
                bullets: lines(e['details']),
              ),
        ];
      } else {
        sec.bullets = lines(answers[spec.key]);
      }
  }
  return sec;
}

/// The finished CV from a draft: generated sections where there are any, own words otherwise.
CvDoc buildDoc({required Json answers, required String type, required Json sections, required bool ai, required String role}) {
  final specs = sectionsToBuild(type, answers, ai: ai, role: role);
  return CvDoc(
    name: s(obj(answers['contact'])['name']),
    contact: contactLine(answers, type),
    type: type,
    sections: [
      for (final spec in specs)
        if (spec.key == 'references')
          ownWords(spec, answers)
        else if (sections[spec.key] is Map)
          CvSection.fromJson(spec.key, spec.heading, obj(sections[spec.key]))
        else
          ownWords(spec, answers),
    ].where((sec) => !sec.isEmpty).toList(),
  );
}

// cover letter

const letterParts = ['opening', 'motivation', 'skills', 'closing'];
const letterPartLabels = {
  'opening': 'Opening',
  'motivation': 'Why this job and organisation',
  'skills': 'Your skills and evidence',
  'closing': 'Closing',
};

class LetterDoc {
  LetterDoc({
    required this.name,
    required this.yourAddress,
    required this.date,
    required this.recipient,
    required this.paragraphs,
    required this.named,
  });
  final String name;
  final List<String> yourAddress;
  final String date;
  final List<String> recipient; // name, job title, organisation, address lines
  final List<String> paragraphs;

  /// Addressed to a named person (recipient.first is the name).
  final bool named;
  String get recipientName => named ? recipient.first : '';

  /// "Dear Ms Smith," with a name, "Dear Hiring Manager," without.
  String get greeting => named ? 'Dear $recipientName,' : 'Dear Hiring Manager,';

  /// UK rule: "Yours sincerely" to a named person, "Yours faithfully" to "Dear Hiring Manager".
  String get signOff => named ? 'Yours sincerely,' : 'Yours faithfully,';
}

LetterDoc buildLetter(Json inputs, Json parts, {required DateTime today}) {
  final recipientName = s(inputs['recipient_name']);
  final paragraphs = <String>[
    for (final p in letterParts)
      ...s(parts[p]).split(RegExp(r'\n\s*\n')).map((x) => x.trim()).where((x) => x.isNotEmpty),
  ];
  return LetterDoc(
    name: s(inputs['your_name']),
    yourAddress: lines(s(inputs['your_address']).replaceAll(',', '\n')),
    date: ukDate(today),
    recipient: [
      if (recipientName.isNotEmpty) recipientName,
      if (s(inputs['recipient_title']).isNotEmpty) s(inputs['recipient_title']),
      if (recipientName.isEmpty && s(inputs['recipient_title']).isEmpty) 'Recruitment Team',
      if (s(inputs['company']).isNotEmpty) s(inputs['company']),
      ...lines(s(inputs['company_address']).replaceAll(',', '\n')),
    ],
    paragraphs: paragraphs,
    named: recipientName.isNotEmpty,
  );
}

/// "14th November 2026"
String ukDate(DateTime d) {
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
    'November', 'December'];
  final n = d.day;
  final suffix = (n % 100 >= 11 && n % 100 <= 13) ? 'th' : switch (n % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' };
  return '$n$suffix ${months[d.month - 1]} ${d.year}';
}

/// "Jane Smith CV.docx" style names, safe for every platform.
String fileStem(String name, String what) {
  final clean = name.replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), '').trim();
  return clean.isEmpty ? what : '$clean $what';
}
