# JobFinder

Hourly job-hunting agents plus a Flutter app (web on your subdomain + iPhone), built entirely on free tiers.

```
GitHub Actions (hourly cron)                     Supabase (free)                 Flutter app
┌───────────────────────────────┐   writes   ┌──────────────────────┐  reads  ┌───────────────────┐
│ Profile  → knows parent resume│──────────▶ │ Postgres: jobs,      │ ◀────── │ Home stats (live) │
│ Scout    → APIs + Google search│           │  settings, profile,  │         │ Job cards → detail│
│ Salary   → JD / Glassdoor est. │           │  agent_runs, runs    │         │ Apply (pick resume│
│ Scorer   → ATS + suggestions   │           │ Storage:             │         │  from job folder) │
│ Tailor   → job-specific resume │           │  parent/  (masters)  │         │ Interview prep    │
│ Coach    → MCQ/tech/coding prep│           │  jobs/<job_id>/ …    │         │ Settings/uploads  │
│ Writer   → cover letter        │           └──────────────────────┘         └───────────────────┘
└───────────────────────────────┘   LLM: Gemini (Google AI Studio free key) with Google Search grounding
```

Every captured job gets its own folder `jobs/<job_id>/`:

| File | Made by |
|---|---|
| `job.json` | Scout (company, JD, salary, links; missing values = `NA`) |
| `report.json`, `Suggestions Report.md` | Scorer (+ Tailor appends before/after scores) |
| `<Your parent resume name>.docx` / `.pdf` | Tailor |
| `tailored_report.json` | Tailor (includes **added adjacent skills** to review) |
| `interview.json` | Coach |
| `Cover Letter.docx` / `.pdf` | Writer |

## Job sources (no scraping)

| Source | Cost | Cadence |
|---|---|---|
| Adzuna API | free key | hourly |
| Arbeitnow API | free, no key | hourly |
| Remotive API | free, no key | every 6h (their limit) |
| JSearch (Google for Jobs: LinkedIn/Indeed/Glassdoor…) | free 200 req/month | once a day (06 UTC) |
| Gemini + Google Search | free | every 4h |
| Your board links: Greenhouse / Lever / Ashby / Workable | free public APIs | hourly |
| Any other link (LinkedIn, Indeed, Naukri, careers page) | Gemini `site:` search | every 4h |

---

## Setup (≈30 minutes, one time)

### 1. Supabase
1. Create a free project at <https://supabase.com>.
2. **SQL Editor** → paste and run [`supabase/migrations/001_init.sql`](supabase/migrations/001_init.sql).
   Check: **Table Editor** shows `settings, profile, jobs, pipeline_runs, agent_runs`; **Storage** shows buckets `parent` and `jobs`.
3. Left sidebar **Authentication → Users → Add user → Create new user**, tick **Auto Confirm User**.
   This is your *app* login. It is separate from your supabase.com account, but it can use the same email/password.
4. **Authentication → Sign In / Providers**: turn **off** "Allow new users to sign up" (only you can log in).
5. Get the connection values (or click **Connect** at the top of the project page):
   - Project URL: **Project Settings → Data API** (`https://<ref>.supabase.co`) → `SUPABASE_URL`
   - Publishable key `sb_publishable_…` (or legacy `anon`): **Project Settings → API Keys** → `SUPABASE_ANON_KEY` (app)
   - Secret key `sb_secret_…` (or legacy `service_role`): same page → `SUPABASE_SERVICE_ROLE_KEY` (agents only, keep private)
6. Later, once the domain is live: **Authentication → URL Configuration** → Site URL `https://jobs.<your-domain>`.

### 2. API keys
- Gemini: <https://aistudio.google.com/apikey>
- Adzuna: <https://developer.adzuna.com> (app id + key)
- Optional JSearch: subscribe to the free plan at <https://rapidapi.com/letscrape-6bRBa3QguO5/api/jsearch>

