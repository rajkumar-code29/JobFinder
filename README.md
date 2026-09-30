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
| Your board links: Greenhouse / Lever / Ashby / Workable / Workday / SmartRecruiters | free public feeds | hourly |
| Any other link (LinkedIn, Indeed, Naukri, careers page) | Gemini `site:` search | every 4h |

### What to paste in *Job boards & career pages*
| Link | How it's read |
|---|---|
| `boards.greenhouse.io/<company>`, `jobs.lever.co/<company>`, `jobs.ashbyhq.com/<company>`, `apply.workable.com/<company>` | Company's public feed: every open job, full descriptions |
| `<company>.wd5.myworkdayjobs.com/en-US/<SiteName>` | Workday feed, searched by your roles; full details loaded for new jobs only (40 per run) |
| `jobs.smartrecruiters.com/<CompanyId>` | SmartRecruiters feed, searched by your roles |
| `linkedin.com`, `indeed.com`, `naukri.com`, `glassdoor.com`, … | Not visited. Google search limited to the site's job pages (`site:linkedin.com/jobs/view …`), max 10 results every 4h, short descriptions. Only the domain matters; search filters in the link are ignored. JSearch (RapidAPI key) covers LinkedIn/Indeed/Glassdoor better. |
| Any other careers page | Google `site:` search on that domain/path. Tip: if its Apply buttons go to one of the platforms above, paste that link instead. |

---

## Setup (≈30 minutes, one time)

### 1. Supabase
1. Create a free project at <https://supabase.com>.
2. **SQL Editor** → paste and run [`supabase/migrations/001_init.sql`](supabase/migrations/001_init.sql).
   After creating your user (step 3), also run [`002_multi_user.sql`](supabase/migrations/002_multi_user.sql).
   Check: **Table Editor** shows `settings, profile, jobs, pipeline_runs, agent_runs`; **Storage** shows buckets `parent` and `jobs`.
3. Left sidebar **Authentication → Users → Add user → Create new user**, tick **Auto Confirm User**.
   This is your *app* login. It is separate from your supabase.com account, but it can use the same email/password.
4. **Authentication → Sign In / Providers**: turn **off** "Allow new users to sign up" (only you can log in).
5. Get the connection values (or click **Connect** at the top of the project page):
   - Project URL: **Project Settings → Data API** (`https://<ref>.supabase.co`) → `SUPABASE_URL`
   - Publishable key `sb_publishable_…` (or legacy `anon`): **Project Settings → API Keys** → `SUPABASE_ANON_KEY` (app)
   - Secret key `sb_secret_…` (or legacy `service_role`): same page → `SUPABASE_SERVICE_ROLE_KEY` (agents only, keep private)
6. Once the domain is live: **Authentication → URL Configuration** → Site URL `https://jobs.<your-domain>` and add
   `https://jobs.<your-domain>/**` under Redirect URLs. **Required for invites and password resets**. Until it's set,
   email links open `http://localhost:3000`.

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
   For fallback keys use the list forms instead/as well: `GEMINI_API_KEYS=k1,k2`, `ADZUNA_KEYS=id1:key1,id2:key2`,
   `RAPIDAPI_KEYS=k1,k2` (see *Users & API keys* below).
3. Optional **Variables**: `GEMINI_MODEL`, `GEMINI_FAST_MODEL`.
4. **Actions → Job agents (hourly) → Run workflow** to test. After that it runs every hour.

### 4. Web app on your subdomain (Cloudflare Pages, free)
1. Sign up / log in at <https://dash.cloudflare.com>.
2. **Account ID**: shown in the dashboard URL (`dash.cloudflare.com/<account-id>/…`) and on
   **Workers & Pages** (right sidebar) → GitHub secret `CLOUDFLARE_ACCOUNT_ID`.
3. **API token**: profile icon → **My Profile → API Tokens → Create Token → Create Custom Token**,
   permission **Account · Cloudflare Pages · Edit**, account resources = your account → GitHub secret `CLOUDFLARE_API_TOKEN`.
