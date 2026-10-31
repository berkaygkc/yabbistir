/**
 * @yabbistir/api — the extension API, version 1.
 *
 * An extension's index.ts exports `actions`, `detectors`, `captureRules` and/or `sources`. yabbistir draws every piece of UI;
 * an extension only computes. The functions below run in JavaScriptCore (ES2022), not Node: there
 * is no `require`, `process`, `fs` or `Buffer`. The web standards declared at the bottom are there.
 */

/** Why a call failed. A `yab` function that throws, or a `yab` promise that rejects, gives an Error with one in `code`. */
export type ExtensionErrorCode =
  | "script"
  | "syntax"
  | "timeout"
  | "notFound"
  | "badResult"
  | "unavailable"
  | "unsupported"
  | "interrupted"
  | "permissionDenied"
  | "toolMissing"
  | "cancelled"
  | "networkError";

/**
 * What `yab` throws and rejects with: test `e.code`, e.g. `e.code === "cancelled"` once the person
 * cancelled the job. An error you throw yourself with a `code` from this list keeps it.
 */
export interface YabError extends Error {
  readonly code: ExtensionErrorCode;
}

/** A handle to an image held by yabbistir; pass it to `yab.image`, `yab.vision` or return it. */
export interface ImageHandle {
  readonly __image: string;
  readonly width: number;
  readonly height: number;
}

/** A clipboard item. Concealed copies (passwords) never reach an extension. */
export interface Item {
  id: number;
  kind: "text" | "code" | "link" | "color" | "image" | "file";
  /** Text and code items. */
  text?: string;
  /** Link items. */
  url?: string;
  /** Color items: 0–255 channels, alpha 0–1. */
  color?: { hex: string; r: number; g: number; b: number; a: number };
  /** File items. */
  files?: { path: string; name: string; size: number; uti: string }[];
  /** Items copied as rich text. */
  richText?: { html?: string };
  /** Image items. */
  image?: ImageHandle;
  /** Tags detectors put on the item, as "extension.id:tag". */
  tags: string[];
  /** Where it was copied. */
  source?: { name?: string | null; bundleID?: string | null; device: string };
  /** ISO 8601. */
  copiedAt: string;
}

/** What a call knows besides the item. */
export interface Context {
  /** The app's language, e.g. "en" or "tr". */
  language: string;
  /** This extension's preferences (manifest defaults until the user changes them). */
  preferences: Record<string, unknown>;
  /** Where the call came from. */
  trigger: "search" | "shiftPanel" | "commandK" | "detect" | "preview" | "capture" | "source";
  /** The variant the user chose, for actions with `variants`. */
  variant: string | null;
  /** The app the result is headed for, when known. */
  target: { bundleID: string; name: string; kind: "finder" | "terminal" | "browser" | "editor" | "other" } | null;
  /**
   * Aborts when the person cancels the call (a job's ✕). Its `reason` is a YabError with code
   * "cancelled", and pending `yab` promises reject with that code too. Stop work and let the error
   * through; whatever the call returns afterwards is dropped.
   */
  signal: AbortSignal;
}

/** An item as `yab.history` returns it: images have their size only. */
export type HistoryItem = Omit<Item, "image"> & {
  image?: { width: number; height: number };
  /** True when the text or HTML was cut to 64 KB; absent otherwise. */
  readonly truncated?: boolean;
};

/** `yab.ai.generate`'s options. Left out, each is the model's own default. */
export interface AIOptions {
  /** The model's role and rules for this answer ("Answer in one sentence."). Cut to 32 000 characters. */
  instructions?: string;
  /** 0 is the most predictable, 2 the most varied; values outside are held to 0–2. */
  temperature?: number;
  /** The longest answer, in tokens; values outside are held to 1–2048. */
  maxTokens?: number;
}

/** What `yab.translate` resolves with. */
export interface TranslationResult {
  text: string;
  /** The source language (BCP-47): the one given, or the one recognized. */
  from: string;
}

