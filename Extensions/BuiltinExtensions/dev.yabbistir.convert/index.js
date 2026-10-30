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

// builtin/dev.yabbistir.convert/src/index.ts
var index_exports = {};
__export(index_exports, {
  actions: () => actions
});
module.exports = __toCommonJS(index_exports);

// builtin/dev.yabbistir.convert/src/color.ts
var short = (value) => String(Number(value.toFixed(3)));
function rgb({ r, g, b, a }) {
  return a < 1 ? `rgba(${r}, ${g}, ${b}, ${short(a)})` : `rgb(${r}, ${g}, ${b})`;
}
function hsl({ r, g, b, a }) {
  const [red, green, blue] = [r / 255, g / 255, b / 255];
  const max = Math.max(red, green, blue), min = Math.min(red, green, blue);
  const lightness = (max + min) / 2;
  const delta = max - min;
  let hue = 0, saturation = 0;
  if (delta > 0) {
    saturation = delta / (1 - Math.abs(2 * lightness - 1));
    if (max === red) hue = 60 * ((green - blue) / delta % 6);
    else if (max === green) hue = 60 * ((blue - red) / delta + 2);
    else hue = 60 * ((red - green) / delta + 4);
  }
  if (hue < 0) hue += 360;
  const body = `${Math.round(hue) % 360}, ${Math.round(saturation * 100)}%, ${Math.round(lightness * 100)}%`;
  return a < 1 ? `hsla(${body}, ${short(a)})` : `hsl(${body})`;
}
function oklch({ r, g, b, a }) {
  const linear = (channel) => {
    const c = channel / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  const [lr, lg, lb] = [linear(r), linear(g), linear(b)];
  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
  const L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
  const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
  const B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
  const chroma = Math.sqrt(A * A + B * B);
  let hue = Math.atan2(B, A) * 180 / Math.PI;
  if (hue < 0) hue += 360;
  const body = `${(L * 100).toFixed(1)}% ${chroma.toFixed(3)} ${chroma < 5e-4 ? "0" : hue.toFixed(1)}`;
  return a < 1 ? `oklch(${body} / ${short(a)})` : `oklch(${body})`;
}
function swiftUI({ r, g, b, a }) {
  const body = `red: ${short(r / 255)}, green: ${short(g / 255)}, blue: ${short(b / 255)}`;
  return a < 1 ? `Color(${body}, opacity: ${short(a)})` : `Color(${body})`;
}
function nsColor({ r, g, b, a }) {
  return `NSColor(srgbRed: ${short(r / 255)}, green: ${short(g / 255)}, blue: ${short(b / 255)}, alpha: ${short(a)})`;
}

// builtin/dev.yabbistir.convert/src/index.ts
var formats = { rgb, hsl, oklch, swiftui: swiftUI, nscolor: nsColor };
function imageOf(image) {
  if (!image) throw new Error("this action needs an image");
  return image;
}
var actions = {
  color: {
    run(item, ctx) {
      const color = item?.color;
      if (!color) return { none: true };
      const format = formats[ctx.variant ?? "rgb"] ?? rgb;
      return { text: format(color) };
    }
  },
  image: {
    async run(item, ctx) {
      const image = imageOf(item?.image);
      switch (ctx.variant) {
        case "png":
          return { image: await yab.image.convert(image, { format: "png" }) };
        case "half":
          return { image: await yab.image.resize(image, { scale: 0.5 }) };
        default:
          return { image: await yab.image.convert(image, { format: "jpeg", quality: 0.85 }) };
      }
    }
  },
  bgremove: {
    async run(item) {
      return { image: await yab.vision.removeBackground(imageOf(item?.image)) };
    }
  },
  ocr: {
    async run(item) {
      return { text: await yab.vision.ocr(imageOf(item?.image)) };
    }
  }
};