4. GitHub → **Actions → Deploy web app → Run workflow**. The first run creates the `jobfinder` Pages project
   and deploys; the app is then live at `https://jobfinder.pages.dev` (Cloudflare may add a suffix if taken).
5. Cloudflare → **Workers & Pages → jobfinder → Custom domains → Set up a custom domain** → `jobs.<your-domain>`.
   - Domain's DNS on Cloudflare: the record is created for you.
   - DNS elsewhere (GoDaddy, Namecheap, Google/Squarespace…): add at your registrar a **CNAME** record,
     name `jobs`, value `jobfinder.pages.dev` (use the exact value Cloudflare shows). Activation takes minutes to a few hours.
6. Supabase → **Authentication → URL Configuration** → Site URL `https://jobs.<your-domain>`.

### 4b. Punctual hourly runs (Cloudflare scheduler, free)
GitHub's own cron is best-effort and often hours late, so a tiny Cloudflare Worker (`scheduler/`) starts the
agents workflow every hour at :07 UTC. GitHub's cron stays as a 3-hourly backup; duplicate runs are skipped.
1. GitHub → profile → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**:
   repository access **Only select repositories → JobFinder**, permission **Actions: Read and write**. Pick an
   expiry and note it (the Worker stops starting runs when the token expires).
   Save it as the GitHub secret **`GH_DISPATCH_TOKEN`**.
2. Cloudflare → **My Profile → API Tokens** → edit the deploy token → add **Account · Workers Scripts · Edit**.
3. GitHub → **Actions → Deploy hourly scheduler → Run workflow**.
   Logs: Cloudflare → Workers & Pages → `jobfinder-scheduler` → Logs.

### 5. Upload your parent documents
Sign in → **Settings → Parent documents** → upload your resume (**.docx** is required for tailoring; add the
.pdf too) and your master cover letter. Set countries, roles and board links, then **Save**.

Or from the command line:
```bash
cd agents && python -m jobfinder.upload_parent --email you@example.com --resume ~/Documents/Me_Resume.docx ~/Documents/Me_Resume.pdf --cover ~/Documents/Cover\ Letter.docx
```

### 6. iPhone app
> Keep this repo outside iCloud-synced folders (e.g. `~/Developer/JobFinder`, not `~/Documents`). iCloud offloads
> files when the disk is low, which hangs Python/git, and its file attributes break iOS code signing
> (*"resource fork, Finder information, or similar detritus not allowed"*).

```bash
cd app && cp env.example.json env.json   # fill in URL + anon key
open ios/Runner.xcworkspace              # Signing & Capabilities → pick your Apple ID team
flutter run --release --dart-define-from-file=env.json   # with the iPhone plugged in
```
With a free Apple ID the install expires after 7 days (just re-run). A paid developer account removes that.
You can also open `https://jobs.<your-domain>` in Safari → Share → **Add to Home Screen**.

---

## Users & API keys

**Each user only sees their own data.** Jobs, files, settings, API keys and agent activity are isolated by
Supabase row-level security, and files live under `parent/<user-id>/…` and `jobs/<user-id>/<job-id>/…`.
As the Supabase project owner you can still see everything in the Supabase dashboard.

**Add a user:** Supabase → Authentication → Users → **Invite user** (they get an email, open the link, and the app asks
them to choose a password), or **Add user → Create new user** with a password you give them. Their settings are created
automatically; they then upload their resume and add their own API keys in Settings. Anyone can use
**Forgot password?** on the login screen. Supabase's built-in email sender only allows a few emails per hour.

**Limits are per user:**
- Each user's agents use **their own keys first**. The shared keys (GitHub secrets) are only used for the owner,
  or for users you allow:
  ```sql
  update accounts set use_shared_keys = true, llm_calls_per_run = 20
  where user_id = (select id from auth.users where email = 'friend@example.com');
  ```
- `llm_calls_per_run` caps each user's Gemini calls per hourly run (owner 60, others 40 by default).
- Pause a user: `update accounts set enabled = false where …`.

