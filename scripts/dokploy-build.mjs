#!/usr/bin/env node
/**
 * Deployment-variant blueprint builder — generates `<variant>/` from the
 * local-dev stack at the repository root plus that variant's own directory.
 *
 * Sources (hand-maintained):
 *   docker-compose.yml            the ONE complete local stack
 *   Caddyfile                     the front-door routes (bind-mounted locally)
 *   idp-config/*.jsonc            the identity provider's configuration
 *                                 (bind-mounted locally; every .jsonc in the
 *                                 folder is picked up)
 *   variants/<variant>/template.toml   that variant's variables/env/domains
 *   variants/<variant>/meta.json       that variant's gallery metadata
 *   variants/<variant>/logo.svg       (optional; falls back to the repo root's)
 *
 * Output (GENERATED — committed, never hand-edited):
 *   <variant>/docker-compose.yml  deployment variant of the stack
 *   <variant>/template.toml       copied from variants/<variant>/
 *   <variant>/meta.json           copied from variants/<variant>/
 *
 * The compose transform is variant-agnostic, per the Dokploy blueprint rules
 * (github.com/Dokploy/templates):
 *   - drop every `ports:`      — Dokploy/Traefik routes by service name, not host ports
 *   - drop every `container_name:` — names must not collide across deployments
 *   - no custom networks       — Dokploy attaches its own
 *   - no bind mounts           — every bind-mounted file is embedded instead, as a
 *                                top-level `configs:` entry with inline `content:`,
 *                                so the template needs `mounts = []` and the stack
 *                                stays a single self-contained file
 *   - no `read_only:` on a service that gains such a config — compose delivers an
 *                                inline `content:` config by WRITING it into the
 *                                container filesystem, and refuses outright on a
 *                                read-only one ("cannot create config … in
 *                                read-only service"). Nothing else about the
 *                                service changes.
 *
 * Comments in the source compose are preserved (yaml Document round-trip).
 *
 * Usage (from the repository root, the folder it builds):
 *   ./dokploy-build.sh [variant]     (Windows: dokploy-build.cmd; default: dokploy)
 *
 * or directly, from anywhere:
 *   node scripts/dokploy-build.mjs [variant]
 *
 * A second variant is a DIRECTORY under variants/, not a fork of this script.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { isMap, isSeq, parseDocument, Scalar, YAMLMap } from "yaml";

// The variant to build: names variants/<variant>/ (the inputs) and <variant>/
// (the committed output folder in the repo root).
const VARIANT = process.argv[2] ?? "dokploy";
if (!/^[a-z][a-z0-9-]*$/.test(VARIANT)) {
  console.error(`\ndokploy-build FAILED — variant name must be a lowercase slug, got: ${VARIANT}\n`);
  process.exit(1);
}

// Paths are resolved relative to THIS file, so the task works from any cwd.
const SRC_DIR = new URL("../", import.meta.url);
const VARIANT_DIR = new URL(`variants/${VARIANT}/`, SRC_DIR);
const OUT_DIR = new URL(`${VARIANT}/`, SRC_DIR);
const src = (name) => new URL(name, SRC_DIR);
const variantSrc = (name) => new URL(name, VARIANT_DIR);
const out = (name) => new URL(name, OUT_DIR);

// ---------------------------------------------------------------------------
// The generated compose header. Replaces the local-dev header, which documents
// host ports and the bind-mounted config files — neither of which exists here.
// ---------------------------------------------------------------------------
const GENERATED_HEADER = ` GENERATED FILE — DO NOT EDIT.
 Built from ../docker-compose.yml + ../Caddyfile + ../idp-config/*.jsonc +
 ../variants/${VARIANT}/ by \`./dokploy-build.sh ${VARIANT}\`
 (scripts/dokploy-build.mjs). Change those, then regenerate.

 The ${VARIANT} blueprint variant of the semantius stack. Same services as the
 local-dev compose, minus everything a one-click deployment must not carry:
 host \`ports:\` (the platform's proxy routes to the \`caddy\` service by name —
 see template.toml's [[config.domains]]), \`container_name:\` (would collide
 across deployments) and bind mounts (the Caddyfile and the identity provider's
 configuration are embedded in the top-level \`configs:\` block below, so
 \`mounts = []\` in the template).

 One further difference, forced rather than chosen: a service carrying an inline
 \`content:\` config cannot also be \`read_only\`, because compose delivers such a
 config by writing it into the container filesystem. \`read_only\` is therefore
 dropped from those services here — cap_drop, no-new-privileges and the tmpfs
 are not.

 Requires docker compose >= 2.23.1 on the target server (inline configs.content).`;

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------
function fail(msg) {
  console.error(`\ndokploy-build FAILED — ${msg}\n`);
  process.exit(1);
}

/** Read a text file with CRLF normalised away. */
function readText(path) {
  return readFileSync(path, "utf8").replace(/\r\n/g, "\n");
}

