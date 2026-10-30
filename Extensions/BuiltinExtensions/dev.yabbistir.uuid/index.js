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

// builtin/dev.yabbistir.uuid/src/index.ts
var index_exports = {};
__export(index_exports, {
  actions: () => actions
});
module.exports = __toCommonJS(index_exports);
var hex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
var dashed = (h) => `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
var finish = (value, ctx) => ({ text: ctx.preferences.uppercase === true ? value.toUpperCase() : value });
function v4() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = bytes[6] & 15 | 64;
  bytes[8] = bytes[8] & 63 | 128;
  return dashed(hex(bytes));
}
var lastMilliseconds = -1;
var counter = 0;
function v7() {
  let milliseconds = Date.now();
  if (milliseconds <= lastMilliseconds) {
    milliseconds = lastMilliseconds;
    counter += 1;
    if (counter > 4095) {
      milliseconds += 1;
      counter = 0;
    }
  } else {
    counter = crypto.getRandomValues(new Uint16Array(1))[0] & 2047;
  }
  lastMilliseconds = milliseconds;
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  for (let index = 0; index < 6; index++) bytes[index] = Math.floor(milliseconds / 2 ** (8 * (5 - index))) & 255;
  bytes[6] = 112 | counter >> 8;
  bytes[7] = counter & 255;
  bytes[8] = bytes[8] & 63 | 128;
  return dashed(hex(bytes));
}
var actions = {
  v4: { run: (_item, ctx) => finish(v4(), ctx) },
  v7: { run: (_item, ctx) => finish(v7(), ctx) }
};
