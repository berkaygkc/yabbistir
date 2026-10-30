import type { Actions } from "@yabbistir/api";

/** The longest name a first line gives, in characters as people count them. */
const nameLength = 40;
/** And in bytes, so a letter heavy with combining marks still fits the disk's 255 with room for the type. */
const nameBytes = 200;

const encoder = new TextEncoder();

/**
 * A name Finder shows as it is, from the first line: no control or invisible format characters
 * (tabs, U+202E, U+200B), slashes and colons as dashes, no Markdown heading marker and no leading
 * dot (which would hide the file); then at most 40 characters and 200 bytes, cut between
 * characters. Null when nothing is left.
 */
export function nameFrom(text: string): string | null {
  const line = text.replace(/^\s+/, "").split(/\r\n|\r|\n/, 1)[0] ?? "";
  const cleaned = line
    .replace(/[\p{Cc}\p{Cf}]/gu, "")
    .replace(/[/:]/g, "-")
    .trim()
    .replace(/^#{1,6}(?:\s+|$)/, "")
    .replace(/^[.\s]+/, "");
  let name = "";
  let count = 0;
  let bytes = 0;
  for (const { segment } of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(cleaned)) {
    const size = encoder.encode(segment).length;
    if (count === nameLength || bytes + size > nameBytes) break;
    name += segment;
    count += 1;
    bytes += size;
  }
  name = name.trim();
  return name === "" ? null : name;
}

/** Markdown by its most telling marks: a heading first, a code fence, or a list. */
export function looksLikeMarkdown(text: string): boolean {
  const body = text.replace(/^\s+/, "");
  return body.startsWith("# ") || body.includes("```") || body.includes("\n- ");
}

const escaped = (text: string) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** A Finder link file: the URL in an XML property list. */
export function webloc(url: string): string {
  return [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">`,
    `<plist version="1.0">`,
    `<dict>`,
    `\t<key>URL</key>`,
    `\t<string>${escaped(url)}</string>`,
    `</dict>`,
    `</plist>`,
    ``,
  ].join("\n");
}

function hostOf(url: string): string | null {
  try {
    return new URL(url).hostname || null;
  } catch {
    return null;
  }
}

export const actions: Actions = {
  file: {
    run(item) {
      switch (item?.kind) {
        case "text":
        case "code": {
          const text = item.text ?? "";
          // Code stays plain text, even when it has Markdown's marks.
          const type = item.kind === "text" && looksLikeMarkdown(text) ? "md" : "txt";
          return { file: yab.files.write(`${nameFrom(text) ?? yab.t("text")}.${type}`, text) };
        }
        case "link": {
          const url = item.url ?? item.text ?? "";
          return { file: yab.files.write(`${hostOf(url) ?? yab.t("link")}.webloc`, webloc(url)) };
        }
        default: {
          // An image, or a picture copied as a file (which keeps its name).
          if (!item?.image) return { none: true };
          const base = item.files?.[0]?.name.replace(/\.[^.]*$/, "") ?? "";
          return { file: yab.files.write(`${nameFrom(base) ?? yab.t("image")}.png`, item.image) };
        }
      }
    },
  },
};
