"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// builtin/dev.yabbistir.finderfile/src/index.ts
var index_exports = {};
__export(index_exports, {
  actions: () => actions,
  looksLikeMarkdown: () => looksLikeMarkdown,
  nameFrom: () => nameFrom,
  webloc: () => webloc
});
module.exports = __toCommonJS(index_exports);
var nameLength = 40;
var nameBytes = 200;
var encoder = new TextEncoder();
function nameFrom(text) {
  const line = text.replace(/^\s+/, "").split(/\r\n|\r|\n/, 1)[0] ?? "";
  const cleaned = line.replace(/[\p{Cc}\p{Cf}]/gu, "").replace(/[/:]/g, "-").trim().replace(/^#{1,6}(?:\s+|$)/, "").replace(/^[.\s]+/, "");
  let name = "";
  let count = 0;
  let bytes = 0;
  for (const { segment } of new Intl.Segmenter(void 0, { granularity: "grapheme" }).segment(cleaned)) {
    const size = encoder.encode(segment).length;
    if (count === nameLength || bytes + size > nameBytes) break;
    name += segment;
    count += 1;
    bytes += size;
  }
  name = name.trim();
  return name === "" ? null : name;
}
function looksLikeMarkdown(text) {
  const body = text.replace(/^\s+/, "");
  return body.startsWith("# ") || body.includes("```") || body.includes("\n- ");
}
var escaped = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
function webloc(url) {
  return [
    `<?xml version="1.0" encoding="UTF-8"?>`,
    `<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">`,
    `<plist version="1.0">`,
    `<dict>`,
    `	<key>URL</key>`,
    `	<string>${escaped(url)}</string>`,
    `</dict>`,
    `</plist>`,
    ``
  ].join("\n");
}
function hostOf(url) {
  try {
    return new URL(url).hostname || null;
  } catch {
    return null;
  }
}
var actions = {
  file: {
    run(item) {
      switch (item?.kind) {
        case "text":
        case "code": {
          const text = item.text ?? "";
          const type = item.kind === "text" && looksLikeMarkdown(text) ? "md" : "txt";
          return { file: yab.files.write(`${nameFrom(text) ?? yab.t("text")}.${type}`, text) };
        }
        case "link": {
          const url = item.url ?? item.text ?? "";
          return { file: yab.files.write(`${hostOf(url) ?? yab.t("link")}.webloc`, webloc(url)) };
        }
        default: {
          if (!item?.image) return { none: true };
          const base = item.files?.[0]?.name.replace(/\.[^.]*$/, "") ?? "";
          return { file: yab.files.write(`${nameFrom(base) ?? yab.t("image")}.png`, item.image) };
        }
      }
    }
  }
};