/** What an action returns. yabbistir writes it to the clipboard, pastes it and adds it to history. */
export type Result =
  | { text: string }
  | { html: string; text: string }
  | { image: ImageHandle }
  | { link: { url: string; title?: string } }
  | { file: string }
  | { files: string[] }
  | { none: true; message?: string };

/** A block a detector adds to an item's preview. */
export type PreviewSection =
  | { type: "text"; title: string; text: string }
  | { type: "code"; title: string; code: string; language?: string }
  | { type: "keyValue"; title: string; rows: [string, string][] }
  | { type: "image"; title: string; image: ImageHandle }
  | { type: "link"; title: string; url: string };

export interface Action {
  /** `item` is null for actions whose manifest says `"input": "none"`. */
  run(item: Item | null, ctx: Context): Result | Promise<Result>;
}

export type Actions = Record<string, Action>;

export interface Detector {
  /** Keep the tag? Runs in at most 50 ms; no promises. */
  validate?(item: Item): boolean;
  /** Blocks for the preview of an item carrying this detector's tag. */
  preview?(item: Item, ctx: Context): PreviewSection[] | Promise<PreviewSection[]>;
}

export type Detectors = Record<string, Detector>;

/**
 * What a capture rule decides about a new copy.
 * - `keep`: store it as it is. Returning nothing (`undefined` or `null`) does the same.
 * - `ignore`: do not store it; the rules after this one do not run.
 * - `replace`: store this plain text or link instead (a non-empty string). Only for text, code and link
 *   copies; on any other copy it is ignored. The next rule sees the replaced copy.
 * - `addToCategory`: also put it in this category, which must exist (case and accents are ignored); an
 *   unknown name is ignored.
 * Anything else is an error, and the rule is skipped for this copy.
 */
export type CaptureResult =
  | { keep: true }
  | { ignore: true }
  | { replace: { text: string } }
  | { replace: { url: string } }
  | { addToCategory: string };

/**
 * Runs on each new copy before it reaches history, in at most 200 ms (or it is skipped); needs the
 * "capture" permission. Rules run one at a time, each seeing what the ones before it made of the copy.
 * Rules run in the order extensions are listed in Settings, then in manifest order. A copy whose text or
 * link is over 256 KB meets no rule and is stored as it is. No network, programs, history, AI,
 * translation, notifications or opening links; `ctx.trigger` is "capture".
 *
 * Capture rules see text and URLs only: no tags, no pixels.
 */
export interface CaptureRule {
  run(item: Item, ctx: Context): CaptureResult | undefined | Promise<CaptureResult | undefined>;
}

export type CaptureRules = Record<string, CaptureRule>;

/**
 * One row of a source, drawn by the app in its own category column. A listing keeps at most 10,000 rows: the
 * rest are dropped, with one line in the Development log. Rows live in the app's memory only: never in history,
 * the search index or on disk. A row that breaks a rule below fails the whole listing with "badResult".
 */
export interface SourceRow {
  /**
   * A non-empty string of at most 256 characters. `run` gets it back exactly as listed: it is never cleaned
   * or cut, so a longer one fails the listing. Give each row its own, the same each time it is listed.
   */
  readonly id: string;
  /**
   * The row's first line. Tabs and line ends become spaces, the ends are trimmed and it is cut to 256
   * characters; one that is empty after that fails the listing.
   */
  readonly title: string;
  /**
   * The second line, in the secondary color (a user name). Cleaned and cut like `title`; left out, null or
   * blank, the row has none. Anything but a string fails the listing.
   */
  readonly subtitle?: string;
}

/**
 * What `list` returns: the rows, or `locked` when the source needs the person to unlock it first (the app then
 * drops the rows it held at once, and shows one calm row instead). `locked: true` wins over `rows` sent with
 * it. `message` is required; `message` and `command` are cleaned like a row's title and cut to 200
 * characters, and a blank `command` is none. `command` is a line the person runs to unlock the source
 * (⌘C copies it); a line end in it becomes a space, so pasting it never runs it. Any other shape is a
 * "badResult", whose reason in the Development log names shapes only.
 */
