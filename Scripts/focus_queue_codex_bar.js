#!/usr/bin/env node
'use strict';

// The visual language is adapted from haelyra/agent-usage-bar (MIT). Focus
// Queue adds exact task-agent session selection instead of using the newest
// transcript globally.

const fs = require('fs');
const os = require('os');
const path = require('path');

const TAIL_BYTES = 512 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function argumentsByName(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value.startsWith('--') && index + 1 < argv.length && !argv[index + 1].startsWith('--')) {
      values.set(value, argv[index + 1]);
      index += 1;
    } else if (value.startsWith('--')) {
      values.set(value, true);
    }
  }
  return values;
}

function readTaskAgent(contextPath, agentID) {
  try {
    const metadata = fs.lstatSync(contextPath);
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > 8 * 1024 * 1024) return null;
    const context = JSON.parse(fs.readFileSync(contextPath, 'utf8'));
    const agent = Array.isArray(context.subtasks)
      ? context.subtasks.find(item => String(item?.id || '').toLowerCase() === agentID.toLowerCase())
      : null;
    return agent ? { context, agent } : null;
  } catch {
    return null;
  }
}

function dateFoldersForSession(sessionID, sessionsRoot) {
  const compact = sessionID.replaceAll('-', '');
  const timestamp = Number.parseInt(compact.slice(0, 12), 16);
  if (!Number.isFinite(timestamp)) return [];
  const folders = new Set();
  for (const offset of [-86_400_000, 0, 86_400_000]) {
    const date = new Date(timestamp + offset);
    for (const utc of [true, false]) {
      const year = utc ? date.getUTCFullYear() : date.getFullYear();
      const month = (utc ? date.getUTCMonth() : date.getMonth()) + 1;
      const day = utc ? date.getUTCDate() : date.getDate();
      folders.add(path.join(sessionsRoot, String(year), String(month).padStart(2, '0'), String(day).padStart(2, '0')));
    }
  }
  return [...folders];
}

function findSessionFile(codexHome, sessionID) {
  if (!UUID.test(sessionID)) return null;
  const sessionsRoot = path.join(codexHome, 'sessions');
  const suffix = `-${sessionID.toLowerCase()}.jsonl`;
  for (const folder of dateFoldersForSession(sessionID, sessionsRoot)) {
    try {
      const match = fs.readdirSync(folder).find(name => name.toLowerCase().endsWith(suffix));
      if (match) return path.join(folder, match);
    } catch { /* a timezone candidate may not exist */ }
  }

  // Old or non-v7 session identifiers are uncommon. Bound the fallback so a
  // damaged session tree cannot turn a 15-second status refresh into a crawl.
  const pending = [sessionsRoot];
  let visited = 0;
  while (pending.length > 0 && visited < 10_000) {
    const folder = pending.pop();
    try {
      for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
        visited += 1;
        if (visited >= 10_000) break;
        const candidate = path.join(folder, entry.name);
        if (entry.isDirectory()) pending.push(candidate);
        else if (entry.isFile() && entry.name.toLowerCase().endsWith(suffix)) return candidate;
      }
    } catch { /* unreadable folders are ignored */ }
  }
  return null;
}

function findNewestSession(codexHome) {
  const sessionsRoot = path.join(codexHome, 'sessions');
  try {
    const newest = directory => fs.readdirSync(directory).sort().reverse();
    const folders = [];
    for (const year of newest(sessionsRoot).slice(0, 2)) {
      const yearPath = path.join(sessionsRoot, year);
      for (const month of newest(yearPath).slice(0, 2)) {
        const monthPath = path.join(yearPath, month);
        for (const day of newest(monthPath).slice(0, 4)) folders.push(path.join(monthPath, day));
      }
    }
    let best = null;
    for (const folder of folders) {
      for (const name of fs.readdirSync(folder)) {
        if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;
        const candidate = path.join(folder, name);
        const modified = fs.statSync(candidate).mtimeMs;
        if (!best || modified > best.modified) best = { path: candidate, modified };
      }
    }
    return best?.path || null;
  } catch {
    return null;
  }
}

