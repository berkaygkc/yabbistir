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

// builtin/dev.yabbistir.base64/src/index.ts
var index_exports = {};
__export(index_exports, {
  actions: () => actions,
  decodeBase64: () => decodeBase64,
  detectors: () => detectors
});
module.exports = __toCommonJS(index_exports);
var alphabet = /^[A-Za-z0-9+/_-]+={0,2}$/;
function decodeBase64(input) {
  const text = input.trim();
  if (text.length < 8 || !alphabet.test(text)) return null;
  if (text.includes("=") ? text.length % 4 !== 0 : text.length % 4 === 1) return null;
  let standard = text.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  while (standard.length % 4 !== 0) standard += "=";
  let binary;
  try {
    binary = atob(standard);
  } catch {
    return null;
  }
  let decoded;
  try {
    decoded = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
  } catch {
    return null;
  }
  const visible = Array.from(decoded).filter((char) => !/\s/.test(char));
  if (visible.length === 0) return null;
  const printable = visible.filter((char) => {
    const code = char.codePointAt(0);
    return code >= 32 && code !== 127 && !(code >= 128 && code < 160) && code !== 65533;
  });
  return printable.length / visible.length >= 0.9 ? decoded : null;
}
function encodeBase64(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (let start = 0; start < bytes.length; start += 32768) {
    binary += String.fromCharCode(...bytes.subarray(start, start + 32768));
  }
  return btoa(binary);
}
var textOf = (item) => item?.text ?? item?.url ?? "";
var actions = {
  decode: {
    run(item) {
      const decoded = decodeBase64(textOf(item));
      return decoded === null ? { none: true, message: yab.t("notBase64") } : { text: decoded };
    }
  },
  encode: { run: (item) => ({ text: encodeBase64(textOf(item)) }) }
};
var detectors = {
  base64: {
    validate: (item) => decodeBase64(textOf(item)) !== null,
    preview(item) {
      const decoded = decodeBase64(textOf(item));
      return decoded === null ? [] : [{ type: "code", title: yab.t("preview"), code: decoded }];
    }
  }
};