export type SourceListing =
  | { rows: SourceRow[] }
  | { locked: true; message: string; command?: string };

/**
 * What `run` returns: `{ secret }` for an action whose manifest `kind` is "secret" (of a `sensitive` source
 * only), `{ text }` for a "text" one; the other shape, or any other value, is a "badResult". The string is
 * kept exactly as given, so trim a tool's trailing newline yourself; an empty or whitespace-only one is a
 * "badResult" too, and nothing is pasted or copied. Never log rows or values, and never put one in an error
 * message: the app's own reasons name shapes only.
 */
export type SourceValue = { secret: string } | { text: string };

/**
 * A list the app shows as a column, with one or two row actions declared in the manifest under
 * `contributes.sources`. Both functions get no item, and run as the person's own action, like an action's
 * `run`: `yab.exec` works (with the `exec` permission), as do `yab.http` (a `sensitive` source has no
 * network), `yab.notify`, `yab.open`, `yab.ai` and `yab.translate`; `yab.history` rejects with
 * "permissionDenied". `ctx.trigger` is "source".
 */
export interface Source {
  /**
   * The source's rows, or that it is locked. Called when the panel opens; the app shows the rows it already
   * holds until the new ones come, then swaps them in quietly. `ctx.signal` aborts when the call is cancelled:
   * pass it to `yab.exec` (`{ signal: ctx.signal }`) so the tool stops with it.
   */
  list(ctx: Context): SourceListing | Promise<SourceListing>;
  /**
   * A row's value for one action: `rowId` is a row's `id` exactly as listed, `actionId` the `id` of one of the
   * source's actions in the manifest. `ctx` is as for `list`, with its own `signal`.
   */
  run(rowId: string, actionId: string, ctx: Context): SourceValue | Promise<SourceValue>;
}

/** `exports.sources`, by each source's `id` in the manifest's `contributes.sources`. */
export type Sources = Record<string, Source>;

export interface HttpInit {
  method?: string;
  headers?: Record<string, string>;
  body?: string | Uint8Array;
  toFile?: boolean | string;
  /** Aborting it cancels the request; the promise rejects with code "cancelled". */
  signal?: AbortSignal;
}

export interface HttpResponse {
  status: number;
  headers: Record<string, string>;
  text?: string;
  file?: string;
}

export interface ExecOptions {
  /** Hears each line the tool writes, without its newline (empty lines are skipped), in order for each stream; bad UTF-8 bytes become "\uFFFD". */
  onLine?: (line: string, stream: "stdout" | "stderr") => void;
  /** Aborting it stops the tool and everything it started; the promise rejects with code "cancelled". */
  signal?: AbortSignal;
  /** Written to the tool's standard input, which is then closed. Without it, standard input is empty. */
  input?: string;
}

export interface ExecResult {
  /** The tool's exit code; 128 + the signal's number when a signal ended it. A non-zero code does not reject: judge it yourself. */
  exitCode: number;
  /** The last 64 KB the tool wrote to standard output. */
  stdout: string;
  /** The last 64 KB the tool wrote to standard error. */
  stderr: string;
}

