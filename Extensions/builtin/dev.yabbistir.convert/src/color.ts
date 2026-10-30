/** A color from a clipboard item: 0–255 channels, alpha 0–1. */
export interface RGBA {
  r: number;
  g: number;
  b: number;
  a: number;
}

/** Up to three decimals, without trailing zeros: 0.431, 1, 0.5. */
const short = (value: number) => String(Number(value.toFixed(3)));

export function rgb({ r, g, b, a }: RGBA): string {
  return a < 1 ? `rgba(${r}, ${g}, ${b}, ${short(a)})` : `rgb(${r}, ${g}, ${b})`;
}

export function hsl({ r, g, b, a }: RGBA): string {
  const [red, green, blue] = [r / 255, g / 255, b / 255];
  const max = Math.max(red, green, blue), min = Math.min(red, green, blue);
  const lightness = (max + min) / 2;
  const delta = max - min;
  let hue = 0, saturation = 0;
  if (delta > 0) {
    saturation = delta / (1 - Math.abs(2 * lightness - 1));
    if (max === red) hue = 60 * (((green - blue) / delta) % 6);
    else if (max === green) hue = 60 * ((blue - red) / delta + 2);
    else hue = 60 * ((red - green) / delta + 4);
  }
  if (hue < 0) hue += 360;
  const body = `${Math.round(hue) % 360}, ${Math.round(saturation * 100)}%, ${Math.round(lightness * 100)}%`;
  return a < 1 ? `hsla(${body}, ${short(a)})` : `hsl(${body})`;
}

/** CSS Color 4 OKLCH from sRGB (Björn Ottosson's OKLab). */
export function oklch({ r, g, b, a }: RGBA): string {
  const linear = (channel: number) => {
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
  let hue = (Math.atan2(B, A) * 180) / Math.PI;
  if (hue < 0) hue += 360;
  const body = `${(L * 100).toFixed(1)}% ${chroma.toFixed(3)} ${chroma < 0.0005 ? "0" : hue.toFixed(1)}`;
  return a < 1 ? `oklch(${body} / ${short(a)})` : `oklch(${body})`;
}

export function swiftUI({ r, g, b, a }: RGBA): string {
  const body = `red: ${short(r / 255)}, green: ${short(g / 255)}, blue: ${short(b / 255)}`;
  return a < 1 ? `Color(${body}, opacity: ${short(a)})` : `Color(${body})`;
}

export function nsColor({ r, g, b, a }: RGBA): string {
  return `NSColor(srgbRed: ${short(r / 255)}, green: ${short(g / 255)}, blue: ${short(b / 255)}, alpha: ${short(a)})`;
}
