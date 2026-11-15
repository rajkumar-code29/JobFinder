# Pounce

(The repo and code still use the old name, JobFinder.)

I got tired of scrolling job boards and rewriting my resume for every application, so I built this. A set of
agents runs every hour, finds jobs that actually match my resume, tailors a copy of my resume for each one,
writes a cover letter and puts together interview prep. I check the results in a Flutter app, on the web at
jobs.rajkumar.codes or on my iPhone, and apply from there.

Everything runs on free tiers: GitHub Actions for the agents, Supabase for the database, auth and files,
Gemini for the AI work, and Cloudflare for the website and the hourly trigger.

## What it does

Finding and scoring jobs is free for everyone. The paid part is per job and on request: a tailored resume and cover
letter (1 credit) or interview prep (1 credit). Asking holds the credits; they're only taken when the work succeeds,
so a failure costs nothing and shows an error code instead. Credits come from referrals: when someone signs up with
a friend's code and verifies their email, both get 30. People can also buy packs (20 for £5, 50 for £10, 200 for
£20), and admins can add credits. Each
email address can only earn sign-up credits once: a one-way hash of every address is kept even after an account is
deleted, Gmail dots and `+tags` count as the same address, throwaway inbox domains get nothing, and a code earns at
most 5 rewards a day and 20 in total. The admin panel lists every referral, including the declined ones and why.

Each run works in batches of up to 20 jobs:

1. **Scout** looks at the company career pages I've added and a few job APIs, and keeps only jobs that fit my
   resume. Once it has 20 it stops, and those 20 become the next batch.
2. **Salary** takes the salary from the posting, or estimates it from salary sites. If there's nothing, it's NA.
3. **Scorer** gives every job an ATS score against my resume and ranks the batch.
4. **Tailor, Coach and Writer** run when someone asks for them on a job (`--work`, started straight from the app):
   a tailored resume (the original .docx with edits, same file name), a cover letter, and interview prep (MCQs with
   explanations, technical and coding questions).

Every posting the scouts fetch also goes on a shared **Jobs** board (kept 30 days) that anyone can search with
keywords, location, date posted, workplace, job type and salary. Jobs the scout rated for you show your match.

Every job gets its own folder in storage with the job details, the scoring report, the tailored resume (docx
and pdf), the cover letter and the interview pack. In the app I can open a job, pick which resume to send,
open the application page, mark it applied, or delete it.

A new batch only starts once the current one is done. On free tiers that's a few jobs an hour.

**Custom jobs.** When I find a job myself, I paste the title and description on the Custom page (company, link and
a batch number are optional) and press Process now. That starts a run just for those jobs, with the same scoring,
tailored resume, cover letter and interview prep. They stay on that page, never join the hourly batches and aren't
cleaned up after 30 days.

**Resume builder.** For friends who are students or don't have a decent CV yet. It follows UK university careers
guidance: one column, standard headings, reverse chronological order, evidence instead of buzzwords, one or two full
A4 pages. You pick what the CV is for (part-time job, internship, graduate job, professional role), which sets the
format and section order, and then either answer questions and let the AI write it, use your own words as typed, or
start from your current resume. Every section can be regenerated, edited or switched back to your own words before
you download Word or PDF, and you can make the result your master resume. It also writes UK-style cover letters
from your resume ("Yours sincerely" to a named person, "Yours faithfully" otherwise). The AI part runs in a Supabase
Edge Function (`supabase/functions/resume-ai`) on the shared keys, 20 requests a day each; the files are made in the app.

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
1. Create a free project and run the files in `supabase/migrations/` in order (001 to 013) in the SQL editor.
   Create your own user first (Authentication > Users > Add user, tick Auto Confirm) because 002 makes the
   oldest user the owner.
2. Turn on "Allow new users to sign up" and "Confirm email" under Authentication > Sign In / Providers. Accounts
   can't do anything until the email is verified. Set up custom SMTP (Resend or Brevo, both free) because the
   built-in one only sends a few emails an hour, and verification emails would stall.
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
`CLOUDFLARE_ACCOUNT_ID` and `GH_DISPATCH_TOKEN`. The resume builder's Edge Function is deployed by the "Deploy
Supabase functions" workflow, which needs `SUPABASE_ACCESS_TOKEN` (Supabase dashboard > Account > Access Tokens).

