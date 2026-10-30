import type { Actions, ImageHandle } from "@yabbistir/api";
import { hsl, nsColor, oklch, rgb, swiftUI } from "./color";

const formats = { rgb, hsl, oklch, swiftui: swiftUI, nscolor: nsColor } as const;

function imageOf(image: ImageHandle | undefined): ImageHandle {
  if (!image) throw new Error("this action needs an image");
  return image;
}

export const actions: Actions = {
  color: {
    run(item, ctx) {
      const color = item?.color;
      if (!color) return { none: true };
      const format = formats[(ctx.variant ?? "rgb") as keyof typeof formats] ?? rgb;
      return { text: format(color) };
    },
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
    },
  },
  bgremove: {
    async run(item) {
      return { image: await yab.vision.removeBackground(imageOf(item?.image)) };
    },
  },
  ocr: {
    async run(item) {
      return { text: await yab.vision.ocr(imageOf(item?.image)) };
    },
  },
};
