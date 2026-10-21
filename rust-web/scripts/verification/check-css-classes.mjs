#!/usr/bin/env node
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "../..");
const views = join(root, "assets/views");
const stylesheets = ["assets/static/css/app.css", "assets/static/css/layout.css", "assets/static/css/site.css"];

// Hooks read by scripts, not styled by a stylesheet.
const scriptHooks = new Set(["cf-turnstile"]);

function unescapeCss(name) {
  return name
    .replace(/\\([0-9a-fA-F]{1,6})\s?/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/\\(.)/g, "$1");
}

function definedClasses() {
  const defined = new Set();
  for (const file of stylesheets) {
    const css = readFileSync(join(root, file), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    for (const match of css.matchAll(/\.((?:\\[0-9a-fA-F]{1,6}\s?|\\.|[A-Za-z0-9_-])+)/g)) {
      defined.add(unescapeCss(match[1]));
    }
  }
  return defined;
}

function templates(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return templates(path);
    return name.endsWith(".html") ? [path] : [];
  });
}

function usedClasses(source) {
  const lists = [];
  for (const match of source.matchAll(/\{%-?\s*set\s+\w*class\s*=\s*"([^"]*)"\s*-?%\}/g)) {
    lists.push(match[1]);
  }
  for (const match of source.matchAll(/\{%-?\s*component\s+[^%]*%\}([\s\S]*?)\{%-?\s*endcomponent\s*-?%\}/g)) {
    if (!match[1].includes("<")) lists.push(match[1]);
  }
  const markup = source
    .replace(/\{#[\s\S]*?#\}/g, " ")
    .replace(/\{\{[\s\S]*?\}\}/g, " ")
    .replace(/\{%[\s\S]*?%\}/g, " ");
  for (const match of markup.matchAll(/\bclass="([^"]*)"/g)) lists.push(match[1]);
  return lists.flatMap((list) =>
    list
      .replace(/\{\{[\s\S]*?\}\}|\{%[\s\S]*?%\}/g, " ")
      .split(/\s+/)
      .filter(Boolean),
  );
}

const defined = definedClasses();
const missing = [];
let checked = 0;
for (const file of templates(views)) {
  const used = new Set(usedClasses(readFileSync(file, "utf8")));
  for (const name of used) {
    checked += 1;
    if (!defined.has(name) && !scriptHooks.has(name)) {
      missing.push(`${relative(root, file)}: ${name}`);
    }
  }
}

if (missing.length > 0) {
  console.error(`missing CSS classes (${missing.length}):`);
  for (const line of missing) console.error(`  ${line}`);
  console.error("check-css-classes: FAIL");
  process.exit(1);
}
console.log(`check-css-classes: PASS (${checked} class uses, ${defined.size} defined classes)`);
