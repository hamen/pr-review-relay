#!/usr/bin/env node
/**
 * Wrap PR/issue comment markdown in <details>/<summary> (forum-style hide/show).
 *
 * Usage:
 *   node wrap-collapsed-pr-comment.mjs --summary "🔵 Cursor review (automated cross-review)" \
 *     --footer "<sub>via pr-review-relay</sub>" --file review.md
 *   node wrap-collapsed-pr-comment.mjs --auto --file existing-comment.md
 */
import { readFileSync } from 'node:fs';

export function wrapCollapsedComment(content, { summary, footer = '', defaultSummary = 'Review report' } = {}) {
  let body = content.replace(/\r\n/g, '\n').trimEnd();
  // Skip only when the comment is ALREADY a wrapped block (starts with <details>).
  // A review that merely *mentions* <details> elsewhere must still be wrapped, or
  // it loses its summary + footer (e.g. the reviewed-SHA line) and can't be
  // identified/replaced on later runs.
  if (body.trimStart().startsWith('<details')) return body;

  let extractedFooter = footer;
  if (!summary) {
    const subMatch = body.match(/\n(<sub>[\s\S]*<\/sub>)\s*$/);
    if (subMatch) {
      extractedFooter = subMatch[1].trim();
      body = body.slice(0, subMatch.index).trimEnd();
    }

    const firstLine = body.split('\n')[0] ?? '';
    if (firstLine.startsWith('## ')) {
      summary = firstLine.replace(/^##\s+/, '').trim();
      body = body.split('\n').slice(1).join('\n').trim();
    } else if (firstLine.startsWith('# ')) {
      summary = firstLine.replace(/^#\s+/, '').trim();
      body = body.split('\n').slice(1).join('\n').trim();
    } else {
      summary = defaultSummary;
    }
  }

  if (body.startsWith('```markdown') && body.endsWith('```')) {
    body = body.replace(/^```markdown\n?/, '').replace(/\n?```$/, '').trim();
  }

  const parts = [
    '<details>',
    `<summary>${summary}</summary>`,
    '',
    body,
  ];
  if (extractedFooter) {
    parts.push('', extractedFooter);
  }
  parts.push('', '</details>', '');
  return parts.join('\n');
}

function readInput(file) {
  if (file) return readFileSync(file, 'utf8');
  return readFileSync(0, 'utf8');
}

function parseArgs(argv) {
  const opts = { auto: false, summary: '', footer: '', file: null };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--auto') opts.auto = true;
    else if (a === '--summary') opts.summary = argv[++i] ?? '';
    else if (a === '--footer') opts.footer = argv[++i] ?? '';
    else if (a === '--file') opts.file = argv[++i] ?? null;
    else if (a === '-h' || a === '--help') {
      console.log(`Usage: node wrap-collapsed-pr-comment.mjs [--summary TEXT] [--footer HTML] [--file PATH]
       node wrap-collapsed-pr-comment.mjs --auto [--file PATH]`);
      process.exit(0);
    } else {
      console.error(`Unknown arg: ${a}`);
      process.exit(2);
    }
  }
  return opts;
}

const opts = parseArgs(process.argv);
const input = readInput(opts.file);
const out = wrapCollapsedComment(input, {
  summary: opts.auto ? undefined : opts.summary,
  footer: opts.footer,
});
process.stdout.write(out);