/** Write LF-only UTF-8. */
function writeText(path, text) {
  writeFileSync(path, text.replace(/\r\n/g, "\n"));
}

// ---------------------------------------------------------------------------
// The variant's own files: template.toml (variables/env/domains) and meta.json
// (the gallery card). Hand-maintained under variants/<variant>/ and COPIED into
// the output, so a second variant is a directory rather than a fork of this
// script.
// ---------------------------------------------------------------------------
if (!existsSync(VARIANT_DIR)) fail(`no variants/${VARIANT}/ directory`);

let TEMPLATE_TOML;
try {
  TEMPLATE_TOML = readText(variantSrc("template.toml"));
} catch {
  fail(`variants/${VARIANT}/template.toml is missing`);
}

let metaJsonText;
let metaJson;
try {
  metaJsonText = readText(variantSrc("meta.json"));
  metaJson = JSON.parse(metaJsonText);
} catch (e) {
  fail(`variants/${VARIANT}/meta.json is missing or not valid JSON: ${e.message}`);
}
if (!metaJson?.id) fail(`variants/${VARIANT}/meta.json has no "id"`);

/** Blueprint id — the folder name it gets in a Dokploy templates repo. */
const BLUEPRINT_ID = metaJson.id;

// ---------------------------------------------------------------------------
// What gets embedded. One group per service that bind-mounts configuration
// locally: the mount is dropped, each file becomes a top-level `configs:` entry,
// and the service gets a `configs:` list pointing at the same paths the mount
// used to provide.
//
// The idp's files are DISCOVERED rather than listed, so adding e.g. a
// roles.jsonc to idp-config/ needs no change here.
// ---------------------------------------------------------------------------
const idpConfigFiles = readdirSync(src("idp-config/"))
  .filter((f) => f.endsWith(".jsonc"))
  .sort()
  .map((f) => ({
    // Compose config names: the file's stem, prefixed so it cannot collide with
    // another service's. `config.jsonc` -> `idp_config`.
    name: `idp_${f.replace(/\.jsonc$/, "").replace(/[^A-Za-z0-9]+/g, "_")}`,
    source: `idp-config/${f}`,
    target: `/config/${f}`,
  }));

if (!idpConfigFiles.length) fail("no *.jsonc files in idp-config/");

const EMBED_GROUPS = [
  {
    service: "caddy",
    // The bind mount this replaces.
    isMount: (v) => v.includes("/etc/caddy/Caddyfile"),
    files: [{ name: "caddyfile", source: "Caddyfile", target: "/etc/caddy/Caddyfile" }],
    comment:
      " The Caddyfile, embedded at the bottom of this file (no bind mounts in a\n" +
      " blueprint). Edit ../Caddyfile and regenerate — never this copy.",
  },
  {
    service: "idp",
    isMount: (v) => v.includes(":/config"),
    files: idpConfigFiles,
    comment:
      " The identity provider's configuration, embedded at the bottom of this file\n" +
      " (no bind mounts in a blueprint). Edit ../idp-config/*.jsonc and regenerate\n" +
      " — never these copies. Restarting the service applies a change.",
  },
];

// Read every source file up front, so a typo in a path fails before anything is
// written and the round-trip check below has the exact bytes to compare against.
for (const group of EMBED_GROUPS) {
  for (const file of group.files) {
    const text = readText(src(file.source));
    file.content = text.endsWith("\n") ? text : `${text}\n`;
  }
}

const composeSrc = readText(src("docker-compose.yml"));

const doc = parseDocument(composeSrc);
if (doc.errors.length) fail(`source compose has YAML errors: ${doc.errors[0].message}`);

// --- header ----------------------------------------------------------------
// The local header sits as a `commentBefore` on the `services:` key; swap it for
// the generated one and hoist a banner above `name:` too.
doc.commentBefore = GENERATED_HEADER;
const servicesPair = doc.contents.items.find(
  (p) => String(p.key.value) === "services",
);
if (!servicesPair) fail("no `services:` block in the source compose");
servicesPair.key.commentBefore = undefined;

const services = servicesPair.value;
if (!isMap(services)) fail("`services:` is not a mapping");

// --- per-service: strip host ports + container names ------------------------
let strippedPorts = 0;
let strippedNames = 0;
let strippedReadOnly = 0;
for (const pair of services.items) {
  const svc = pair.value;
  if (!isMap(svc)) continue;
  if (svc.has("ports")) {
    svc.delete("ports");
    strippedPorts++;
  }
  if (svc.has("container_name")) {
    svc.delete("container_name");
    strippedNames++;
  }
}

