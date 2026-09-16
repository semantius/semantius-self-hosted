#!/usr/bin/env node
/**
 * Variant builder — generates `variants/<variant>/` from the ONE hand-written
 * stack in `templates/`.
 *
 * TEMPLATES ARE WHAT YOU EDIT. VARIANTS ARE WHAT YOU RUN.
 *
 * templates/ (hand-maintained, the single source of truth):
 *   docker-compose.yml            the complete stack
 *   Caddyfile                     the front-door routes
 *   .env.example                  every variable, described once
 *   semantius-idp-config/*.jsonc  the bundled idp's configuration
 *   compose-scripts/              the compose runtime (up, create, setup-env…),
 *                                 copied into every compose variant so the
 *                                 folder stands alone; not used by dokploy
 *   variants/<variant>/variant.json   that variant's manifest (see below)
 *   variants/<variant>/header.txt     the header its compose file gets
 *   variants/<variant>/<anything else> copied verbatim into the output
 *
 * variants/ (GENERATED — committed, never hand-edited):
 *   <variant>/…                   a runnable folder, or a deployment blueprint
 *
 * A generated folder may also hold the operator's own `.env`, which a rebuild
 * must never destroy — so a build clears the paths it writes rather than the
 * directory.
 *
 * THE MANIFEST, templates/variants/<variant>/variant.json:
 *   platform        "compose"  a plain folder you `docker compose up` in
 *                   "dokploy"  a single-file blueprint for Dokploy's importer
 *   removeFeatures  names matched against `x-semantius-feature:` keys in the
 *                   compose and `# >>> feature:<name>` regions in text files.
 *                   Everything marked with a listed feature is cut.
 *   required        variables the variant CANNOT start without: every
 *                   `${VAR…}` reference becomes `${VAR:?…}`, so compose refuses
 *                   to start until .env has a value.
 *   defaults        replacement defaults for variables whose built-in default
 *                   pointed at something this variant removed.
 *
 * FEATURES, and why they are marked rather than listed here: a variant is a
 * subtraction from one stack, and the thing being subtracted knows where it
 * lives far better than a build script does. The compose carries
 * `x-semantius-feature:` (ignored by compose itself); text files carry
 * `# >>> feature:<name>` / `# <<< feature:<name>` pairs. Adding a route, a
 * variable or a service to a feature is a marker where you are already typing,
 * not an entry in a list somewhere else.
 *
 * Comments in the source compose are preserved (yaml Document round-trip).
 *
 * Usage (from anywhere):
 *   ./build.sh                 build every variant in templates/variants/
 *   ./build.sh external-idp    build one
 *   node scripts/build.mjs [variant]
 */
import {
  cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { isMap, isSeq, parseDocument, Scalar, visit, YAMLMap } from "yaml";

const ROOT = new URL("../", import.meta.url);
const TEMPLATES_DIR = new URL("templates/", ROOT);
/** Per-variant inputs: templates/variants/<name>/ builds variants/<name>/. */
const VARIANT_INPUTS_DIR = new URL("variants/", TEMPLATES_DIR);
const OUTPUT_DIR = new URL("variants/", ROOT);
/** A source file you edit: the shared stack, directly under templates/. */
const src = (name) => new URL(name, TEMPLATES_DIR);

/**
 * The compose RUNTIME: up/create/stop/status/destroy/setup-env/jwks-refresh,
 * and the .ps1 their Windows wrappers call. They belong to the `compose`
 * platform rather than to the stack or to any one variant — identical for every
 * folder you `docker compose up` in, and meaningless to a Dokploy blueprint,
 * which is a single self-contained file with no scripts beside it.
 *
 * The whole directory is copied into every compose variant at the same relative
 * paths, feature-cut like any other text. Adding one is adding a file here.
 */
const COMPOSE_SCRIPTS_DIR = new URL("compose-scripts/", TEMPLATES_DIR);

/** Every file under `dir`, as paths relative to it. */
function listFiles(dir, prefix = "") {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...listFiles(new URL(`${entry.name}/`, dir), rel));
    else out.push(rel);
  }
  return out;
}

