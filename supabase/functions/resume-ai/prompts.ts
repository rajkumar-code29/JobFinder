// Prompts for the resume builder. The CV rules follow UK university careers guidance: one column, standard
// headings, reverse chronological order, evidence over adjectives, and wording that sounds like the candidate.

const STYLE = `Writing rules:
- Use only facts from the candidate's material. Never invent employers, job titles, dates, grades, numbers, tools,
  awards or results. You may reword, reorder, merge and trim. If something is vague, keep it general instead of
  making it specific.
- British English spelling (organise, programme, centre, analyse, licence as a noun).
- Plain, concrete language that sounds like a real person, not a template. Vary sentence length and openings.
- Never use these words or phrases: hard-working, passionate, highly motivated, dynamic, results-driven,
  detail-oriented, team player, go-getter, synergy, leverage, spearheaded, utilise, thrive, proven track record,
  cutting-edge, seamless, furthermore, moreover, additionally, in today's world.
- No em dashes. Use commas or full stops instead. Date ranges are the only place for an en dash ("Sept 2023 – Present").
- Don't mention a photo, date of birth, age, gender, religion or marital status, even if the material does.`;

export const CV_SYSTEM = `You are an experienced UK university careers adviser. You help students, graduates and
professionals turn rough notes into an honest, well-organised CV that an applicant tracking system can read and a
hiring manager enjoys reading.

${STYLE}`;

const CV_RULES = `CV rules:
- Bullets start with a varied, concrete verb (past tense for finished roles, present tense for current ones), make one
  point each, run roughly 8 to 25 words, say what was done and what it achieved or what skill it shows, and end with
  a full stop. Two bullets in the same entry never start with the same verb.
- If a job advert is given, reuse its exact wording for skills the candidate genuinely has, so tracking software
  matches them. Never add a keyword the material doesn't support.
- Write a qualification in full with its abbreviation, e.g. "Master of Engineering (MEng) Mechanical Engineering",
  "BA (Hons) Marketing", "BSc (Hons) Computer Science".
- Dates look like "Sept 2023 – Present", "Jun 2024", "2019 – 2023" (months: Jan Feb Mar Apr May Jun Jul Aug Sept Oct
  Nov Dec). Entries within a section go newest first.
- Keep it tight: a CV is one or two full A4 pages, so cut repetition and weak points rather than padding.`;

export const SECTION_GUIDE: Record<string, string> = {
  profile: `One paragraph of at most 4 lines (about 45-70 words). Say what the person studies or does now, the most
relevant thing they've done (with evidence), and what they're looking for, naming the target role. Don't open with
"I am a". First person is fine, but don't start every sentence with "I". For a part-time CV, mention availability
if it's given and the kind of work wanted.`,
  education: `Entries, newest first. title = the qualification in full with grade or predicted grade if given;
org = institution; location; dates. lines: "Relevant modules: ..." when modules are given, then dissertation or
project titles. bullets: at most two, for what they achieved or learned, only if the material has it. For a school,
summarise subjects and grades in a single line and use no bullets. On a part-time CV keep education short.`,
  experience_relevant: `Entries, newest first. title = job title, org = organisation, location, dates. Two to four
bullets each, aimed at the target role. Set "heading" to a field-specific heading when it reads better, such as
"Marketing Experience" or "Engineering Work Experience"; otherwise "Relevant Experience".`,
  experience_other: `Entries, newest first. One or two bullets each, focused on transferable skills that matter
for the target role (customer service, teamwork, working under pressure, responsibility). Several similar short jobs
can be merged into one entry, e.g. "Various retail roles".`,
  volunteering: `Entries, newest first. One or two bullets each about what they did and the skills it shows.`,
  projects: `Entries for academic, personal or group projects. title = project name, org = context (module,
competition, personal), dates if given. One or two bullets on the aim, their role and the result.`,
  skills_evidence: `This is a skills-based CV. groups: four to six skills the target role needs (for example
Teamwork, Communication, Organisation, Problem solving, Analytical thinking, Leadership), each with one to three
bullets of evidence taken from anywhere in the material (jobs, studies, volunteering, clubs). Only include a skill
when there is evidence for it. Use "text" = "" for these groups.`,
  skills_list: `groups with a short label and a one-line comma-separated "text", e.g. {"label": "Technical",
"text": "Python, SQL, Power BI"}, {"label": "IT", "text": "Microsoft Excel, Word, PowerPoint"}. Two to four groups,
no bullets.`,
  achievements: `bullets: awards, prizes, positions of responsibility and scholarships, one line each, with the year
if given.`,
  certifications: `bullets: one line each, "Name, issuer (year)".`,
  languages: `bullets: one per language with level, e.g. "Spanish – Intermediate (B1)".`,
  interests: `bullets: one or two lines per interest saying what it involves or shows (a team captained, a goal,
a skill). Leave out generic interests like reading or socialising unless there's something specific about them.`,
  additional: `bullets: short facts such as driving licence, visa or right-to-work status, first aid certificates,
availability. One line each.`,
};

const SECTION_SHAPE = `Each section is an object with these keys (leave unused ones as empty lists):
{"heading": str (only for experience_relevant, otherwise omit), "paragraphs": [str], "bullets": [str],
 "groups": [{"label": str, "text": str, "bullets": [str]}],
 "entries": [{"title": str, "org": str, "location": str, "dates": str, "lines": [str], "bullets": [str]}]}`;

export const TARGETS: Record<string, string> = {
  part_time: "a part-time job alongside studies (retail, hospitality, call centre and similar)",
  internship: "an internship, summer placement or work experience while studying",
  graduate: "a graduate job or graduate scheme",
  professional: "a professional role for someone with work experience",
};