// --- bind mounts -> compose configs -----------------------------------------
const configsMap = new YAMLMap();

for (const group of EMBED_GROUPS) {
  const svc = services.get(group.service);
  if (!isMap(svc)) fail(`no \`${group.service}\` service in the source compose`);

  const volumes = svc.get("volumes");
  if (!isSeq(volumes)) fail(`\`${group.service}\` has no \`volumes:\` list`);
  const before = volumes.items.length;
  volumes.items = volumes.items.filter((item) => {
    const v = item.value;
    return !(typeof v === "string" && group.isMount(v));
  });
  if (volumes.items.length === before) {
    fail(
      `\`${group.service}\` has no config bind mount to replace — did the compose change?`,
    );
  }
  if (volumes.items.length === 0) {
    // Nothing left to mount; an empty `volumes:` is noise at best.
    svc.delete("volumes");
  } else {
    // The comment that introduced the bind mount describes local-dev editing; it
    // is wrong here, and the yaml round-trip re-anchors it onto whatever item
    // follows.
    volumes.commentBefore = undefined;
    const first = volumes.items[0];
    if (first?.commentBefore?.includes("Caddyfile")) first.commentBefore = undefined;
  }

  // The service-level reference: `configs: [{source, target}, …]`.
  svc.set(
    doc.createNode("configs"),
    doc.createNode(group.files.map((f) => ({ source: f.name, target: f.target }))),
  );
  // An inline `content:` config is WRITTEN INTO the container filesystem, so it
  // cannot be delivered to a read-only one — compose fails the container outright
  // ("cannot create config … in read-only service: \`file\` is the sole supported
  // option"). A `file:` config would bind-mount and leave read_only intact, but a
  // blueprint has no files beside it to point at. So the config wins and read_only
  // goes, here only; the rest of the service's hardening is untouched.
  let comment = group.comment;
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

  // The top-level entry, one per file.
  for (const file of group.files) {
    // `$` must be escaped as `$$`: compose interpolates `${...}` inside
    // `content:`, and both Caddy's `{$SITE_ADDRESS::80}` and the idp's
    // `${env:...}` placeholders have to reach their reader verbatim.
    const contentScalar = new Scalar(file.content.replaceAll("$", "$$$$"));
    contentScalar.type = Scalar.BLOCK_LITERAL;
    const entry = new YAMLMap();
    entry.set(doc.createNode("content"), contentScalar);
    configsMap.set(doc.createNode(file.name), entry);
  }
}

doc.set(doc.createNode("configs"), configsMap);

const topConfigsPair = doc.contents.items.find(
  (p) => String(p.key.value) === "configs",
);
if (topConfigsPair) {
  topConfigsPair.key.commentBefore =
    " The bind-mounted files, copied verbatim from ../Caddyfile and\n" +
    " ../idp-config/*.jsonc at build time. `$` is escaped as `$$` so compose\n" +
    " leaves Caddy's own {$SITE_ADDRESS::80} and the idp's ${env:...} placeholders\n" +
    " alone — each is resolved by its own reader, from that service's environment.\n" +
    " Needs docker compose >= 2.23.1 (inline `content:` support).";
}

// lineWidth 0: never fold long lines. Folding is valid YAML and round-trips, but
// a `${VAR}` split across two lines is alarming to read in a published template.
const outCompose = doc.toString({ lineWidth: 0 });

// ---------------------------------------------------------------------------
// Validate the OUTPUT — a blueprint that breaks these rules fails in Dokploy in
// ways that are tedious to debug, so fail here instead.
// ---------------------------------------------------------------------------
const problems = [];

const outDoc = parseDocument(outCompose);
if (outDoc.errors.length) {
  problems.push(`generated compose does not parse: ${outDoc.errors[0].message}`);
}
const outAny = outDoc.toJS();
const outServices = outAny?.services ?? {};

if (!Object.keys(outServices).length) problems.push("generated compose has no services");

for (const [name, svc] of Object.entries(outServices)) {
  if (svc.ports) problems.push(`service \`${name}\` still has ports:`);
  // Compose refuses to create such a container at all — catch it here, not there.
  if (svc.configs?.length && svc.read_only) {
    problems.push(`service \`${name}\` is read_only but carries an inline config`);
  }
  if (svc.container_name) problems.push(`service \`${name}\` still has container_name:`);
  if (svc.networks) problems.push(`service \`${name}\` declares networks: (Dokploy attaches its own)`);
  for (const v of svc.volumes ?? []) {
    const s = typeof v === "string" ? v : JSON.stringify(v);
    if (/^\s*[.\/~]/.test(s) || (typeof v === "object" && v && v.type === "bind")) {
      problems.push(`service \`${name}\` still has a bind mount: ${s}`);
    }
  }
}
if (outAny?.networks) problems.push("generated compose declares top-level networks:");