const COMPOSE_SCRIPTS = existsSync(COMPOSE_SCRIPTS_DIR) ? listFiles(COMPOSE_SCRIPTS_DIR).sort() : [];

function fail(msg) {
  console.error(`\nbuild FAILED — ${msg}\n`);
  process.exit(1);
}

/** Read a text file with CRLF normalised away. */
function readText(path) {
  return readFileSync(path, "utf8").replace(/\r\n/g, "\n");
}

/**
 * Write UTF-8, creating parent directories. LF everywhere — except `.cmd`,
 * which cmd.exe wants CRLF, and which .gitattributes pins that way too.
 */
function writeText(path, text) {
  mkdirSync(new URL(".", path), { recursive: true });
  const lf = text.replace(/\r\n/g, "\n");
  writeFileSync(path, path.pathname.endsWith(".cmd") ? lf.replace(/\n/g, "\r\n") : lf);
}

// ---------------------------------------------------------------------------
// Feature markers in text files
// ---------------------------------------------------------------------------
// A marker is a WHOLE line that is nothing but the marker, so the paragraphs
// explaining the convention (which necessarily contain `>>> feature:<name>`)
// are never mistaken for one — `<name>` is not a slug, and trailing prose is
// not allowed by this pattern.
const MARKER = /^\s*(?:#|\/\/|;)?\s*(>>>|<<<)\s*feature:([a-z][a-z0-9-]*)\s*$/;

/**
 * Cut every region belonging to a removed feature; strip the markers of the
 * regions that stay, so no output ever carries build-only syntax.
 * Unbalanced or misnested markers fail the build — silently keeping a region
 * whose opener was typo'd is how a variant ships a service it was meant to drop.
 */
function cutFeatureBlocks(text, removeFeatures, what) {
  const out = [];
  const stack = [];
  let lineNo = 0;

  for (const line of text.split("\n")) {
    lineNo++;
    const m = line.match(MARKER);
    if (!m) {
      if (!stack.some((f) => removeFeatures.includes(f))) out.push(line);
      continue;
    }
    const [, kind, feature] = m;
    if (kind === ">>>") {
      stack.push(feature);
    } else {
      const open = stack.pop();
      if (open !== feature) {
        fail(`${what}:${lineNo}: closes feature:${feature} but the open region is ${open ? `feature:${open}` : "none"}`);
      }
    }
  }
  if (stack.length) fail(`${what}: feature:${stack[stack.length - 1]} is opened and never closed`);

  // A cut region usually leaves the blank line that separated it behind; two or
  // more blank lines in a row are the giveaway, so collapse them.
  return out.join("\n").replace(/\n{3,}/g, "\n\n");
}

// ---------------------------------------------------------------------------
// Variable rewriting
// ---------------------------------------------------------------------------
/**
 * Rewrite `${VAR…}` references: `required` names become `${VAR:?message}` and
 * `defaults` names get a new default value.
 *
 * Brace-aware rather than a regex, because defaults nest other references
 * (`${VITE_OAUTH_AUDIENCE-${IDP_JWT_AUDIENCE:-semantius://api}}`) and a regex
 * cannot find the matching close brace.
 */
function rewriteVars(text, required, defaults) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "$" || text[i + 1] !== "{") { out += text[i]; continue; }
    // `$${VAR}` is compose's ESCAPE: the container sees `${VAR}` and resolves it
    // itself. The jwks-fetch entrypoint is a shell script written that way, and
    // rewriting `$${VITE_OAUTH_CONFIG}` into `$${VITE_OAUTH_CONFIG:?…}` would
    // turn one of its own guards into a fatal exit with a message about .env.
    if (i > 0 && text[i - 1] === "$") { out += text[i]; continue; }

    let depth = 0, end = i;
    for (let j = i + 1; j < text.length; j++) {
      if (text[j] === "{") depth++;
      else if (text[j] === "}" && --depth === 0) { end = j; break; }
    }
    if (end === i) { out += text[i]; continue; }          // unterminated; leave it

    const body = text.slice(i + 2, end);
    const name = body.match(/^[A-Za-z_][A-Za-z0-9_]*/)?.[0];
    if (!name) { out += text.slice(i, end + 1); i = end; continue; }

    const rest = body.slice(name.length);
    if (required.includes(name)) {
      out += `\${${name}:?set ${name} in .env}`;
    } else if (Object.hasOwn(defaults, name)) {
      // Keep the operator the source used: `-` applies its default only when
      // the variable is UNSET, `:-` also when it is empty. JWKS_URL depends on
      // that difference — an empty value there selects discovery.
      const op = rest.startsWith(":-") ? ":-" : rest.startsWith("-") ? "-" : ":-";
      out += `\${${name}${op}${defaults[name]}}`;
    } else {
      // Not listed — but its DEFAULT may nest a reference that is:
      // `${PUBLIC_API_URL:-http://…${DOCS_API_ROUTE:-/gateway/rest}}` has to
      // reach the inner one, so recurse instead of copying the span verbatim.
      out += `\${${name}${rewriteVars(rest, required, defaults)}}`;
    }
    i = end;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Build one variant