export const CV_TYPES: Record<string, string> = {
  chronological: "chronological CV with education near the top",
  experience_first: "chronological CV with experience before education",
  skills: "skills-based CV where evidence is grouped under skills",
  one_page: "one-page CV that keeps only what matters for this role",
  part_time: "one-page part-time job CV: experience first, education short",
};

function clip(value: unknown, max: number): string {
  const s = typeof value === "string" ? value : JSON.stringify(value ?? "");
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

export type SectionRequest = { key: string; guide: string };

export function cvPrompt(opts: {
  target: string;
  cvType: string;
  role: string;
  jobAd: string;
  answers: unknown;
  sections: SectionRequest[];
  notes: Record<string, string>;
  current: Record<string, unknown>;
}): string {
  const wanted = opts.sections.map((s) => `- ${s.key}: ${SECTION_GUIDE[s.guide] ?? ""}`).join("\n");
  const redo = Object.keys(opts.current).length
    ? `\nThe candidate wants a different version of these sections. Write a clearly different version that still
follows every rule. What they asked for (may be empty): ${clip(JSON.stringify(opts.notes), 1500)}
Current version: ${clip(JSON.stringify(opts.current), 8000)}\n`
    : "";
  return `Write the following CV sections for this candidate.

Target: ${TARGETS[opts.target] ?? opts.target}
CV format: ${CV_TYPES[opts.cvType] ?? opts.cvType}
Role they want: ${opts.role || "not given"}
Job advert: ${opts.jobAd ? clip(opts.jobAd, 7000) : "none given"}

${CV_RULES}

Sections to write (use exactly these keys):
${wanted}

${SECTION_SHAPE}
${redo}
Candidate's answers (their own words, may be rough or in note form):
${clip(JSON.stringify(opts.answers), 24000)}

Return ONLY JSON: {"sections": {"<key>": {...}}}`;
}

export const PARSE_SYSTEM = `You copy information out of CVs accurately. You never add or improve anything.`;

export function parsePrompt(text: string | null, role: string): string {
  return `Copy the information from this CV into JSON. Keep the candidate's own wording; don't polish it.
Put each role's duties and achievements into "details" as separate lines. Use "" for anything missing.
kind is "relevant" when the role relates to ${role ? `"${role}"` : "the candidate's main field"}, "volunteering"
for unpaid or volunteer roles, otherwise "other".

Return ONLY JSON with exactly this shape:
{"contact": {"name": str, "email": str, "phone": str, "location": str, "linkedin": str, "website": str},
 "about": "their summary or personal statement, if any",
 "education": [{"qualification": str, "institution": str, "location": str, "start": str, "end": str,
                "grade": str, "modules": str, "details": str}],
 "experience": [{"kind": "relevant|other|volunteering", "title": str, "organisation": str, "location": str,
                 "start": str, "end": str, "details": str}],
 "projects": [{"name": str, "context": str, "dates": str, "details": str}],
 "skills": {"technical": str, "it": str, "soft": str},
 "achievements": str, "certifications": str, "languages": str, "interests": str, "additional": str}
${text ? `\nCV:\n${clip(text, 30000)}` : "\nThe CV is the attached PDF."}`;
}

export const LETTER_SYSTEM = `You are a UK careers adviser helping someone write their own cover letter. It has to
sound like them: warm, direct and specific. A hiring manager should be able to tell it was written for this job only.

${STYLE}`;

export const LETTER_PARTS: Record<string, string> = {
  opening: "One or two sentences: the role they're applying for and where they saw it. For a speculative letter, the kind of opportunity they're asking about.",
  motivation: "One paragraph: who they are and why this role and this organisation appeal to them, based on their notes and the advert. Never invent facts about the organisation; if there are no notes about it, talk about what in the role or advert appeals.",
  skills: "One or two paragraphs (separate them with a blank line): match two or three of the advert's most important requirements to evidence from the CV, saying where the skill was shown. Refer to the CV instead of repeating it, at most once (for example \"as you can see from my CV\").",
  closing: "Two or three sentences: thank them for their time, close confidently, and say they'd welcome the chance to discuss it at interview.",
};

export function letterPrompt(opts: {
  inputs: Record<string, string>;
  resumeText: string | null;
  parts: string[];
  notes: Record<string, string>;
  current: Record<string, string>;
}): string {
  const i = opts.inputs;
  const wanted = opts.parts.map((p) => `- ${p}: ${LETTER_PARTS[p]}`).join("\n");
  const redo = Object.keys(opts.current).length
    ? `\nThe candidate wants a different version of these parts. Write a clearly different version that still follows
every rule. What they asked for (may be empty): ${clip(JSON.stringify(opts.notes), 1000)}
Current version: ${clip(JSON.stringify(opts.current), 4000)}
The rest of the letter, for context only: ${clip(JSON.stringify(i.rest ?? ""), 3000)}\n`
    : "";
  return `Write parts of a cover letter.

Job title: ${i.job_title || "not given"}
Organisation: ${i.company || "not given"}
Where they found it: ${i.source || "not given"}
${i.job_ad ? `Job advert:\n${clip(i.job_ad, 7000)}` : "No advert: this is a speculative letter."}
Their notes on why they want this job and organisation: ${i.why || "none"}

The whole letter (all four parts) should be 250 to 380 words and fit on one page. Don't write the greeting,
sign-off, addresses or date; those are added separately.

Parts to write (use exactly these keys):
${wanted}
${redo}
${opts.resumeText ? `The candidate's CV:\n${clip(opts.resumeText, 20000)}` : "The candidate's CV is the attached PDF."}

Return ONLY JSON: {"parts": {"<key>": "text"}}`;
}