function readSessionSnapshot(sessionFile) {
  if (!sessionFile) return { tokenCount: null, turnContext: null };
  let descriptor;
  try {
    const metadata = fs.statSync(sessionFile);
    const start = Math.max(0, metadata.size - TAIL_BYTES);
    descriptor = fs.openSync(sessionFile, 'r');
    const buffer = Buffer.alloc(metadata.size - start);
    fs.readSync(descriptor, buffer, 0, buffer.length, start);
    const lines = buffer.toString('utf8').split('\n');
    let tokenCount = null;
    let turnContext = null;
    for (let index = lines.length - 1; index >= 0 && (!tokenCount || !turnContext); index -= 1) {
      const line = lines[index];
      if (!line.includes('"token_count"') && !line.includes('"turn_context"')) continue;
      try {
        const event = JSON.parse(line);
        if (!tokenCount && event?.payload?.type === 'token_count') tokenCount = event.payload;
        if (!turnContext && event?.type === 'turn_context') turnContext = event.payload;
      } catch { /* the first tail line can be partial */ }
    }
    return { tokenCount, turnContext };
  } catch {
    return { tokenCount: null, turnContext: null };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function agentProvider(taskAgent) {
  return String(taskAgent?.agent?.provider || 'codex').toLowerCase() === 'claude' ? 'claude' : 'codex';
}

// Claude transcripts live one escaped project folder deep and are named by the
// exact session UUID, so the scan stays bounded by the project count.
function findClaudeSessionFile(claudeHome, sessionID) {
  if (!UUID.test(sessionID)) return null;
  const projectsRoot = path.join(claudeHome, 'projects');
  try {
    for (const entry of fs.readdirSync(projectsRoot, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const candidate = path.join(projectsRoot, entry.name, `${sessionID.toLowerCase()}.jsonl`);
      try {
        if (fs.statSync(candidate).isFile()) return candidate;
      } catch { /* another project's folder may not hold this session */ }
    }
  } catch { /* a missing projects root is an untracked session */ }
  return null;
}

// Claude transcripts carry per-message usage records but no quota events.
function readClaudeSessionSnapshot(sessionFile) {
  if (!sessionFile) return { claudeUsage: null, claudeModel: null };
  let descriptor;
  try {
    const metadata = fs.statSync(sessionFile);
    const start = Math.max(0, metadata.size - TAIL_BYTES);
    descriptor = fs.openSync(sessionFile, 'r');
    const buffer = Buffer.alloc(metadata.size - start);
    fs.readSync(descriptor, buffer, 0, buffer.length, start);
    const lines = buffer.toString('utf8').split('\n');
    let usage = null;
    let model = null;
    for (let index = lines.length - 1; index >= 0 && !usage; index -= 1) {
      const line = lines[index];
      if (!line.includes('"usage"')) continue;
      try {
        const event = JSON.parse(line);
        const record = event?.message?.usage;
        if (record && Number.isFinite(record.input_tokens) && Number.isFinite(record.output_tokens)) {
          usage = record;
          model = typeof event.message?.model === 'string' ? event.message.model : null;
        }
      } catch { /* the first tail line can be partial */ }
    }
    return { claudeUsage: usage, claudeModel: model };
  } catch {
    return { claudeUsage: null, claudeModel: null };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function claudeContextWindow(model) {
  return typeof model === 'string' && model.includes('[1m]') ? 1_000_000 : 200_000;
}

function claudeContextUsed(usage) {
  if (!usage) return null;
  return (usage.input_tokens || 0) + (usage.cache_read_input_tokens || 0)
    + (usage.cache_creation_input_tokens || 0);
}

function glyphs(environment = process.env) {
  const unicode = String(environment.USAGE_BAR_GLYPHS || '').toLowerCase() !== 'ascii';
  return unicode
    ? { full: '█', empty: '░', sep: '│', bolt: '⚡', star: '✳', gear: '⬢', reset: '↻' }
    : { full: '|', empty: '_', sep: '|', bolt: '*', star: '*', gear: '#', reset: '~' };
}

function palette(mode) {
  if (mode === 'plain') {
    const identity = text => text;
    return { amber: identity, rose: identity, warn: identity, crit: identity, ok: identity, dim: identity };
  }
  const color = code => text => `#[fg=${code}]${text}#[default]`;
  return {
    amber: color('colour214'), rose: color('colour173'), warn: color('colour208'),
    crit: color('colour196,bold'), ok: color('colour114'), dim: color('colour245'),
  };
}

function safeText(value, mode) {
  const clean = String(value || '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  return mode === 'tmux' ? clean.replaceAll('#', '##') : clean;
}

function bar(percent, width, marks) {
  const value = Math.max(0, Math.min(100, Math.round(percent)));
  const filled = Math.round((value / 100) * width);
  return marks.full.repeat(filled) + marks.empty.repeat(width - filled);
}

function compactTokens(value) {
  if (!Number.isFinite(value) || value <= 0) return '';
  return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(1)}M` : `${Math.round(value / 1000)}K`;
}

function countdown(epochSeconds) {
  if (!Number.isFinite(epochSeconds)) return '';
  const minutes = Math.ceil((epochSeconds * 1000 - Date.now()) / 60_000);
  if (minutes <= 0) return '';
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return minutes % 60 ? `${hours}h${minutes % 60}m` : `${hours}h`;
  return `${Math.round(hours / 24)}d`;
}

function windowLabel(minutes) {
  if (!Number.isFinite(minutes) || minutes <= 0) return '';
  if (minutes % 1440 === 0) return `${minutes / 1440}d`;
  return `${Math.round(minutes / 60)}h`;
}

function quotaSegment(window, fallbackLabel, paint, p, marks) {
  if (!window || !Number.isFinite(window.used_percent)) return '';
  const percent = Math.round(window.used_percent);
  const severity = percent >= 90 ? p.crit : percent >= 60 ? p.warn : paint;
  const reset = countdown(window.resets_at);
  return `${paint(windowLabel(window.window_minutes) || fallbackLabel)} ${severity(`${bar(percent, 8, marks)} ${percent}%`)}`
    + (reset ? ` ${p.dim(`${marks.reset}${reset}`)}` : '');
}

// One-pane-border variant: quota, context window and ticket on a single line.
// Panes without a registered agent stay empty so the border keeps only the
// plain task title.
function buildCompactLine(taskAgent, snapshot, quotaSnapshot, mode) {
  if (!taskAgent) return '';
  const marks = glyphs();
  const p = palette(mode);
  const sep = ` ${p.dim(marks.sep)} `;
  const ticket = safeText(taskAgent.context?.ticketID || 'Focus Queue', mode);
  const isClaude = agentProvider(taskAgent) === 'claude';
  const tokenCount = snapshot.tokenCount;
  const info = tokenCount?.info || {};
  const limits = isClaude ? {}
    : quotaSnapshot?.tokenCount?.rate_limits || tokenCount?.rate_limits || {};
  const quotaParts = [
    quotaSegment(limits.primary, '5h', p.amber, p, marks),
    quotaSegment(limits.secondary, '7d', p.rose, p, marks),
  ].filter(Boolean);
  const parts = [quotaParts.length > 0
    ? `${p.amber(marks.bolt)} ${quotaParts.join(sep)}`
    : p.dim(isClaude ? `${marks.bolt} no provider quota data` : `${marks.bolt} waiting for first prompt`)];
  const launch = taskAgent.agent.launchConfiguration || {};
  const model = safeText(launch.model || (isClaude ? snapshot.claudeModel : snapshot.turnContext?.model)
    || (isClaude ? 'claude' : 'codex'), mode);
  const last = info.last_token_usage;
  const used = isClaude ? claudeContextUsed(snapshot.claudeUsage) : last?.total_tokens;
  const contextWindow = isClaude ? claudeContextWindow(snapshot.claudeModel) : info.model_context_window;
  const modelParts = [p.amber(`${marks.star} ${model}`)];
  if (Number.isFinite(used) && Number.isFinite(contextWindow) && contextWindow > 0) {
    const percent = Math.min(100, Math.round((used / contextWindow) * 100));
    const paint = percent >= 90 ? p.crit : percent >= 75 ? p.warn : p.ok;
    modelParts.push(`${p.dim('ctx')} ${paint(`${bar(percent, 6, marks)} ${percent}%`)}`);
  }
  parts.push(modelParts.join(sep), p.dim(ticket));
  return parts.join(sep);
}

function countHooks(codexHome) {
  try {
    const config = fs.readFileSync(path.join(codexHome, 'config.toml'), 'utf8');
    return (config.match(/^\[hooks\.state\."[^"]+"\]/gm) || []).length;
  } catch {
    return 0;
  }
}

function buildLines(taskAgent, snapshot, quotaSnapshot, codexHome, cwd, mode) {
  const marks = glyphs();
  const p = palette(mode);
  const sep = ` ${p.dim(marks.sep)} `;
  const ticket = safeText(taskAgent?.context?.ticketID || 'Focus Queue', mode);
  const directory = safeText(path.basename(cwd || ''), mode);
  if (!taskAgent) {
    return [
      p.dim(`${marks.bolt} waiting for agent session`),
      p.dim(`${marks.star} waiting for agent session`),
      [p.rose(marks.gear), ticket, directory].filter(Boolean).join(sep),
    ];
  }

  const isClaude = agentProvider(taskAgent) === 'claude';
  const tokenCount = snapshot.tokenCount;
  const info = tokenCount?.info || {};
  const limits = isClaude ? {}
    : quotaSnapshot?.tokenCount?.rate_limits || tokenCount?.rate_limits || {};
  const last = info.last_token_usage;
  const quotaParts = [
    quotaSegment(limits.primary, '5h', p.amber, p, marks),
    quotaSegment(limits.secondary, '7d', p.rose, p, marks),
  ].filter(Boolean);
  if (!isClaude && last?.input_tokens > 0 && quotaParts.length > 0) {
    const cache = Math.round(((last.cached_input_tokens || 0) / last.input_tokens) * 100);
    quotaParts.push(`${p.dim('cache')} ${cache >= 50 ? p.ok(`${cache}%`) : p.dim(`${cache}%`)}`);
  }
  const line1 = quotaParts.length > 0
    ? `${p.amber(marks.bolt)} ${quotaParts.join(sep)}`
    : p.dim(isClaude ? `${marks.bolt} no provider quota data` : `${marks.bolt} waiting for first prompt`);

  const launch = taskAgent.agent.launchConfiguration || {};
  const model = safeText(launch.model || (isClaude ? snapshot.claudeModel : snapshot.turnContext?.model)
    || (isClaude ? 'claude' : 'codex'), mode);
  const effort = safeText(launch.effort
    || (isClaude ? '' : snapshot.turnContext?.collaboration_mode?.settings?.reasoning_effort) || '', mode);
  const modelParts = [p.amber(`${marks.star} ${model}`)];
  if (effort) modelParts.push(p.dim(effort));
  const used = isClaude ? claudeContextUsed(snapshot.claudeUsage) : last?.total_tokens;
  const contextWindow = isClaude ? claudeContextWindow(snapshot.claudeModel) : info.model_context_window;
  if (Number.isFinite(used) && Number.isFinite(contextWindow) && contextWindow > 0) {
    const percent = Math.min(100, Math.round((used / contextWindow) * 100));
    const paint = percent >= 90 ? p.crit : percent >= 75 ? p.warn : p.ok;
    modelParts.push(`${p.dim('ctx')} ${paint(`${bar(percent, 10, marks)} ${percent}%`)} ${p.dim(`${Math.round(contextWindow / 1000)}K`)}`);
  } else {
    modelParts.push(p.dim('ctx waiting'));
  }
  const total = isClaude ? '' : compactTokens(info.total_token_usage?.total_tokens);
  if (total) modelParts.push(p.dim(`${total} tok`));

  const hooks = isClaude ? 0 : countHooks(codexHome);
  const detailParts = [p.rose(marks.gear), p.dim(`task ${ticket}`)];
  if (hooks > 0) detailParts.push(p.dim(`hooks ${hooks}`));
  if (directory) detailParts.push(p.dim(directory));
  return [line1, modelParts.join(sep), detailParts.join(sep)];
}

function main() {
  const args = argumentsByName(process.argv.slice(2));
  const mode = args.has('--plain') ? 'plain' : 'tmux';
  const contextPath = args.get('--context');
  const agentID = args.get('--agent');
  const cwd = args.get('--cwd') || process.cwd();
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
  const claudeHome = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  const taskAgent = typeof contextPath === 'string' && typeof agentID === 'string'
    ? readTaskAgent(contextPath, agentID) : null;
  const provider = agentProvider(taskAgent);
  const sessionID = taskAgent?.agent?.sessionID;
  const requested = Number.parseInt(args.get('--line'), 10);
  const compact = requested === 0;
  const sessionFile = requested === 3 || typeof sessionID !== 'string'
    ? null : provider === 'claude'
      ? findClaudeSessionFile(claudeHome, sessionID) : findSessionFile(codexHome, sessionID);
  const snapshot = provider === 'claude'
    ? readClaudeSessionSnapshot(sessionFile) : readSessionSnapshot(sessionFile);
  const quotaSnapshot = provider !== 'claude' && (requested === 1 || compact) && taskAgent
    ? readSessionSnapshot(findNewestSession(codexHome)) : snapshot;
  if (compact) {
    process.stdout.write(`${buildCompactLine(taskAgent, snapshot, quotaSnapshot, mode)}\n`);
    return;
  }
  const lines = buildLines(taskAgent, snapshot, quotaSnapshot, codexHome, cwd, mode);
  process.stdout.write(`${Number.isFinite(requested) ? lines[requested - 1] || '' : lines.join('\n')}\n`);
}

module.exports = {
  readTaskAgent, findSessionFile, findNewestSession, readSessionSnapshot, buildLines,
  buildCompactLine, findClaudeSessionFile, readClaudeSessionSnapshot,
};

if (require.main === module) main();