// ---------------------------------------------------------------------------
function build(variant) {
  const VARIANT_DIR = new URL(`${variant}/`, VARIANT_INPUTS_DIR);
  const OUT_DIR = new URL(`${variant}/`, OUTPUT_DIR);
  const variantSrc = (name) => new URL(name, VARIANT_DIR);
  const out = (name) => new URL(name, OUT_DIR);

  if (!existsSync(VARIANT_DIR)) fail(`no templates/variants/${variant}/ directory`);

  let manifest;
  try {
    manifest = JSON.parse(readText(variantSrc("variant.json")));
  } catch (e) {
    fail(`templates/variants/${variant}/variant.json is missing or not valid JSON: ${e.message}`);
  }
  const platform = manifest.platform;
  if (platform !== "compose" && platform !== "dokploy") {
    fail(`templates/variants/${variant}/variant.json: platform must be "compose" or "dokploy", got ${JSON.stringify(platform)}`);
  }
  const removeFeatures = manifest.removeFeatures ?? [];
  const required = manifest.required ?? [];
  const defaults = manifest.defaults ?? {};

  let header;
  try {
    header = readText(variantSrc("header.txt"));
  } catch {
    fail(`templates/variants/${variant}/header.txt is missing`);
  }

  // --- the compose document ------------------------------------------------
  // The text pass runs FIRST, so the compose's own comments can be marked the
  // same way as the Caddyfile's routes: `x-semantius-feature` removes nodes,
  // but a paragraph explaining a service is a comment, and a variant that drops
  // the service should not inherit the paragraph describing it.
  const doc = parseDocument(
    cutFeatureBlocks(readText(src("docker-compose.yml")), removeFeatures, "docker-compose.yml"),
  );
  if (doc.errors.length) fail(`source compose has YAML errors: ${doc.errors[0].message}`);

  const servicesPair = doc.contents.items.find((p) => String(p.key.value) === "services");
  if (!servicesPair) fail("no `services:` block in the source compose");
  const services = servicesPair.value;
  if (!isMap(services)) fail("`services:` is not a mapping");

  // Feature removal, before anything else looks at the document.
  const removedServices = [];
  for (const pair of [...services.items]) {
    const svc = pair.value;
    if (!isMap(svc)) continue;
    const feature = svc.get("x-semantius-feature");
    if (feature && removeFeatures.includes(String(feature))) {
      removedServices.push(String(pair.key.value));
      services.delete(pair.key);
    }
  }
  // Any node may carry the key (a long-syntax port or volume entry, a future
  // dimension); drop marked ones wherever they are, and strip the key from the
  // survivors so no build-only syntax reaches the output.
  visit(doc, {
    Map(_, node, path) {
      const feature = node.get?.("x-semantius-feature");
      if (!feature) return;
      if (removeFeatures.includes(String(feature))) {
        const parent = path[path.length - 1];
        if (isSeq(parent)) {
          parent.items.splice(parent.items.indexOf(node), 1);
          return visit.REMOVE;
        }
      }
      node.delete("x-semantius-feature");
    },
  });

  // A removed service cannot be depended on.
  for (const pair of services.items) {
    const svc = pair.value;
    if (!isMap(svc)) continue;
    const deps = svc.get("depends_on");
    if (isMap(deps)) {
      for (const dep of [...deps.items]) {
        if (removedServices.includes(String(dep.key.value))) deps.delete(dep.key);
      }
      if (deps.items.length === 0) svc.delete("depends_on");
    } else if (isSeq(deps)) {
      deps.items = deps.items.filter((i) => !removedServices.includes(String(i.value ?? i)));
      if (deps.items.length === 0) svc.delete("depends_on");
    }
  }

  // --- header --------------------------------------------------------------
  if (manifest.replaceSourceHeader) {
    doc.commentBefore = header;
    servicesPair.key.commentBefore = undefined;
  } else {
    doc.commentBefore = header;
  }

  // --- the text sources ----------------------------------------------------
  const caddyfile = cutFeatureBlocks(readText(src("Caddyfile")), removeFeatures, "Caddyfile");
  let envExample = cutFeatureBlocks(readText(src(".env.example")), removeFeatures, ".env.example");

  const strippedPorts = [];
  const strippedNames = [];
  let strippedReadOnly = 0;
  const configsMap = new YAMLMap();
  const embedded = [];

  if (platform === "dokploy") {
    // Dokploy blueprint rules (github.com/Dokploy/templates): no host ports,
    // no container names, no bind mounts — every bind-mounted file is embedded
    // as a top-level `configs:` entry with inline content instead.
    for (const pair of services.items) {
      const svc = pair.value;
      if (!isMap(svc)) continue;
      if (svc.has("ports")) { svc.delete("ports"); strippedPorts.push(String(pair.key.value)); }
      if (svc.has("container_name")) { svc.delete("container_name"); strippedNames.push(String(pair.key.value)); }
    }

    for (const pair of services.items) {
      const name = String(pair.key.value);
      const svc = pair.value;
      if (!isMap(svc)) continue;
      const volumes = svc.get("volumes");
      if (!isSeq(volumes)) continue;

      // Derived, not listed: every `./`-prefixed bind mount on a surviving
      // service becomes an embed group. A file mount is one config; a directory
      // mount is one per file found in it. Nothing here knows what a Caddyfile
      // or an semantius-idp-config is, so a variant that drops either needs no change.
      const files = [];
      volumes.items = volumes.items.filter((item) => {
        const v = item.value;
        if (typeof v !== "string" || !v.startsWith("./")) return true;
        const [source, target] = v.split(":");
        const rel = source.slice(2);
        const abs = src(rel);
        // `<service>_<file stem>`, lowercased: compose config names are
        // identifiers people read in a deployment UI, and `semantius_Caddyfile`
        // reads like a typo next to `idp_config`.
        const stem = (s) => s.replace(/\.[^.]+$/, "").replace(/[^A-Za-z0-9]+/g, "_").toLowerCase();
        if (statSync(abs).isDirectory()) {
          for (const f of readdirSync(abs).sort()) {
            files.push({
              name: `${name}_${stem(f)}`,
              source: `${rel}/${f}`,
              target: `${target}/${f}`,
              content: readText(src(`${rel}/${f}`)),
            });
          }
        } else {
          files.push({
            name: `${name}_${stem(rel.split("/").pop())}`,
            source: rel,
            target,
            content: rel === "Caddyfile" ? caddyfile : readText(abs),
          });
        }
        return false;
      });
      if (!files.length) continue;
      if (volumes.items.length === 0) svc.delete("volumes");
      else volumes.commentBefore = undefined;

      for (const f of files) if (!f.content.endsWith("\n")) f.content += "\n";

      svc.set(
        doc.createNode("configs"),
        doc.createNode(files.map((f) => ({ source: f.name, target: f.target }))),
      );
      let comment =
        ` Embedded from ../../${files.map((f) => f.source).join(", ../../")} at build time —\n` +
        ` a blueprint is one file, so it carries no bind mounts. Edit the source and\n` +
        ` regenerate; restart the service to apply a change.`;
      if (svc.has("read_only")) {
        svc.delete("read_only");
        strippedReadOnly++;
        comment +=
          "\n\n An inline config is written into the container filesystem, so this service\n" +
          " cannot also be `read_only` — it is dropped in this generated variant and\n" +
          " nowhere else. cap_drop, no-new-privileges and the tmpfs are unchanged.";
      }
      const configsPair = svc.items.find((p) => String(p.key.value) === "configs");
      if (configsPair) configsPair.key.commentBefore = comment;

      for (const f of files) {
        // `$` must be escaped as `$$`: compose interpolates `${...}` inside
        // `content:`, and Caddy's `{$SITE_ADDRESS::80}` and the idp's
        // `${env:...}` placeholders have to reach their reader verbatim.
        const scalar = new Scalar(f.content.replaceAll("$", "$$$$"));
        scalar.type = Scalar.BLOCK_LITERAL;
        const entry = new YAMLMap();
        entry.set(doc.createNode("content"), scalar);
        configsMap.set(doc.createNode(f.name), entry);
        embedded.push(f);
      }
    }

    doc.set(doc.createNode("configs"), configsMap);
    const topConfigsPair = doc.contents.items.find((p) => String(p.key.value) === "configs");
    if (topConfigsPair) {
      topConfigsPair.key.commentBefore =
        " The bind-mounted files, copied verbatim from the repository at build time.\n" +
        " `$` is escaped as `$$` so compose leaves the placeholders inside them alone —\n" +
        " each is resolved by its own reader, from that service's environment.\n" +
        " Needs docker compose >= 2.23.1 (inline `content:` support).";
    }
  }

  // --- variable rewriting --------------------------------------------------
  // On the serialized document: one pass covers every scalar, including the
  // ones nested inside JSON-ish values like API_REFERENCE_CONFIG.
  let outCompose = doc.toString({ lineWidth: 0 });
  if (required.length || Object.keys(defaults).length) {
    outCompose = rewriteVars(outCompose, required, defaults);
  }

  // --- validate ------------------------------------------------------------
  const problems = [];
  const outDoc = parseDocument(outCompose);
  if (outDoc.errors.length) problems.push(`generated compose does not parse: ${outDoc.errors[0].message}`);
  const outAny = outDoc.toJS() ?? {};
  const outServices = outAny.services ?? {};
  if (!Object.keys(outServices).length) problems.push("generated compose has no services");

  for (const [name, svc] of Object.entries(outServices)) {
    if (JSON.stringify(svc).includes("x-semantius-feature")) {
      problems.push(`service \`${name}\` still carries x-semantius-feature`);
    }
    for (const gone of removedServices) {
      for (const dep of Object.keys(svc.depends_on ?? {})) {
        if (dep === gone) problems.push(`service \`${name}\` still depends_on the removed \`${gone}\``);
      }
    }
  }
  // A removed service must not survive as a hostname anywhere in the compose
  // or the Caddyfile — a dangling `reverse_proxy idp:3000` is a 502 nobody
  // expected, and comments are excluded so prose about it stays legible.
  for (const gone of removedServices) {
    const hostname = new RegExp(`(^|[^A-Za-z0-9_-])${gone}:\\d+`);
    for (const [label, text] of [["compose", outCompose], ["Caddyfile", caddyfile]]) {
      const hit = text.split("\n").find((l) => !/^\s*(#|\/\/)/.test(l) && hostname.test(l));
      if (hit) problems.push(`${label} still names the removed service \`${gone}\`: ${hit.trim()}`);
    }
  }

  if (platform === "dokploy") {
    for (const [name, svc] of Object.entries(outServices)) {
      if (svc.ports) problems.push(`service \`${name}\` still has ports:`);
      if (svc.container_name) problems.push(`service \`${name}\` still has container_name:`);
      if (svc.networks) problems.push(`service \`${name}\` declares networks: (Dokploy attaches its own)`);
      if (svc.configs?.length && svc.read_only) {
        problems.push(`service \`${name}\` is read_only but carries an inline config`);
      }
      for (const v of svc.volumes ?? []) {
        const s = typeof v === "string" ? v : JSON.stringify(v);
        if (/^\s*[.\/~]/.test(s) || (typeof v === "object" && v && v.type === "bind")) {
          problems.push(`service \`${name}\` still has a bind mount: ${s}`);
        }
      }
    }
    if (outAny.networks) problems.push("generated compose declares top-level networks:");
    // Every embedded file must round-trip back to its source, byte for byte,
    // once the `$$` escaping is undone.
    for (const f of embedded) {
      const got = outAny.configs?.[f.name]?.content;
      if (!got) problems.push(`configs.${f.name}.content is missing or empty`);
      else if (got.replaceAll("$$", "$") !== f.content) {
        problems.push(`configs.${f.name}.content does not round-trip back to ${f.source}`);
      }
    }
  }

  // --- the variant's .env.example -----------------------------------------
  if (platform === "compose" && (required.length || Object.keys(defaults).length)) {
    const block = [
      "# =============================================================================",
      `# Set these before the stack will start. \`docker compose up\` refuses to run`,
      "# while any of them is empty. README.md in this folder says what each one is",
      "# and where to get it.",
      "# =============================================================================",
      ...required.map((v) => `${v}=`),
      "",
      "# Defaults that differ from the bundled stack. Uncomment to change one.",
      ...Object.entries(defaults).map(([k, v]) => `# ${k}=${v}`),
      "",
    ].join("\n");
    envExample = `${block}\n${envExample}`;
  }

  if (platform === "compose") {
    // Every required variable must reach the operator: a `${VAR:?}` the
    // .env.example never mentions is a stack that refuses to start and does not
    // say what to set.
    for (const v of required) {
      if (!new RegExp(`^\\s*#?\\s*${v}=`, "m").test(envExample)) {
        problems.push(`required variable ${v} has no line in the generated .env.example`);
      }
    }
    // And each variable must have exactly ONE value line, or an operator edits
    // the wrong one and cannot see why nothing changed.
    for (const v of [...required, ...Object.keys(defaults)]) {
      const lines = envExample.split("\n").filter((l) => new RegExp(`^\\s*#?\\s*${v}=`).test(l));
      if (lines.length > 1) problems.push(`${v} has ${lines.length} value lines in the generated .env.example`);
    }
    // A typo in the manifest is otherwise invisible: the variable simply never
    // appears, and the variant quietly keeps the source default.
    for (const v of [...required, ...Object.keys(defaults)]) {
      if (!outCompose.includes(`\${${v}`)) {
        problems.push(`variant.json names ${v} but the generated compose never references \${${v}…}`);
      }
    }
  }

  if (problems.length) fail(`${variant}: validation:\n  - ${problems.join("\n  - ")}`);

  // --- emit ----------------------------------------------------------------
  // Remove only what THIS build produces, never the whole folder: a runnable
  // variant holds the operator's own .env (and nothing else of ours), and a
  // rebuild that deleted it would take their passwords with it. Stale outputs
  // still go, because every path written below is cleared first.
  const clear = (rel) => rmSync(out(rel), { recursive: true, force: true });
  mkdirSync(OUT_DIR, { recursive: true });
  for (const rel of ["docker-compose.yml", ".env.example", "Caddyfile", "import.base64.txt", "logo.svg", ...COMPOSE_SCRIPTS]) {
    clear(rel);
  }
  for (const entry of readdirSync(VARIANT_DIR)) {
    if (entry !== "variant.json" && entry !== "header.txt") clear(entry);
  }
  writeText(out("docker-compose.yml"), outCompose);

  const written = ["docker-compose.yml"];

  if (platform === "compose") {
    writeText(out(".env.example"), envExample);
    written.push(".env.example");

    // Whatever the surviving services bind-mount has to exist beside the
    // compose file. Derived from the mounts, so nothing here has to know what
    // a Caddyfile or an semantius-idp-config directory is.
    for (const svc of Object.values(outServices)) {
      for (const v of svc.volumes ?? []) {
        if (typeof v !== "string" || !v.startsWith("./")) continue;
        const rel = v.split(":")[0].slice(2);
        if (rel === "Caddyfile") {
          writeText(out("Caddyfile"), caddyfile);
        } else if (statSync(src(rel)).isDirectory()) {
          cpSync(src(rel), out(`${rel}/`), { recursive: true });
        } else {
          cpSync(src(rel), out(rel));
        }
        if (!written.includes(rel)) written.push(rel);
      }
    }

    // The compose runtime, so the folder is runnable on its own. Feature-cut
    // like everything else — setup-env generates a secret per feature, and a
    // variant that dropped one must not ask for it.
    for (const rel of COMPOSE_SCRIPTS) {
      const text = cutFeatureBlocks(
        readText(new URL(rel, COMPOSE_SCRIPTS_DIR)), removeFeatures, `compose-scripts/${rel}`,
      );
      writeText(out(rel), text);
    }
    written.push(`${COMPOSE_SCRIPTS.length} compose scripts`);
  }

  if (platform === "dokploy") {
    // template.toml and meta.json drive Dokploy's importer; they are part of
    // the variant directory and copied below like everything else, but the
    // blueprint bundle and the checks need them here.
    let templateToml, metaJson, metaJsonText;
    try {
      templateToml = readText(variantSrc("template.toml"));
      metaJsonText = readText(variantSrc("meta.json"));
      metaJson = JSON.parse(metaJsonText);
    } catch (e) {
      fail(`templates/variants/${variant}: a dokploy variant needs template.toml and meta.json: ${e.message}`);
    }
    if (!metaJson?.id) fail(`templates/variants/${variant}/meta.json has no "id"`);

    const templateProblems = [];
    const templateEnv = new Set(
      [...templateToml.matchAll(/^\s*"([A-Za-z_][A-Za-z0-9_]*)=/gm)].map((m) => m[1]),
    );
    for (const v of [...outCompose.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*):\?/g)].map((m) => m[1])) {
      if (!templateEnv.has(v)) templateProblems.push(`compose requires \${${v}:?…} but template.toml's env does not set it`);
    }
    // And the reverse: a typo'd name in template.toml would ship silently
    // defaulted, every check green.
    for (const v of templateEnv) {
      if (!outCompose.includes(`\${${v}`)) {
        templateProblems.push(`template.toml env sets ${v} but the compose never references \${${v}…}`);
      }
    }
    for (const block of templateToml.split("[[config.domains]]").slice(1)) {
      const svcName = block.match(/serviceName\s*=\s*"([^"]+)"/)?.[1];
      if (!svcName) templateProblems.push("a [[config.domains]] block has no serviceName");
      else if (!outServices[svcName]) {
        templateProblems.push(`[[config.domains]] serviceName "${svcName}" is not a service in the compose`);
      }
    }
    if (templateProblems.length) fail(`${variant}: validation:\n  - ${templateProblems.join("\n  - ")}`);

    // The paste-in-the-UI bundle: base64 of exactly what Dokploy's
    // compose.processTemplate decodes — the compose YAML plus template.toml as
    // a TOML string. Without it the blueprint's generated secrets and ${domain}
    // are unreachable outside a published gallery.
    const importBundle = Buffer.from(
      JSON.stringify({ compose: outCompose, config: templateToml }), "utf8",
    ).toString("base64");
    writeText(out("import.base64.txt"), `${importBundle}\n`);
    written.push("import.base64.txt");

    // The gallery card wants a logo beside meta.json; the variant's own wins,
    // the repo root's is the shared fallback, missing is not fatal.
    for (const candidate of [variantSrc("logo.svg"), src("logo.svg")]) {
      if (existsSync(candidate)) { cpSync(candidate, out("logo.svg")); written.push("logo.svg"); break; }
    }
  }

  // Everything else in the variant directory, verbatim: template.toml and
  // meta.json for Dokploy, entra/ for external-idp, whatever a later variant
  // needs. One rule instead of a list.
  for (const entry of readdirSync(VARIANT_DIR)) {
    if (entry === "variant.json" || entry === "header.txt" || entry === "logo.svg") continue;
    cpSync(variantSrc(entry), out(entry), { recursive: true });
    written.push(entry);
  }

  // Anything in the output this build did not produce: either the operator's
  // (their .env, a compose override) or a LEFTOVER from a source that has since
  // been renamed or removed — which a committed output would otherwise keep
  // forever, because a build only clears the paths it writes. Reported, never
  // deleted: guessing wrong here costs somebody their .env.
  const produced = new Set([
    ...written,
    ...COMPOSE_SCRIPTS.map((rel) => rel.split("/")[0]),   // `written` counts these, not names them
  ]);
  const strays = readdirSync(OUT_DIR).filter(
    (e) => !produced.has(e) && !e.startsWith(".env") && !e.startsWith("docker-compose.override"),
  );

  const summary = platform === "dokploy"
    ? `stripped ${strippedPorts.length} ports:, ${strippedNames.length} container_name:, ${strippedReadOnly} read_only:, embedded ${embedded.length} files`
    : `${removedServices.length ? `removed ${removedServices.join(", ")}` : "complete stack"}`;
  console.log(`variants/${variant}/  (${platform}: ${summary})`);
  console.log(`  ${written.join(", ")}`);
  if (strays.length) {
    console.log(`  NOT produced by this build — yours, or stale: ${strays.join(", ")}`);
  }
}

// ---------------------------------------------------------------------------
const requested = process.argv[2];
if (requested && !/^[a-z][a-z0-9-]*$/.test(requested)) {
  fail(`variant name must be a lowercase slug, got: ${requested}`);
}
if (!existsSync(VARIANT_INPUTS_DIR)) {
  fail("templates/variants/ does not exist — that is where each variant's variant.json lives");
}

const variants = requested
  ? [requested]
  : readdirSync(VARIANT_INPUTS_DIR)
      .filter((d) => existsSync(new URL(`${d}/variant.json`, VARIANT_INPUTS_DIR)))
      .sort();

// Finding nothing is a FAILURE, not an empty success. A moved directory, a
// renamed manifest or a run from the wrong checkout would otherwise print the
// closing summary and exit 0, having built nothing at all.
if (!variants.length) {
  fail("no variants found in templates/variants/ — each one needs a variant.json");
}

for (const v of variants) build(v);

console.log("");
console.log(`Built ${variants.length} variant${variants.length === 1 ? "" : "s"} into variants/: ${variants.join(", ")}.`);
console.log("A compose variant is runnable where it stands: cd into it, ./setup-env.sh, ./up.sh.");
console.log("A dokploy variant is published as a one-click template — see the README.");
