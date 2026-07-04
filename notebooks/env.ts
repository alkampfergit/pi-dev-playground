// env.ts — tiny dotenv loader for the Deno notebooks.
//
// Walks UP the directory tree from `startDir` (default: the directory of THIS
// module, so it is independent of the kernel's working directory) and loads
// EVERY `.env` it finds along the way — not just the first. This lets you keep
// API keys in a `.env` OUTSIDE the git repo (on disk, never committed) and
// optionally layer a repo-local `.env` on top.
//
// Files are loaded closest-first: a `.env` nearer the module wins over one
// higher up (unless `override: true` is set). By default it also prints, for
// each `.env` found, the names of the keys it loaded.
//
// Usage from a notebook cell:
//   import { loadEnvUp } from "./env.ts";   // or "playground/env"
//   await loadEnvUp();

export interface FileLoad {
  /** Absolute path of the `.env` file. */
  path: string;
  /** Names of the variables this file actually set. */
  loaded: string[];
  /** Names present in this file but skipped (already set by a closer file/env). */
  skipped: string[];
}

export interface LoadResult {
  /** Every `.env` found, ordered closest-first. */
  files: FileLoad[];
  /** Union of all variable names that were set, across all files. */
  loaded: string[];
}

export interface LoadOptions {
  /**
   * Directory to start searching from. Defaults to the directory of this
   * module (`env.ts`), NOT `Deno.cwd()` — the Jupyter kernel's working
   * directory is unreliable (VS Code often starts it outside the repo), so we
   * anchor the walk-up to a known location inside the repo instead.
   */
  startDir?: string;
  /** Overwrite variables already present in the environment. Defaults to false. */
  override?: boolean;
  /** Print a per-file summary of the keys loaded. Defaults to true. */
  log?: boolean;
}

/** Parse the contents of a `.env` file into key/value pairs. */
function parseEnv(text: string): Array<[string, string]> {
  const pairs: Array<[string, string]> = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    if (!key) continue;
    let val = line.slice(eq + 1).trim();
    // Strip a single pair of surrounding quotes, if present.
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    pairs.push([key, val]);
  }
  return pairs;
}

export async function loadEnvUp(options: LoadOptions = {}): Promise<LoadResult> {
  // Anchor the search to this module's own directory so it works no matter
  // where the Jupyter kernel's cwd happens to be. Fall back to cwd only if the
  // module directory is somehow unavailable (e.g. loaded from a remote URL).
  const { startDir = import.meta.dirname ?? Deno.cwd(), override = false, log = true } = options;

  // 1. Collect the absolute paths of every `.env` from `startDir` up to root.
  const paths: string[] = [];
  let dir = startDir;
  while (true) {
    const candidate = `${dir}/.env`;
    try {
      await Deno.stat(candidate);
      paths.push(candidate);
    } catch {
      // No `.env` in this directory.
    }
    const parent = dir.slice(0, dir.lastIndexOf("/"));
    if (!parent || parent === dir) break; // reached filesystem root
    dir = parent;
  }

  // 2. Load them closest-first, so a nearer `.env` wins on conflicts.
  const files: FileLoad[] = [];
  const loadedAll = new Set<string>();
  for (const path of paths) {
    const text = await Deno.readTextFile(path);
    const loaded: string[] = [];
    const skipped: string[] = [];
    for (const [key, val] of parseEnv(text)) {
      // Skip if a closer file already set it (unless overriding).
      if (!override && (loadedAll.has(key) || Deno.env.get(key) !== undefined)) {
        skipped.push(key);
        continue;
      }
      Deno.env.set(key, val);
      loaded.push(key);
      loadedAll.add(key);
    }
    files.push({ path, loaded, skipped });
  }

  if (log) {
    if (files.length === 0) {
      console.log("No .env found from", startDir, "up to the filesystem root.");
    } else {
      for (const f of files) {
        const parts = [`${f.path} → ${f.loaded.length ? f.loaded.join(", ") : "(nothing new)"}`];
        if (f.skipped.length) parts.push(`(skipped, already set: ${f.skipped.join(", ")})`);
        console.log(parts.join(" "));
      }
    }
  }

  return { files, loaded: [...loadedAll] };
}
