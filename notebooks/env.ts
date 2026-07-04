// env.ts — tiny dotenv loader for the Deno notebooks.
//
// Walks UP the directory tree from `startDir` (default: the kernel's current
// working directory), loads the first `.env` it finds, and imports the values
// into the session environment (`Deno.env`). This lets you keep API keys in a
// `.env` file OUTSIDE the git repo — on disk, never committed.
//
// Usage from a notebook cell:
//   import { loadEnvUp } from "./env.ts";
//   await loadEnvUp();

export interface LoadResult {
  /** Absolute path of the `.env` that was loaded, or null if none was found. */
  path: string | null;
  /** Names of the variables that were set. */
  loaded: string[];
}

export interface LoadOptions {
  /** Directory to start searching from. Defaults to `Deno.cwd()`. */
  startDir?: string;
  /** Overwrite variables already present in the environment. Defaults to false. */
  override?: boolean;
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
  const { startDir = Deno.cwd(), override = false } = options;

  let dir = startDir;
  while (true) {
    const candidate = `${dir}/.env`;
    let text: string | null = null;
    try {
      text = await Deno.readTextFile(candidate);
    } catch {
      // No `.env` in this directory — keep walking up.
    }

    if (text !== null) {
      const loaded: string[] = [];
      for (const [key, val] of parseEnv(text)) {
        if (!override && Deno.env.get(key) !== undefined) continue;
        Deno.env.set(key, val);
        loaded.push(key);
      }
      return { path: candidate, loaded };
    }

    const parent = dir.slice(0, dir.lastIndexOf("/"));
    if (!parent || parent === dir) {
      // Reached the filesystem root without finding a `.env`.
      return { path: null, loaded: [] };
    }
    dir = parent;
  }
}