The Cloudflare token needs Pages: Edit and Workers Scripts: Edit. `GH_DISPATCH_TOKEN` is a fine-grained token
for this repo only, with Actions: Read and write.

**Payments** (optional, everything else works without them)

Credits are sold through Stripe Checkout on the website and Android, and through Apple In-App Purchase in the iPhone
app (Apple requires that for digital credits; the iPhone app never mentions Stripe or the website). The functions
check every payment with Stripe or Apple before adding credits, add them once per payment, and take them back on a
refund. Set these as Supabase Edge Function secrets (Edge Functions > Secrets):

- Stripe: `STRIPE_SECRET_KEY`, and `STRIPE_WEBHOOK_SECRET` from a webhook endpoint pointing at
  `https://<project>.supabase.co/functions/v1/stripe-webhook` with the events `checkout.session.completed`,
  `checkout.session.async_payment_succeeded` and `charge.refunded`.
- Apple: sign the Paid Apps agreement, create three consumable in-app purchases with the IDs
  `com.rajkumargk.jobfinder.credits20`, `.credits50` and `.credits200` (price points closest to £5, £10, £20), and
  an In-App Purchase key under Users and Access > Integrations. Then set `APPLE_IAP_ISSUER_ID`, `APPLE_IAP_KEY_ID`
  and `APPLE_IAP_PRIVATE_KEY` (the .p8 contents). For refunds, set App Store Server Notifications (version 2) to
  `https://<project>.supabase.co/functions/v1/apple-notifications`.

**Cloudflare**
1. Run the "Deploy web app" workflow. It creates the Pages project and deploys.
2. Add your domain under the Pages project's Custom domains. If DNS is elsewhere, add the CNAME it shows.
3. Run "Deploy hourly scheduler". That's a small Worker that starts the agents at :07 every hour, because
   GitHub's own cron can be hours late. The GitHub cron is still there as a backup every 3 hours.

**In the app**

Sign in, agree to the privacy notice, and follow the setup guide it opens: upload the resume as .docx (plus the
PDF and a master cover letter) and pick locations and roles. Settings > Appearance has light and dark mode and six
colour themes.

**iPhone**
```bash
cd app && cp env.example.json env.json   # fill in
flutter build ios --release --dart-define-from-file=env.json
```
Then install with Xcode or `xcrun devicectl device install app`. Keep the repo outside iCloud-synced folders,
because iCloud offloads files and breaks code signing. To ship a TestFlight build: `cd app && ./tool/testflight.sh`.

**Android**
GitHub Actions builds a signed APK on every push that touches the app and puts it on the `android` release:
https://github.com/rajkumar-code29/JobFinder/releases/download/android/pounce.apk
People open that link on their phone, download it and allow installs from the browser when asked. To update they
install the new APK over the old one. The build needs two secrets, `ANDROID_KEYSTORE_BASE64` and
`ANDROID_KEYSTORE_PASSWORD`. Keep a backup of the upload key: without it, existing installs can't be updated.

## Other users

Anyone can sign up from the sign-in page with their name, email and a password. They verify the email from the
link they're sent, and the first time they sign in the app shows a privacy notice listing exactly which AI
providers see their resume; nothing happens until they agree. Until the email is verified the database gives
them nothing. Everyone gets their own settings and only ever sees their own jobs, which row-level security
enforces. Nobody needs an API key: everyone runs on the shared keys (people who added keys before still have them
tried first). Settings > Users lets me search accounts, see whether each person is set up, their last run and
storage, and block an account if needed.

People can delete their own account in Settings > Account, which removes their files and every row straight
away (the `account` Edge Function). As the project owner I can still see everything in the Supabase dashboard,
and the privacy notice says so.

## Admin bits

Accounts on @rajkumar.codes get the admin tools:

- **Pause all** on Home is a kill switch for every agent.
- **Run now** under Agents.
- **Shared keys** in Settings, including which key is currently in use. Only admins can add keys.
- **Admin panel** (Settings > the shield icon): users with their credits (add or remove, with a note they see),
  adding a job by hand to the board or to one person, and the referrals list.
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
.venv/bin/python -m jobfinder.pipeline --custom <user id>        # that user's Custom page jobs

cd app && flutter run -d chrome --dart-define-from-file=env.json
```
