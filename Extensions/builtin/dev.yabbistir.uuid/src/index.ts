import type { Actions, Context } from "@yabbistir/api";

const hex = (bytes: Uint8Array) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
const dashed = (h: string) => `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
const finish = (value: string, ctx: Context) => ({ text: ctx.preferences.uppercase === true ? value.toUpperCase() : value });

function v4(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return dashed(hex(bytes));
}

// RFC 9562 v7: a 48-bit millisecond timestamp, then a 12-bit counter that keeps ids made in the
// same millisecond in order, then random bits.
let lastMilliseconds = -1;
let counter = 0;

function v7(): string {
  let milliseconds = Date.now();
  if (milliseconds <= lastMilliseconds) {
    milliseconds = lastMilliseconds;
    counter += 1;
    if (counter > 0xfff) {
      milliseconds += 1;
      counter = 0;
    }
  } else {
    counter = crypto.getRandomValues(new Uint16Array(1))[0] & 0x7ff;
  }
  lastMilliseconds = milliseconds;
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  for (let index = 0; index < 6; index++) bytes[index] = Math.floor(milliseconds / 2 ** (8 * (5 - index))) & 0xff;
  bytes[6] = 0x70 | (counter >> 8);
  bytes[7] = counter & 0xff;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return dashed(hex(bytes));
}

export const actions: Actions = {
  v4: { run: (_item, ctx) => finish(v4(), ctx) },
  v7: { run: (_item, ctx) => finish(v7(), ctx) },
};