**Key fallback:** keys are tried in order. When one hits its limit the next is used, and the spent key is parked
until it resets (Gemini: midnight Pacific; Adzuna: next hour or next day; RapidAPI monthly quota: the 1st), so
later runs skip it. Invalid keys are parked for 24 h. Users see each key's status in Settings → API keys.
- Gemini's free quota belongs to a Google Cloud **project**, so extra keys only add quota if they come from
  different projects.
- Check each provider's terms before using several free accounts to get around its limits.
  Google and Adzuna don't allow it, and they can suspend accounts that do.
- Everyone's agents run on the owner's GitHub Actions minutes.

## Admin tools (`@rajkumar.codes` accounts)
Run [`004_admin_tools.sql`](supabase/migrations/004_admin_tools.sql), then store the GitHub token for **Run now**
in Supabase Vault (SQL editor, your fine-grained token with *Actions: Read and write* on this repo):
```sql
select vault.create_secret('github_pat_…', 'gh_dispatch_token', 'Starts the JobFinder agents workflow');
```
- **Settings → Shared keys (admin):** the shared key pool, including GitHub-secret keys (shown by their last 4
  characters). See which key is **In use**, when it was last used, whether it's paused and why; switch keys on/off,
  **Use this key first**, add or remove keys stored in the app.
- **Agents → Run now:** starts the agents workflow (at most once every 5 minutes).
- The database enforces admin access (`public.is_admin()`), not just the UI.

## Gemini safety stop
Per-minute rejections (429) are counted per user per run: 4 in a row or 12 in total stop all Gemini work for that run
and pause the rejected keys for 1 hour. Google-grounded search gives up after 2 and is skipped for the rest of the run.
Each request waits at most 90 s (search 30 s); the workflow is capped at 40 minutes. Rejections and Google's reasons
appear live in the run log (Agents → Runs).

## Local development
```bash
# agents
cd agents && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp .env.example .env    # fill in
.venv/bin/python -m jobfinder.pipeline --trigger manual --all-sources
.venv/bin/python -m jobfinder.pipeline --job JF-20260927-ABCDE    # reprocess one job
.venv/bin/python -m jobfinder.pipeline --user you@example.com      # one user only

# app
cd app && flutter run -d chrome --dart-define-from-file=env.json
```

## Free-tier budget notes
- Work is routed by model. **flash-lite** (free tier ~15/min, 500/day per model) does relevance rating, ATS scoring,
  salary lookups and Google job search. **flash** (~5/min, 20/day per model) does tailoring, interview prep and cover
  letters, about 3–4 calls per job.
- `GEMINI_MODEL` / `GEMINI_FAST_MODEL` default to `auto` (newest stable model of each family). Every model version has
  its own daily allowance, so when one is used up the agents move to the next version, then to flash-lite. With the
  current free tier that's roughly 25–30 fully flash-quality jobs a day. Set `GEMINI_USE_ALL_MODELS=false` to use just one.
- `max_jobs_per_run` (Settings, default 3) and each user's `llm_calls_per_run` cap usage. Jobs that don't
  fit in a run stay queued and resume from their last finished stage.
- Free-tier limits differ per model and change over time. On *too many requests* the agents widen the gap between
  calls (up to 60 s) and wait up to 4 min per request. If the main model's daily or free-tier limit is used up on every
  key, the rest of the run uses the light model, and the run log names Google's quota (e.g. `…PerDay…, limit 20`).
  Your real limits are shown in AI Studio under *Usage & limits*.
- Google retires Gemini versions over time. If a model is retired, the agents switch to the newest model of the same
  family and say so in the run log (Agents → Runs); update `GEMINI_MODEL` / `GEMINI_FAST_MODEL` when you see that.
- GitHub Actions minutes: unlimited on a **public** repo, 2,000 min/month on a private one. A scan-only run takes
  ~2 min, and a run that processes jobs takes up to ~8 min (Gemini free-tier pacing), so hourly on a private repo can exceed
  2,000 min. Options: make the repo public (no secrets or personal files live in it: keys are Action secrets and
  your resume lives in Supabase), or change the cron in `.github/workflows/agents.yml` to every 2 hours (`7 */2 * * *`).
