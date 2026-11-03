// Reads releases from the GitHub API so the download button and the releases
// page always show the latest build. Falls back to the GitHub pages when the
// API is unavailable (offline, rate limited).
const REPO = "Edwardrem/Tepfasonic-Client";
const API = `https://api.github.com/repos/${REPO}/releases`;

function formatBytes(n) {
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(1) + " MB";
  if (n >= 1 << 10) return Math.round(n / (1 << 10)) + " KB";
  return n + " B";
}

function formatDate(iso) {
  return new Date(iso).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
}

function findAsset(release, suffix) {
  return (release.assets || []).find((a) => a.name.endsWith(suffix));
}

// Minimal Markdown for release notes: headings, bullets, code spans, links.
function renderNotes(markdown) {
  const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const inline = (s) =>
    escape(s)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="$2">$1</a>');
  const lines = (markdown || "").split(/\r?\n/);
  let html = "";
  let inList = false;
  for (const raw of lines) {
    const line = raw.trimEnd();
    if (/^\s*[-*] /.test(line)) {
      if (!inList) { html += "<ul>"; inList = true; }
      html += `<li>${inline(line.replace(/^\s*[-*] /, ""))}</li>`;
      continue;
    }
    if (inList) { html += "</ul>"; inList = false; }
    if (/^### /.test(line)) html += `<h4>${inline(line.slice(4))}</h4>`;
    else if (/^## /.test(line)) html += `<h4>${inline(line.slice(3))}</h4>`;
    else if (line.trim() === "") continue;
    else html += `<p>${inline(line)}</p>`;
  }
  if (inList) html += "</ul>";
  return html;
}

async function fetchReleases() {
  const response = await fetch(API, { headers: { Accept: "application/vnd.github+json" } });
  if (!response.ok) throw new Error(`GitHub API ${response.status}`);
  return response.json();
}

// Landing / download pages: point the button at the latest DMG.
async function wireDownloadButton() {
  const button = document.querySelector("[data-download-latest]");
  if (!button) return;
  try {
    const releases = await fetchReleases();
    const stable = releases.find((r) => !r.prerelease && !r.draft) || releases.find((r) => !r.draft);
    if (!stable) return;
    const dmg = findAsset(stable, ".dmg");
    if (dmg) button.href = dmg.browser_download_url;
    const version = document.querySelector("[data-latest-version]");
    if (version) version.textContent = `${stable.tag_name.replace(/^v/, "")} · ${formatDate(stable.published_at)}` + (dmg ? ` · ${formatBytes(dmg.size)}` : "");
    const sums = document.querySelector("[data-latest-sums]");
    const sumsAsset = findAsset(stable, "SHA256SUMS");
    if (sums && sumsAsset) { sums.href = sumsAsset.browser_download_url; sums.classList.remove("hidden"); }
  } catch (error) {
    console.warn("Could not read releases:", error);
  }
}

// Releases page: list everything.
async function renderReleases() {
  const container = document.querySelector("[data-releases]");
  if (!container) return;
  try {
    const releases = (await fetchReleases()).filter((r) => !r.draft);
    if (releases.length === 0) {
      container.innerHTML = `<p class="note">No releases have been published yet. The first tag pushed to the repository builds one; see <a href="https://github.com/${REPO}/releases">GitHub Releases</a>.</p>`;
      return;
    }
    let latestMarked = false;
    container.innerHTML = releases.map((r) => {
      const dmg = findAsset(r, ".dmg");
      const zip = findAsset(r, ".zip");
      const sums = findAsset(r, "SHA256SUMS");
      let badge = "";
      if (r.prerelease) badge = '<span class="badge beta">beta</span>';
      else if (!latestMarked) { badge = '<span class="badge latest">latest</span>'; latestMarked = true; }
      const assets = [
        dmg ? `<a href="${dmg.browser_download_url}">Download DMG (${formatBytes(dmg.size)})</a>` : "",
        zip ? `<a href="${zip.browser_download_url}">ZIP for the updater (${formatBytes(zip.size)})</a>` : "",
        sums ? `<a href="${sums.browser_download_url}">SHA256SUMS</a>` : "",
        `<a href="${r.html_url}">On GitHub</a>`,
      ].filter(Boolean).join("");
      return `<section class="release" id="${r.tag_name}">
        <h3>${r.name || r.tag_name} ${badge}</h3>
        <div class="meta">${formatDate(r.published_at)} · <code>${r.tag_name}</code></div>
        <div class="notes">${renderNotes(r.body)}</div>
        <div class="assets">${assets}</div>
      </section>`;
    }).join("");
  } catch (error) {
    container.innerHTML = `<p class="note">Could not load the list right now (${error.message}). See <a href="https://github.com/${REPO}/releases">GitHub Releases</a>.</p>`;
  }
}

wireDownloadButton();
renderReleases();