> Free-tier Gemini may use prompts to improve Google's models. Your resume is sent to it. Enable billing
> on the AI Studio project (still free within limits) if you want that turned off.

### 3. GitHub repo + hourly agents
1. Push this folder to a **private** GitHub repo.
2. **Settings → Secrets and variables → Actions → Secrets**: add
   `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`, `GEMINI_API_KEY`,
   `ADZUNA_APP_ID`, `ADZUNA_APP_KEY`, `RAPIDAPI_KEY` (optional),
   `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` (step 4).
3. Optional **Variables**: `GEMINI_MODEL`, `GEMINI_FAST_MODEL`, `LLM_MAX_CALLS_PER_RUN`.
4. **Actions → Job agents (hourly) → Run workflow** to test. After that it runs every hour.

### 4. Web app on your subdomain (Cloudflare Pages, free)
1. Cloudflare dashboard → **Workers & Pages → Create → Pages** → project name `jobfinder`
   (or run the workflow once; it creates it).
2. Create an API token with *Cloudflare Pages: Edit* → save as `CLOUDFLARE_API_TOKEN`; save your account id.
3. Push to `main` (or run **Deploy web app**) → it builds Flutter web and deploys.
4. Pages project → **Custom domains** → add `jobs.<your-domain>`. If your domain's DNS isn't on Cloudflare,
   add the CNAME it shows you at your registrar.

### 5. Upload your parent documents
Sign in → **Settings → Parent documents** → upload your resume (**.docx** is required for tailoring; add the
.pdf too) and your master cover letter. Set countries, roles and board links, then **Save**.

Or from the command line:
```bash
cd agents && python -m jobfinder.upload_parent --resume ~/Documents/Me_Resume.docx ~/Documents/Me_Resume.pdf --cover ~/Documents/Cover\ Letter.docx
```

### 6. iPhone app
> If this folder is inside iCloud-synced `~/Documents`, iOS builds fail with *"Failed to codesign Flutter.framework … resource fork, Finder information, or similar detritus"*. Move the repo somewhere iCloud doesn't sync (e.g. `~/Developer/JobFinder`).

```bash
cd app && cp env.example.json env.json   # fill in URL + anon key
open ios/Runner.xcworkspace              # Signing & Capabilities → pick your Apple ID team
flutter run --release --dart-define-from-file=env.json   # with the iPhone plugged in
```
With a free Apple ID the install expires after 7 days (just re-run). A paid developer account removes that.
You can also open `https://jobs.<your-domain>` in Safari → Share → **Add to Home Screen**.

---

## Local development
```bash
# agents
cd agents && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp .env.example .env    # fill in
.venv/bin/python -m jobfinder.pipeline --trigger manual --all-sources
.venv/bin/python -m jobfinder.pipeline --job JF-20260927-ABCDE    # reprocess one job

# app
cd app && flutter run -d chrome --dart-define-from-file=env.json
```

## Free-tier budget notes
- Each fully processed job ≈ 6–8 Gemini calls (score, salary, 1–2 tailor passes + re-scores, interview, cover letter).
- `max_jobs_per_run` (Settings, default 3) and `LLM_MAX_CALLS_PER_RUN` (default 60) cap usage. Jobs that don't
  fit in a run stay queued and resume from their last finished stage.
- If you hit Gemini's daily limit, lower `max_jobs_per_run` or set `GEMINI_MODEL=gemini-2.5-flash-lite`.
- GitHub Actions minutes: unlimited on a **public** repo, 2,000 min/month on a private one. A scan-only run takes
  ~2 min, and a run that processes jobs takes up to ~8 min (Gemini free-tier pacing), so hourly on a private repo can exceed
  2,000 min. Options: make the repo public (no secrets or personal files live in it: keys are Action secrets and
  your resume lives in Supabase), or change the cron in `.github/workflows/agents.yml` to every 2 hours (`7 */2 * * *`).
