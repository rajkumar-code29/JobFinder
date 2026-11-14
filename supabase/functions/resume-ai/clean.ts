// Normalises what the models return, so the app always gets the same shapes.
export const str = (v: unknown) => (typeof v === "string" ? v : v == null ? "" : String(v)).replace(/\s*—\s*/g, ", ").trim();
export const strs = (v: unknown): string[] =>
  Array.isArray(v) ? v.map(str).filter(Boolean) : typeof v === "string" && v.trim() ? [str(v)] : [];
export const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {});

export function cleanSection(raw: unknown) {
  const s = obj(raw);
  const out: Record<string, unknown> = {
    paragraphs: strs(s.paragraphs),
    bullets: strs(s.bullets),
    groups: (Array.isArray(s.groups) ? s.groups : []).map(obj)
      .map((g) => ({ label: str(g.label), text: str(g.text), bullets: strs(g.bullets) }))
      .filter((g) => g.label || g.text || g.bullets.length),
    entries: (Array.isArray(s.entries) ? s.entries : []).map(obj)
      .map((e) => ({
        title: str(e.title), org: str(e.org), location: str(e.location), dates: str(e.dates),
        lines: strs(e.lines), bullets: strs(e.bullets),
      }))
      .filter((e) => e.title || e.org || e.lines.length || e.bullets.length),
  };
  if (typeof s.heading === "string" && s.heading.trim()) out.heading = str(s.heading);
  return out;
}

export function cleanAnswers(raw: unknown) {
  const a = obj(raw);
  const c = obj(a.contact);
  const sk = obj(a.skills);
  const list = (v: unknown, fields: string[]) =>
    (Array.isArray(v) ? v : []).map(obj).map((x) => Object.fromEntries(fields.map((f) => [f, str(x[f])])))
      .filter((x) => Object.values(x).some(Boolean));
  const experience = list(a.experience, ["kind", "title", "organisation", "location", "start", "end", "details"])
    .map((e) => ({ ...e, kind: ["relevant", "other", "volunteering"].includes(e.kind) ? e.kind : "other" }));
  return {
    contact: Object.fromEntries(["name", "email", "phone", "location", "linkedin", "website"].map((f) => [f, str(c[f])])),
    about: str(a.about),
    education: list(a.education, ["qualification", "institution", "location", "start", "end", "grade", "modules", "details"]),
    experience,
    projects: list(a.projects, ["name", "context", "dates", "details"]),
    skills: { technical: str(sk.technical), it: str(sk.it), soft: str(sk.soft) },
    achievements: str(a.achievements),
    certifications: str(a.certifications),
    languages: str(a.languages),
    interests: str(a.interests),
    additional: str(a.additional),
  };
}
