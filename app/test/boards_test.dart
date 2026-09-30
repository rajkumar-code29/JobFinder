import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/boards.dart';

void main() {
  test('direct feeds are recognised', () {
    for (final url in [
      'https://boards.greenhouse.io/stripe',
      'jobs.lever.co/spotify',
      'https://jobs.ashbyhq.com/openai',
      'https://apply.workable.com/acme',
      'https://nvidia.wd5.myworkdayjobs.com/en-US/NVIDIAExternalCareerSite',
      'https://jobs.smartrecruiters.com/BoschGroup',
    ]) {
      expect(boardKind(url).direct, isTrue, reason: url);
    }
  });

  test('incomplete Workday / SmartRecruiters links explain what is missing', () {
    expect(boardKind('https://nvidia.wd5.myworkdayjobs.com/').warning, contains('full careers-site link'));
    expect(boardKind('https://jobs.smartrecruiters.com/').direct, isFalse);
  });

  test('big boards fall back to Google with a JSearch hint', () {
    for (final url in ['https://www.linkedin.com/jobs/search?keywords=x', 'in.indeed.com', 'naukri.com', 'glassdoor.co.uk']) {
      final k = boardKind(url);
      expect(k.direct, isFalse, reason: url);
      expect(k.warning, contains('RapidAPI'), reason: url);
    }
  });

  test('other careers pages get the "look for the ATS link" tip', () {
    expect(boardKind('https://careers.acme.com/jobs').warning, contains('paste that link instead'));
  });
}