// Every embedded file must be present, referenced by its service, and round-trip
// back to its source byte for byte once the `$$` escaping is undone.
for (const group of EMBED_GROUPS) {
  const refs = outServices[group.service]?.configs ?? [];
  for (const file of group.files) {
    const embedded = outAny?.configs?.[file.name]?.content;
    if (!embedded) {
      problems.push(`configs.${file.name}.content is missing or empty`);
    } else if (embedded.replaceAll("$$", "$") !== file.content) {
      problems.push(`configs.${file.name}.content does not round-trip back to ../${file.source}`);
    }
    if (!refs.some((r) => r?.source === file.name && r?.target === file.target)) {
      problems.push(
        `service \`${group.service}\` does not mount config \`${file.name}\` at ${file.target}`,
      );
    }
  }
}

// Every `${VAR:?...}` (required, no default) must be supplied by the template env.
const templateEnv = new Set(
  [...TEMPLATE_TOML.matchAll(/^\s*"([A-Za-z_][A-Za-z0-9_]*)=/gm)].map((m) => m[1]),
);
const required = new Set(
  [...outCompose.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*):\?/g)].map((m) => m[1]),
);
for (const v of required) {
  if (!templateEnv.has(v)) {
    problems.push(`compose requires \${${v}:?...} but template.toml's env does not set it`);
  }
}

// And the REVERSE: every variable the template env supplies must be consumed by
// the compose. The check above only covers `${VAR:?}` (required, no default) —
// a variable WITH a default, like IDP_DYNAMIC_ISSUER, would ship silently
// defaulted (feature off, every check green) if its name were typo'd here.
// `${NAME` also matches `${NAME:-…}` / `${NAME-…}` / `${NAME:?…}`.
for (const v of templateEnv) {
  if (!outCompose.includes(`\${${v}`)) {
    problems.push(
      `template.toml env sets ${v} but the generated compose never references \${${v}…} — typo, or a variable the stack no longer reads`,
    );
  }
}

// Every [[config.domains]] must point at a service that exists, on a port it serves.
for (const block of TEMPLATE_TOML.split("[[config.domains]]").slice(1)) {
  const svcName = block.match(/serviceName\s*=\s*"([^"]+)"/)?.[1];
  if (!svcName) problems.push("a [[config.domains]] block has no serviceName");
  else if (!outServices[svcName]) {
    problems.push(`[[config.domains]] serviceName "${svcName}" is not a service in the compose`);
  }
}

if (problems.length) {
  fail(`blueprint validation:\n  - ${problems.join("\n  - ")}`);
}

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------
mkdirSync(OUT_DIR, { recursive: true });
writeText(out("docker-compose.yml"), outCompose);
writeText(out("template.toml"), TEMPLATE_TOML);
writeText(out("meta.json"), metaJsonText.endsWith("\n") ? metaJsonText : `${metaJsonText}\n`);

// The gallery card wants a logo next to meta.json. The variant's own logo wins;
// the repo root's is the shared fallback. Missing entirely is not fatal — the
// blueprint still deploys, it just renders without a logo.
let logoNote = `  logo.svg          MISSING — drop the Semantius SVG at logo.svg in the repo root (or variants/${VARIANT}/)`;
for (const candidate of [variantSrc("logo.svg"), src("logo.svg")]) {
  try {
    const logo = readFileSync(candidate, "utf8");
    writeFileSync(out("logo.svg"), logo, "utf8");
    logoNote = "  logo.svg";
    break;
  } catch {
    // try the next location
  }
}

const embeddedNames = EMBED_GROUPS.flatMap((g) => g.files.map((f) => f.source));
console.log(
  `Wrote ${VARIANT}/ (stripped ${strippedPorts} ports:, ${strippedNames} container_name:, ${strippedReadOnly} read_only:)`,
);
console.log(`  docker-compose.yml    embeds ${embeddedNames.join(", ")}`);
console.log(`  template.toml         from variants/${VARIANT}/`);
console.log(`  meta.json             from variants/${VARIANT}/`);
console.log(logoNote);
console.log("");
console.log("Publish it as a Dokploy one-click template either way:");
console.log(`  - fork github.com/Dokploy/templates and copy this folder to blueprints/${BLUEPRINT_ID}/`);
console.log("  - or in any instance: Create Service > Advanced > Import > Base64 of these files");
