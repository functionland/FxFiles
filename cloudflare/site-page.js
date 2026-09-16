/**
 * What the link resolver needs to know about a PUBLISHED page — kept apart
 * from the Worker entry so it is plain functions with no runtime bindings,
 * testable under `node --test`.
 *
 * A published page is immutable. When the gateway a page was built for stops
 * working for it, no setting and no republish can change the bytes, so the
 * redirect is the only place left to make that page render. These functions
 * decide where that is, and what a link-preview crawler should be shown.
 */

/** Path-style gateway base: reachable by crawlers and servers alike. */
export const PATH_GATEWAY_BASE = 'https://ipfs.filebase.io/ipfs/';

/** CR, LF and friends — anything that could split a header or attribute. */
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\x00-\x1f\x7f]/;

/**
 * Which publish pipeline produced a page:
 *   0  before relative assets — every asset is an absolute gateway URL
 *      (dweb.link) and there is no fallback script
 *   1  relative `../<cid>` assets plus an image fallback (`data-fx-try`)
 *   2+ declared on the fallback script tag itself (`data-fx-v="2"`): relative
 *      references are also rewritten on subdomain gateways
 */
export function pipelineVersion(html) {
  const declared = html.match(/\bdata-fx-v="(\d+)"/);
  if (declared) return Number(declared[1]);
  return html.includes('data-fx-try') ? 1 : 0;
}

/**
 * Whether a version-1 page references anything relatively that is not a plain
 * `<img src>` — a video, a download link, a CSS background, a subpage. On a
 * subdomain gateway those 404 (the host is the page's own CID), and that
 * pipeline's fallback only rescues `<img>`. Our own injected script copies do
 * not count: they are redundant wherever inline scripts run.
 */
