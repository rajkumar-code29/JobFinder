# JobFinder

I got tired of scrolling job boards and rewriting my resume for every application, so I built this. A set of
agents runs every hour, finds jobs that actually match my resume, tailors a copy of my resume for each one,
writes a cover letter and puts together interview prep. I check the results in a Flutter app, on the web at
jobs.rajkumar.codes or on my iPhone, and apply from there.

Everything runs on free tiers: GitHub Actions for the agents, Supabase for the database, auth and files,
Gemini for the AI work, and Cloudflare for the website and the hourly trigger.

## What it does

Each run works in batches of up to 20 jobs:

1. **Scout** looks at the company career pages I've added and a few job APIs, and keeps only jobs that fit my
   resume. Once it has 20 it stops, and those 20 become the next batch.
2. **Salary** takes the salary from the posting, or estimates it from salary sites. If there's nothing, it's NA.
3. **Scorer** gives every job an ATS score against my resume and ranks the batch.
4. **Tailor, Coach and Writer** then go through the jobs best-first: a tailored resume (my original .docx with
   edits, same file name), interview prep (MCQs with explanations, technical and coding questions) and a cover
   letter.

Every job gets its own folder in storage with the job details, the scoring report, the tailored resume (docx
and pdf), the cover letter and the interview pack. In the app I can open a job, pick which resume to send,
open the application page, mark it applied, or delete it.

A new batch only starts once the current one is done. On free tiers that's a few jobs an hour.

## Job sources

| Source | Notes |
|---|---|
| Company boards on Greenhouse, Lever, Ashby, Workable, Workday, SmartRecruiters | Read from their public feeds, so you get every opening with the full description. This is the best source. |
| Adzuna | Free key, 19 countries |
| JSearch (RapidAPI) | LinkedIn/Indeed/Glassdoor postings. 200 requests a month, so it runs once a day. |
| Remotive, Arbeitnow | No key needed |
| Google search through Gemini | Every 4 hours. Also used for board links without an API, like LinkedIn or a plain careers page. |

Nothing gets scraped. For LinkedIn, Indeed and similar sites only the domain is used, for a Google `site:` search.

## Setup

It takes about half an hour the first time.

**Supabase**
1. Create a free project and run the files in `supabase/migrations/` in order (001 to 007) in the SQL editor.
   Create your own user first (Authentication > Users > Add user, tick Auto Confirm) because 002 makes the
   oldest user the owner.
2. Turn off "Allow new users to sign up" under Authentication > Sign In / Providers.
3. Authentication > URL Configuration: set the Site URL to the web app's address and add `https://<site>/**`
   under Redirect URLs. Without this, invite and reset emails open localhost:3000.
4. Grab the project URL, the publishable key and the secret key from the API settings.
5. Store the GitHub token for the Run now button (004 has the exact line):
   `select vault.create_secret('<token>', 'gh_dispatch_token', 'JobFinder');`

**Keys**
- Gemini: aistudio.google.com/apikey (required)
- Adzuna: developer.adzuna.com (app id + key)
- JSearch on RapidAPI, Groq: optional

Free Gemini may use prompts to improve their models, and your resume is part of the prompts.

**GitHub**

Add these repository secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`,
`GEMINI_API_KEY` (or `GEMINI_API_KEYS=k1,k2`), `ADZUNA_APP_ID`, `ADZUNA_APP_KEY`, and optionally
`RAPIDAPI_KEY` and `GROQ_API_KEY`. For the website and the scheduler also add `CLOUDFLARE_API_TOKEN`,
`CLOUDFLARE_ACCOUNT_ID` and `GH_DISPATCH_TOKEN`.

The Cloudflare token needs Pages: Edit and Workers Scripts: Edit. `GH_DISPATCH_TOKEN` is a fine-grained token
for this repo only, with Actions: Read and write.

**Cloudflare**
1. Run the "Deploy web app" workflow. It creates the Pages project and deploys.
2. Add your domain under the Pages project's Custom domains. If DNS is elsewhere, add the CNAME it shows.
3. Run "Deploy hourly scheduler". That's a small Worker that starts the agents at :07 every hour, because
   GitHub's own cron can be hours late. The GitHub cron is still there as a backup every 3 hours.

**In the app**

Sign in, then go to Settings: upload the resume as .docx (plus the PDF and a master cover letter), add a
Gemini key, and pick locations and roles. The Getting started card on Home lists whatever's still missing.

**iPhone**
```bash
cd app && cp env.example.json env.json   # fill in
flutter build ios --release --dart-define-from-file=env.json
```
Then install with Xcode or `xcrun devicectl device install app`. Keep the repo outside iCloud-synced folders,
because iCloud offloads files and breaks code signing. To ship a TestFlight build: `cd app && ./tool/testflight.sh`.

## Other users

Friends can use it too. Add them in Supabase (Authentication > Users). They get their own settings and only
ever see their own jobs, which row-level security enforces. They use their own API keys unless I switch on
shared keys for them in Settings > Users. That screen also shows whether each person is set up, their last
run and how much storage they use.

As the project owner I can still see everything in the Supabase dashboard. The privacy notice in the app
says so.

## Admin bits

Accounts on @rajkumar.codes get the admin tools:

- **Pause all** on Home is a kill switch for every agent.
- **Run now** under Agents.
- **Shared keys** in Settings, including which key is currently in use.
- **Users** panel.
- **AI models**:
  - per-agent model order, e.g. Groq for the Scout and Gemini for tailoring
  - a scorecard per model
  - comparisons that run the same jobs through different models, with a blind vote on the results

## Limits and how it copes

- Gemini Flash models have 20 free requests a day each and Flash-Lite 500. The cheap, high-volume work
  (rating, scoring, salary, search) goes to Flash-Lite. Flash is kept for tailoring, interview prep and cover
  letters, and the agents work through every Flash version before falling back.
- On 429s the agents slow down. After 4 in a row, or 12 in a run, they stop for that run and pause the key
  for an hour. On 503s they move to the next model. Broken JSON gets repaired or retried once.
- When Google retires a model, the agents pick the newest one in the same family and note it in the run log.
- Postings that were already rated aren't rated again. Deleted jobs don't come back. Jobs I never applied to
  are deleted after 30 days.
- GitHub Actions minutes are unlimited because the repo is public. There are no secrets in the repo.

## Running locally

```bash
cd agents && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp .env.example .env
.venv/bin/python -m jobfinder.pipeline --trigger manual --all-sources
.venv/bin/python -m jobfinder.pipeline --job JF-20260930-ABCDE   # redo one job
.venv/bin/python -m jobfinder.pipeline --user me@example.com     # one user

cd app && flutter run -d chrome --dart-define-from-file=env.json
```