export interface Yab {
  /** The app's language. */
  readonly language: string;
  /** This extension's string for `key` (app language → default locale → the key); `{name}` is replaced from `args`. */
  t(key: string, args?: Record<string, string | number | boolean>): string;
  /**
   * This extension's preferences by id. A `folder` preference is an absolute path string (`~` already
   * expanded; a manifest default shows here too; "" when cleared). `yab.files.read` and `exists` may read inside
   * a folder only after the person chose it in Settings (a default alone grants nothing), never write.
   * A `secret` preference is never here: read it with `yab.secrets.get`.
   */
  readonly preferences: Record<string, unknown>;
  readonly secrets: {
    /**
     * The value of this extension's own `secret` preference `id`, or null when it has none or `id` is not a
     * declared secret. Needs no permission and works in every call. Never log it or put it in a result.
     */
    get(id: string): string | null;
  };
  /** A small store kept between calls (JSON values, 1 MB in all). */
  readonly storage: {
    get(key: string): unknown;
    /** Throws when the store would pass 1 MB. */
    set(key: string, value: unknown): void;
    remove(key: string): void;
  };
  readonly image: {
    info(image: ImageHandle): { width: number; height: number; uti: string };
    /** Rejects with code "unavailable" when the Mac cannot write the format (WebP on macOS 26). */
    convert(image: ImageHandle, options: { format: "jpeg" | "png" | "webp" | "heic"; quality?: number; maxSize?: number }): Promise<ImageHandle>;
    resize(image: ImageHandle, options: { scale?: number; width?: number; height?: number }): Promise<ImageHandle>;
    fromBytes(bytes: Uint8Array, uti?: string): ImageHandle;
  };
  readonly vision: {
    /** Recognized text, lines joined with "\n" (Turkish and English). */
    ocr(image: ImageHandle): Promise<string>;
    /**
     * The image's foreground subject(s) cut out onto a transparent background (PNG with alpha), same size.
     * Rejects with code `unavailable` ("no subject found") when Vision finds no subject.
     */
    removeBackground(image: ImageHandle): Promise<ImageHandle>;
    /** QR codes and barcodes found in the image. */
    readCodes(image: ImageHandle): Promise<string[]>;
  };
  readonly qr: {
    generate(text: string, options?: { size?: number }): ImageHandle;
  };
  readonly files: {
    /** This call's work folder; made on first use and removed when the call ends, unless it returns files. */
    readonly workDir: string;
    /**
     * Writes a file in the work folder and returns its path. `/` and `:` in the name become `-`;
     * `..`, an empty name and one over 200 characters throw with code "badResult". An image handle
     * is written as PNG.
     */
    write(name: string, data: string | Uint8Array | ImageHandle): string;
    /**
     * Reads a file from the work folder, one of the item's own `files`, or inside a folder the person chose in a
     * `folder` preference (links that lead out of it are refused); any other path throws "badResult".
     */
    read(path: string): Uint8Array;
    /** Whether a file exists in those places; false for any other path. */
    exists(path: string): boolean;
  };
  readonly http: {
    /**
     * Fetches a URL; needs the `network` permission and only reaches the manifest's `network.domains`
     * (a host equals a domain or ends with ".domain"; redirects are held to the same list). Rejects with
     * "permissionDenied" (host not allowed), "networkError" (failed, redirected outside the domains, or a text
     * body over 10 MB without `toFile`) or "cancelled". Works only in a run the person started or a source's
     * `list` and `run`.
     * Header names in the response are lowercased. With `toFile` the body streams into the work folder and
     * `file` is its path (`true` names it after the URL's last path part, or "download"); a non-2xx answer is
     * returned as `text` instead.
     */
    fetch(url: string, init?: HttpInit): Promise<HttpResponse>;
  };
  /**
   * Runs a tool from the manifest's `requires.tools`; needs the `exec` permission and works only in a run
   * the person started or a source's `list` and `run`. No shell is involved: each argument reaches the tool
   * as it is, so quoting, `;`, `$(…)` and `*` mean nothing special. The tool runs in `yab.files.workDir`
   * with only PATH (the folders tools are looked for in, then /usr/bin:/bin:/usr/sbin:/sbin), HOME, TMPDIR,
   * USER and LANG set. Resolves once it has exited and closed its output. Rejects with "permissionDenied" (no `exec`
   * permission, or the tool is not in `requires.tools`), "toolMissing" (not installed; the message says how
   * to install it), "badResult" (`args` is not an array of strings) or "cancelled". Cancelling the call or
   * aborting `signal` sends SIGTERM to the tool and everything it started, and SIGKILL two seconds later.
   */
  exec(tool: string, args: string[], options?: ExecOptions): Promise<ExecResult>;
  /**
   * Shows a calm notice titled with the extension's name. Works only in a run the person started (throws
   * "permissionDenied" in hints, detectors, previews and capture rules); needs no permission. The message is
   * cut to 200 characters, and an extension gets at most one notice every 3 seconds: more are dropped
   * without an error. Returns at once; the app shows it.
   */
  notify(message: string): void;
  /**
   * Opens a web link in the default browser. Only http and https links open; any other throws "badResult".
   * Works only in a run the person started (throws "permissionDenied" in hints, detectors, previews and
   * capture rules); needs no permission. Returns at once; the app opens it.
   */
  open(url: string): void;
  readonly history: {
    /**
     * The newest clipboard items, newest first. Needs the "history" permission and works only in a run the
     * person started or a job: rules, detectors and previews reject with "permissionDenied", as does an
     * extension without the permission (the message in the app's language). `limit` is 1 to 50 (20 when left
     * out; larger values are cut to 50). Items arrive trimmed: a text and an item's HTML are cut to 64 KB, and
     * an image carries only its width and height, never its pixels. Concealed copies are not in history.
     */
    recent(limit?: number): Promise<HistoryItem[]>;
    /** The same, for items matching `query` (the search the panel uses). Same permission, limit and trimming. */
    search(query: string, limit?: number): Promise<HistoryItem[]>;
  };
  readonly ai: {
    /**
     * Answers `prompt` with Apple's on-device model (Apple Intelligence); nothing leaves the Mac. Works only in
     * a run the person started or a job: hints, detectors, previews and capture rules reject with
     * "permissionDenied". Needs no permission. The prompt is cut to 32 000 characters, but the model reads far
     * less (a few thousand words): shorten long texts first.
     * Rejects with "unavailable" when the model cannot run, the message (in the app's language) saying what to
     * do: this Mac can't run Apple Intelligence, it is turned off in System Settings, or it is still getting
     * ready. It rejects with "unavailable" too, again in the app's language, when the text is too long for the
     * model, the model won't answer it, the language isn't supported yet, or the model is busy; a cancelled
     * call rejects with "cancelled". Transforming the person's own text (summarizing, rewriting) is not
     * refused for what the text contains.
     */
    generate(prompt: string, options?: AIOptions): Promise<string>;
  };
  /**
   * Translates `text` on the Mac with Apple Translation into `to`, a BCP-47 code ("tr", "en", "zh-Hans").
   * `from` is the text's language; left out, it is recognized. A text already in `to` comes back as it is,
   * with `from` set, so compare `from` with `to` to tell. The text is cut to 32 000 characters. Works only in a
   * run the person started or a job (hints, detectors, previews and capture rules reject with
   * "permissionDenied"); needs no permission. Rejects with "badResult" for a missing text or language code,
   * "cancelled" when the call is cancelled, and "unavailable", the message in the app's language, when:
   * the pair's language pack isn't downloaded (yabbistir also offers to download it), the pair can't be
   * translated on this Mac, the text's language can't be told, or the translation otherwise fails.
   */
  translate(text: string, options: { to: string; from?: string }): Promise<TranslationResult>;
  readonly job: {
    /**
     * Reports how far a job is, for its card. `fraction` 0–1 with numbers as the message
     * ("18.4 / 43.7 MB · 1 min left"), or null when it cannot be told, with a state word
     * ("Merging"). Throws with code "badResult" for anything else.
     */
    progress(fraction: number | null, message?: string): void;
  };
}

