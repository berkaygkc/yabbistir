// Builds the extensions in builtin/ into BuiltinExtensions/<id>/ (the folder the app ships) and the
// ones in reference/, when that local-only folder exists, into ReferenceExtensions/<id>/ (tests only; never bundled).
import { build } from "esbuild";
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

async function buildAll(sources, output) {
  if (!existsSync(sources)) return;
  rmSync(output, { recursive: true, force: true });
  for (const id of readdirSync(sources).filter((name) => !name.startsWith("."))) {
    const source = join(sources, id);
    const destination = join(output, id);
    mkdirSync(destination, { recursive: true });
    await build({
      entryPoints: [join(source, "src/index.ts")],
      outfile: join(destination, "index.js"),
      bundle: true,
      format: "cjs",
      platform: "neutral",
      target: "es2022",
      legalComments: "none",
      logLevel: "warning",
    });
    cpSync(join(source, "manifest.json"), join(destination, "manifest.json"));
    cpSync(join(source, "locales"), join(destination, "locales"), { recursive: true });
    if (existsSync(join(source, "icon.png"))) cpSync(join(source, "icon.png"), join(destination, "icon.png"));
    console.log(`built ${id}`);
  }
}

await buildAll(join(root, "builtin"), join(root, "BuiltinExtensions"));
await buildAll(join(root, "reference"), join(root, "ReferenceExtensions"));
