// Cron trigger -> workflow_dispatch on the agents workflow.
// GH_DISPATCH_TOKEN: fine-grained token, this repo only, Actions read/write.
export default {
  async scheduled(event, env, ctx) {
    ctx.waitUntil(dispatch(env, event.cron));
  },
};

async function dispatch(env, cron) {
  if (!env.GH_DISPATCH_TOKEN || !env.GITHUB_REPO) {
    throw new Error("GH_DISPATCH_TOKEN / GITHUB_REPO not configured");
  }
  const url = `https://api.github.com/repos/${env.GITHUB_REPO}/actions/workflows/${env.WORKFLOW}/dispatches`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GH_DISPATCH_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
      "User-Agent": "jobfinder-scheduler",
    },
    // "schedule" so the per-source throttles still apply
    body: JSON.stringify({ ref: env.BRANCH, inputs: { trigger: "schedule", all_sources: "false" } }),
  });
  if (res.status !== 204) {
    const detail = (await res.text()).slice(0, 300);
    // 401: expired/revoked token, 403/404: missing Actions write
    throw new Error(`GitHub dispatch failed (${res.status}): ${detail}`);
  }
  console.log(`Started ${env.WORKFLOW} on ${env.GITHUB_REPO}@${env.BRANCH} (cron ${cron})`);
}
