import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/common.dart';

const _help = r'''
## Getting started
The **Setup guide** (Settings > the book icon) walks through these steps:
1. **Settings > Parent documents:** upload your resume as a **Word file (.docx)** - the agents edit a copy of it for
   every job - plus the PDF and your master cover letter. No resume yet? Build one under **Create**.
2. **Settings > Locations and Target roles:** where and what to look for (leave roles empty to use your resume's titles).
3. Optional: **Job boards** with the careers pages of companies you like.

You don't need any API keys: Pounce's own keys do the AI work.

## How a run works
The agents run every hour, in **batches** of up to 20 jobs (Settings > Jobs per batch). This part is free:
1. **Scout** - scans your company boards and the job sites, puts every posting on the shared **Jobs** board and keeps
   the ones that fit your resume as your **Matches**.
2. **Salary** - finds the salary in the posting or estimates it from salary sites.
3. **Scorer** - gives each match an ATS score and shortlist odds, and ranks the batch, best first.

## Credits
Open a match (or save a job from the board) and pick what you want:
- **Tailored resume and cover letter** - 1 credit.
- **Interview prep** - 1 credit.

Credits are held while the work runs (usually 2 to 5 minutes) and only used if it works. If it fails you see an error
code and keep your credits. You get credits by inviting friends: when someone signs up with your code and verifies
their email, you both get **30 credits** (Settings > Account > Credits and invites). Each email address can only earn
sign-up credits once.

## The screens
- **Home** - totals, your credits, what's running now, the current batch.
- **Jobs** - every job the agents have found, with search, location and filters (date posted, workplace, job type,
  salary). Save one to your matches.
- **Matches** - the jobs that fit your resume, grouped by batch and sorted by rank. Tap a job for details, the
  credits options, **Apply** (pick the tailored or your own resume) and **Prepare for interview**. Mark jobs
  **Applied**, or **Delete** them.
- **Create** - two things in one place:
  - **Add a custom job** you found yourself: paste the title and description (plus the company and link if you
    have them), give it a batch number and tick what you want. Scoring is free; the rest is 1 credit each. These
    jobs never show up in your regular batches.
  - **Build a CV or cover letter** in UK careers-service style: answer questions and let the AI write it, use your
    own words as typed, or start from your current resume. Review each section (regenerate, edit or keep your
    words), then download Word or PDF and, if you like, make it your master resume. The builder allows 20 AI
    requests a day.
- **Agent activity** (Settings > Account) - every agent task and each run's log, including why something failed.
- **Settings** - appearance (light or dark, colour theme), documents, where and what to search, tuning, and your
  account: privacy and AI, password, sign out and **Delete my account**.

## Limits and common messages
| In the log | What it means |
|---|---|
| *No AI provider key available* | Pounce's keys are all busy or used up; work continues on the next run. |
| *No parent resume uploaded yet* | Upload your resume (.docx) in Settings. |
| *rejected a request … 429* | The free per-minute limit - the agents slow down automatically. |
| *daily free-tier limit reached* | That key/model is used up until tomorrow; other models take over. |
| *overloaded (503)* | Google is busy; the next model is used and this one retried later. |
| *Stopped AI work for this run* | Safety stop after repeated rejections; the key pauses for an hour. |
| *call budget … used for this run* | Your per-run limit is reached; work continues next hour. |
| *Agents paused by an admin* | Everything is paused until the admin resumes. |

## Your data
Only you see your jobs and documents in the app; the admin who runs Pounce owns the database. Your resume and job
descriptions are sent to Google Gemini, with Groq and OpenRouter as backups (Settings > Account > Privacy and AI).
Delete jobs any time; jobs never marked **Applied** are deleted automatically after **30 days** (except the ones on
the Custom page), and deleted jobs don't come back. **Delete my account** in Settings removes everything at once.

## FAQ
- **No jobs yet?** Check the Getting started card on Home, then Agents > Runs for the latest run's note.
- **Changed my resume?** Upload the new .docx - jobs are re-rated for it on the next scan.
- **Bad tailoring or cover letter?** Tap 👎 on the job's "Rate the AI's work" - it helps pick better models.
''';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/')),
          title: const Text('How Pounce works'),
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