declare global {
  const yab: Yab;

  const console: { log(...values: unknown[]): void; info(...values: unknown[]): void; warn(...values: unknown[]): void; error(...values: unknown[]): void; debug(...values: unknown[]): void };
  function setTimeout(callback: (...args: unknown[]) => void, ms?: number, ...args: unknown[]): number;
  function clearTimeout(id: number): void;
  function atob(data: string): string;
  function btoa(data: string): string;

  class TextEncoder {
    readonly encoding: "utf-8";
    encode(input?: string): Uint8Array;
  }
  class TextDecoder {
    constructor(label?: string, options?: { fatal?: boolean });
    readonly encoding: "utf-8";
    decode(input?: ArrayBufferView | ArrayBuffer): string;
  }
  const crypto: {
    getRandomValues<T extends ArrayBufferView>(array: T): T;
    randomUUID(): string;
  };
  class Headers implements Iterable<[string, string]> {
    constructor(init?: Headers | Record<string, string> | [string, string][]);
    append(name: string, value: string): void;
    set(name: string, value: string): void;
    get(name: string): string | null;
    has(name: string): boolean;
    delete(name: string): void;
    forEach(callback: (value: string, name: string) => void): void;
    keys(): IterableIterator<string>;
    values(): IterableIterator<string>;
    entries(): IterableIterator<[string, string]>;
    [Symbol.iterator](): IterableIterator<[string, string]>;
  }
  class Response {
    constructor(body?: string | ArrayBuffer | ArrayBufferView | null, init?: { status?: number; statusText?: string; headers?: Headers | Record<string, string> });
    readonly ok: boolean;
    readonly status: number;
    readonly statusText: string;
    readonly headers: Headers;
    readonly url: string;
    readonly bodyUsed: boolean;
    text(): Promise<string>;
    json(): Promise<unknown>;
    arrayBuffer(): Promise<ArrayBuffer>;
  }
  /** Web-compatible and held to the same rules as `yab.http.fetch`; bodies up to 10 MB. */
  function fetch(input: string | URL, init?: { method?: string; headers?: Headers | Record<string, string> | [string, string][]; body?: string | URLSearchParams | ArrayBuffer | ArrayBufferView; signal?: AbortSignal }): Promise<Response>;
  class URLSearchParams implements Iterable<[string, string]> {
    constructor(init?: string | Record<string, string> | [string, string][] | URLSearchParams);
    append(name: string, value: string): void;
    delete(name: string): void;
    get(name: string): string | null;
    getAll(name: string): string[];
    has(name: string): boolean;
    set(name: string, value: string): void;
    sort(): void;
    forEach(callback: (value: string, key: string, parent: URLSearchParams) => void): void;
    keys(): IterableIterator<string>;
    values(): IterableIterator<string>;
    entries(): IterableIterator<[string, string]>;
    [Symbol.iterator](): IterableIterator<[string, string]>;
    readonly size: number;
    toString(): string;
  }
  interface AbortEvent {
    readonly type: "abort";
    readonly target: AbortSignal;
    readonly currentTarget: AbortSignal;
  }
  class AbortSignal {
    private constructor();
    readonly aborted: boolean;
    /** What `abort` was given: an Error named "AbortError" by default, "TimeoutError" from `timeout`. */
    readonly reason: unknown;
    onabort: ((this: AbortSignal, event: AbortEvent) => void) | null;
    /** Each listener runs once, when the signal aborts; one added afterwards never runs. */
    addEventListener(type: "abort", listener: (this: AbortSignal, event: AbortEvent) => void): void;
    removeEventListener(type: "abort", listener: (this: AbortSignal, event: AbortEvent) => void): void;
    /** Throws `reason` once aborted. */
    throwIfAborted(): void;
    /** A signal that aborts after `ms` milliseconds. */
    static timeout(ms: number): AbortSignal;
  }
  class AbortController {
    readonly signal: AbortSignal;
    /** Aborts the signal; only the first call counts. */
    abort(reason?: unknown): void;
  }
  class URL {
    constructor(url: string, base?: string | URL);
    readonly protocol: string;
    username: string;
    password: string;
    readonly host: string;
    readonly hostname: string;
    readonly port: string;
    readonly origin: string;
    pathname: string;
    search: string;
    hash: string;
    readonly searchParams: URLSearchParams;
    readonly href: string;
    toString(): string;
    toJSON(): string;
  }
}
