import type { Actions, Detectors, Item } from "@yabbistir/api";

const alphabet = /^[A-Za-z0-9+/_-]+={0,2}$/;

/** The decoded text, or null unless the input is Base64 of mostly printable UTF-8. */
export function decodeBase64(input: string): string | null {
  const text = input.trim();
  if (text.length < 8 || !alphabet.test(text)) return null;
  if (text.includes("=") ? text.length % 4 !== 0 : text.length % 4 === 1) return null;
  let standard = text.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  while (standard.length % 4 !== 0) standard += "=";
  let binary: string;
  try {
    binary = atob(standard);
  } catch {
    return null;
  }
  let decoded: string;
  try {
    decoded = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
  } catch {
    return null;
  }
  const visible = Array.from(decoded).filter((char) => !/\s/.test(char));
  if (visible.length === 0) return null;
  const printable = visible.filter((char) => {
    const code = char.codePointAt(0)!;
    return code >= 0x20 && code !== 0x7f && !(code >= 0x80 && code < 0xa0) && code !== 0xfffd;
  });
  return printable.length / visible.length >= 0.9 ? decoded : null;
}

function encodeBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (let start = 0; start < bytes.length; start += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(start, start + 0x8000));
  }
  return btoa(binary);
}

const textOf = (item: Item | null) => item?.text ?? item?.url ?? "";

export const actions: Actions = {
  decode: {
    run(item) {
      const decoded = decodeBase64(textOf(item));
      return decoded === null ? { none: true, message: yab.t("notBase64") } : { text: decoded };
    },
  },
  encode: { run: (item) => ({ text: encodeBase64(textOf(item)) }) },
};

export const detectors: Detectors = {
  base64: {
    validate: (item) => decodeBase64(textOf(item)) !== null,
    preview(item) {
      const decoded = decodeBase64(textOf(item));
      return decoded === null ? [] : [{ type: "code", title: yab.t("preview"), code: decoded }];
    },
  },
};
