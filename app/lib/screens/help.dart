import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/common.dart';

const _help = r'''
## Getting started
1. **Settings → Parent documents:** upload your resume as a **Word file (.docx)** – the agents edit a copy of it for
   every job – plus the PDF and your master cover letter.
2. **Settings → API keys → Add API key → Gemini:** a free key from Google AI Studio. The dialog explains how and can
   test it. Without an AI key your agents can't run.
3. **Settings → Locations and Target roles:** where and what to look for (leave roles empty to use your resume's titles).
4. Optional: **Adzuna / JSearch** keys for more job sources, **Groq** for faster rating, and **Job boards** with the
   careers pages of companies you like.

## How a run works
The agents run every hour. Each run works in **batches** of up to 20 jobs (Settings → Jobs per batch):
1. **Scout** – scans your company boards and the job sites and keeps only jobs that fit your resume.
2. **Salary** – finds the salary in the posting or estimates it from salary sites.
3. **Scorer** – gives each job an ATS score and ranks the batch, best first.
4. **Tailor → Coach → Writer** – for each job in rank order: a tailored resume, interview prep and a cover letter.

A new batch starts only when the current one is finished. On free tiers expect **a few jobs per hour**, so a full
batch takes several hours.

## The screens
- **Home** – totals, what's running now, the current batch.
- **Jobs** – grouped by batch and sorted by rank. Tap a job for details, **Apply** (pick the tailored or your own
  resume) and **Prepare for interview**. Mark jobs **Applied**, or **Delete** them.
- **Agents** – every agent task and each run's log, including why something failed.
- **Settings** – documents, API keys, where and what to search, and tuning.

## Limits and common messages
| In the log | What it means |
|---|---|
| *No AI provider key available* | Add a Gemini key in Settings → API keys. |
| *No parent resume uploaded yet* | Upload your resume (.docx) in Settings. |
| *rejected a request … 429* | The free per-minute limit – the agents slow down automatically. |
| *daily free-tier limit reached* | That key/model is used up until tomorrow; other models take over. |
| *overloaded (503)* | Google is busy; the next model is used and this one retried later. |
| *Stopped AI work for this run* | Safety stop after repeated rejections; the key pauses for an hour. |
| *call budget … used for this run* | Your per-run limit is reached; work continues next hour. |
| *Agents paused by an admin* | Everything is paused until the admin resumes. |

## Your data
Only you see your jobs and documents in the app; the admin who runs JobFinder owns the database. Your resume and job
descriptions are sent to the AI provider of your key. Delete jobs any time; jobs never marked **Applied** are deleted
automatically after **30 days**, and deleted jobs don't come back.

## FAQ
- **No jobs yet?** Check the Getting started card on Home, then Agents → Runs for the latest run's note.
- **Changed my resume?** Upload the new .docx – jobs are re-rated for it on the next scan.
- **Bad tailoring or cover letter?** Tap 👎 on the job's "Rate the AI's work" – it helps pick better models.
''';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/')),
          title: const Text('How JobFinder works'),
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          PageBody(
            maxWidth: 820,
            child: MarkdownBody(
              data: _help,
              selectable: true,
              onTapLink: (_, href, _) => href == null ? null : launchUrl(Uri.parse(href)),
            ),
          ),
        ]),
      );
}