export function hasNonImageRelativeRefs(html) {
  const REL = /\.\.\/[A-Za-z0-9]{40,120}/;
  for (const [tag, name, attrs] of html.matchAll(/<([a-zA-Z][\w-]*)\b([^>]*)>/g)) {
    if (!REL.test(attrs)) continue;
    const lower = name.toLowerCase();
    if (lower === 'script' && /\sdata-fx(?=[\s=>])/.test(tag)) continue;
    if (lower === 'img') {
      const others = attrs.replace(/\ssrc\s*=\s*(["'])[^"']*\1/i, '');
      if (!REL.test(others)) continue;
    }
    return true;
  }
  return /url\(\s*["']?\.\.\/[A-Za-z0-9]{40,120}/.test(html);
}

/**
 * The gateway key that can actually render this page, given the visitor's.
 *
 *  - version 0: only inbrowser still serves its absolute dweb.link assets —
 *    its service worker intercepts them (measured 2026-09-16: images, video
 *    and documents all load), while dweb.link itself answers 429 and is
 *    switched off on 2026-09-21. inbrowser also runs the inline scripts and
 *    Google Forms embeds that Filebase's `default-src 'self'` CSP blocks.
 *  - version 1: relative references resolve on a path gateway, while on
 *    inbrowser only images are rescued — so inbrowser only when images are
 *    all the page references.
 *  - newer: exactly what was asked for.
 *  - unreadable (null): what was asked for — except Filebase, which has just
 *    failed to serve this very page in time, and which cannot render the
 *    pre-relative-assets sites that are most of what exists. inbrowser can.
 */
export function chooseGateway(html, requestedKey) {
  if (html === null) return requestedKey === 'filebase' ? 'inbrowser' : requestedKey;
  const version = pipelineVersion(html);
  if (version === 0) return 'inbrowser';
  if (version === 1) return hasNonImageRelativeRefs(html) ? 'filebase' : 'inbrowser';
  return requestedKey;
}

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

function decodeEntities(text) {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, body) => {
    if (body[0] !== '#') return ENTITIES[body.toLowerCase()] ?? match;
    const code = body[1] === 'x' || body[1] === 'X'
      ? parseInt(body.slice(2), 16)
      : parseInt(body.slice(1), 10);
    return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff)
      ? String.fromCodePoint(code)
      : match;
  });
}

/** Escape for BOTH element text and a double- or single-quoted attribute. */
export function escapeHtml(text) {
  return text.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

/** Visible text of an HTML fragment: tags dropped, entities decoded, control
 *  characters and runs of whitespace collapsed, capped at [max] characters. */
function plainText(fragment, max) {
  const text = decodeEntities(fragment.replace(/<[^>]*>/g, ' '))
    // eslint-disable-next-line no-control-regex
    .replace(/[\x00-\x1f\x7f\s]+/g, ' ')
    .trim();
  const chars = Array.from(text);
  return chars.length > max ? `${chars.slice(0, max - 1).join('').trimEnd()}…` : text;
}

function attribute(tag, name) {
  const m = tag.match(
    new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'>]+))`, 'i'),
  );
  return m ? decodeEntities(m[1] ?? m[2] ?? m[3]) : null;
}

/**
 * An absolute, crawler-fetchable image URL for a reference found in a page.
 * Anything naming a CID — a gateway URL of any shape, or a relative `../<cid>`
 * — is re-pointed at the path gateway, since the host it named may be dead
 * (dweb.link) or browser-only (inbrowser). Other https URLs pass through;
 * everything else (data:, http:, javascript:, garbage) is dropped.
 */
export function previewImageUrl(raw) {
  if (!raw) return null;
  const value = raw.trim();
  const cid =
    value.match(/^https?:\/\/([A-Za-z0-9]{40,120})\.ipfs\.[^/]+/i)?.[1] ??
    value.match(/\/(?:ipfs|gateway)\/([A-Za-z0-9]{40,120})(?:[/?#]|$)/)?.[1] ??
    value.match(/^(?:\.\.?\/)*([A-Za-z0-9]{40,120})\/?$/)?.[1];
  if (cid) return `${PATH_GATEWAY_BASE}${cid}`;
  if (!/^https:\/\//i.test(value) || CONTROL_CHARS.test(value)) return null;
  try {
    return new URL(value).href;
  } catch (_) {
    return null;
  }
}

/** Title, description and image a link preview should show for a page. */
export function extractPreview(html) {
  const metas = new Map();
  for (const [tag] of html.matchAll(/<meta\b[^>]*>/gi)) {
    const key = (attribute(tag, 'property') ?? attribute(tag, 'name'))?.toLowerCase();
    const content = attribute(tag, 'content');
    if (key && content && !metas.has(key)) metas.set(key, content);
  }
  const titleTag = html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i)?.[1];
  const h1 = html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i)?.[1];
  // Scripts and styles are not prose; drop them before looking for a paragraph.
  const body = html.replace(/<(script|style)\b[\s\S]*?<\/\1\s*>/gi, ' ');
  const paragraph = [...body.matchAll(/<p\b[^>]*>([\s\S]*?)<\/p>/gi)]
    .map((m) => plainText(m[1], 300))
    .find((text) => text.length >= 40);

  const title = plainText(metas.get('og:title') ?? titleTag ?? h1 ?? '', 200);
  const description = plainText(
    metas.get('og:description') ?? metas.get('description') ?? paragraph ?? '',
    300,
  );

  // Every usable image reference, best first and without repeats: declared
  // preview images, then the page's own <img>s. The caller may still reject a
  // candidate — a page can point an <img> at something that is not an image.
  const images = [];
  const add = (url) => { if (url && !images.includes(url)) images.push(url); };
  add(previewImageUrl(metas.get('og:image')));
  add(previewImageUrl(metas.get('twitter:image')));
  for (const [tag] of body.matchAll(/<img\b[^>]*>/gi)) {
    add(previewImageUrl(attribute(tag, 'src')));
    if (images.length >= 6) break;
  }
  return { title, description, image: images[0] ?? null, images };
}

/**
 * The page a link-preview crawler gets: Open Graph tags describing the site
 * and a plain link to it. Everything taken from the site is decoded, capped
 * and escaped; the Worker also serves it under `default-src 'none'`, so a
 * hostile page cannot turn this into markup or script of its own.
 */
export function buildPreviewHtml(html, link, target, chosenImage) {
  const extracted = extractPreview(html);
  const { title, description } = extracted;
  // `chosenImage` (null = none) lets the caller substitute a verified image.
  const image = chosenImage === undefined ? extracted.image : chosenImage;
  const shownTitle = title || 'Website';
  const lines = [
    '<!doctype html>',
    '<html><head><meta charset="utf-8">',
    `<title>${escapeHtml(shownTitle)}</title>`,
    '<meta property="og:type" content="website">',
    `<meta property="og:url" content="${escapeHtml(link)}">`,
    `<meta property="og:title" content="${escapeHtml(shownTitle)}">`,
  ];
  if (description) {
    lines.push(
      `<meta property="og:description" content="${escapeHtml(description)}">`,
      `<meta name="description" content="${escapeHtml(description)}">`,
    );
  }
  if (image) {
    lines.push(
      `<meta property="og:image" content="${escapeHtml(image)}">`,
      `<meta name="twitter:image" content="${escapeHtml(image)}">`,
      '<meta name="twitter:card" content="summary_large_image">',
    );
  } else {
    lines.push('<meta name="twitter:card" content="summary">');
  }
  lines.push(
    `<link rel="canonical" href="${escapeHtml(link)}">`,
    '</head><body>',
    `<p><a href="${escapeHtml(target)}">${escapeHtml(shownTitle)}</a></p>`,
    '</body></html>',
  );
  return lines.join('\n');
}
