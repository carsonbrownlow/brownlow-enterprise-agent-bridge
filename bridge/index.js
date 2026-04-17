const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HOME = os.homedir();
// On Windows, node.spawn() cannot execute .cmd / .bat shims (claude.cmd,
// pm2.cmd, etc.) directly — it errors with EINVAL. Passing shell:true
// routes the call through cmd.exe which knows how to resolve the shim.
const IS_WINDOWS = process.platform === 'win32';

function resolveClaudePath() {
  if (process.env.CLAUDE_PATH) return process.env.CLAUDE_PATH;
  const candidates = [
    path.join(HOME, '.local/bin/claude'),
    '/opt/homebrew/bin/claude',
    '/usr/local/bin/claude',
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch {}
  }
  return 'claude';
}

const CLAUDE_PATH = resolveClaudePath();
const NODE_BIN_DIR = path.dirname(process.execPath);
const PORT = parseInt(process.env.PORT || '3456', 10);
const REQUEST_TIMEOUT_MS = parseInt(process.env.REQUEST_TIMEOUT_MS || '120000', 10);
const RESPAWN_DELAY_MS = parseInt(process.env.RESPAWN_DELAY_MS || '2000', 10);
const HEARTBEAT_INTERVAL_MS = parseInt(process.env.HEARTBEAT_INTERVAL_MS || '3000', 10);
const SENTINEL = process.env.BRIDGE_SENTINEL || '---AGENT_END---';
const SESSION_LOG_PATH = path.join(__dirname, 'session_logs.jsonl');
const CLAUDE_CWD = process.env.CLAUDE_CWD || HOME;

const childEnv = {
  ...process.env,
  HOME,
  PATH: `${NODE_BIN_DIR}:${path.join(HOME, '.local/bin')}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`,
};

const state = {
  proc: null,
  sessionId: null,
  ready: false,
  queue: [],
  inFlight: null,
  requestCount: 0,
  respawnCount: 0,
  bootTime: Date.now(),
  sessionStartTime: null,
  lastError: null,
  authOk: null,
  wsClients: new Set(),
};

function log(...args) { console.log('[bridge]', new Date().toISOString(), ...args); }
function logErr(...args) { console.error('[bridge]', new Date().toISOString(), ...args); }

function wsSend(ws, obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    try { ws.send(JSON.stringify(obj)); } catch (e) { logErr('ws send failed', e.message); }
  }
}

function broadcastReady() {
  for (const ws of state.wsClients) {
    wsSend(ws, { type: 'ready', session_id: state.sessionId });
  }
}

function finishInFlight(payload, statusCode = 200) {
  const r = state.inFlight;
  if (!r) return;
  clearTimeout(r.timer);
  if (r.heartbeat) clearInterval(r.heartbeat);
  const ms = Date.now() - r.startTime;
  if (r.ws) {
    const isErr = statusCode >= 400 || payload.error;
    if (isErr) {
      wsSend(r.ws, { type: 'error', message: payload.error || 'error', detail: payload, ms });
    } else {
      wsSend(r.ws, { type: 'done', content: payload.response, session_id: payload.session_id, ms });
    }
  } else if (r.res && !r.res.headersSent) {
    r.res.status(statusCode).json({ ...payload, ms });
  }
  state.inFlight = null;
}

function stripSentinel(text) {
  const t = (text || '').trim();
  const idx = t.indexOf(SENTINEL);
  return idx === -1 ? t : t.slice(0, idx).trim();
}

function streamTokenFromAssistant(evt) {
  if (!state.inFlight || !state.inFlight.ws) return;
  const content = evt && evt.message && evt.message.content;
  if (!Array.isArray(content)) return;
  for (const block of content) {
    if (block && block.type === 'text' && typeof block.text === 'string' && block.text.length) {
      const clean = stripSentinel(block.text);
      const prev = state.inFlight.tokensSeen || '';
      let delta = clean;
      if (clean.startsWith(prev)) delta = clean.slice(prev.length);
      if (delta) {
        state.inFlight.tokensSeen = clean;
        state.inFlight.lastTokenTime = Date.now();
        wsSend(state.inFlight.ws, { type: 'token', content: delta });
      }
    }
  }
}

function handleClaudeLine(line) {
  let evt;
  try { evt = JSON.parse(line); } catch { return; }

  if (evt.type === 'system' && evt.subtype === 'init') {
    state.sessionId = evt.session_id;
    if (!state.sessionStartTime) state.sessionStartTime = Date.now();
    log('session init', state.sessionId);
    broadcastReady();
    return;
  }

  if (evt.type === 'assistant') {
    streamTokenFromAssistant(evt);
    return;
  }

  if (evt.type === 'result') {
    if (!state.inFlight) return;
    if (evt.is_error) {
      finishInFlight({ error: 'claude reported error', detail: evt.result, session_id: state.sessionId }, 502);
    } else {
      const text = stripSentinel(evt.result || '');
      finishInFlight({ response: text, session_id: state.sessionId });
    }
    processQueue();
  }
}

function startClaude() {
  log('spawning claude session');
  const proc = spawn(CLAUDE_PATH, [
    '-p',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--verbose',
    '--dangerously-skip-permissions',
    '--setting-sources', 'user,project,local',
    '--chrome',
  ], {
    env: childEnv,
    stdio: ['pipe', 'pipe', 'pipe'],
    cwd: CLAUDE_CWD,
    shell: IS_WINDOWS, // required so Node can invoke claude.cmd on Windows
  });

  state.proc = proc;
  state.ready = true;
  state.sessionId = null;
  state.sessionStartTime = null;

  let buf = '';
  proc.stdout.on('data', (d) => {
    buf += d.toString();
    let idx;
    while ((idx = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (line) handleClaudeLine(line);
    }
  });

  proc.stderr.on('data', (d) => {
    const s = d.toString().trim();
    if (s) logErr('[claude stderr]', s);
  });

  proc.on('error', (err) => {
    logErr('spawn error', err.message);
    state.lastError = `spawn: ${err.message}`;
  });

  proc.on('exit', (code, signal) => {
    logErr(`claude exited code=${code} signal=${signal}`);
    state.proc = null;
    state.ready = false;
    state.sessionId = null;
    if (state.inFlight) {
      finishInFlight({ error: 'claude process exited mid-request', exit_code: code, signal }, 500);
    }
    state.respawnCount++;
    state.lastError = `claude exited code=${code} signal=${signal}`;
    setTimeout(startClaude, RESPAWN_DELAY_MS);
  });

  setTimeout(processQueue, 100);
}

function processQueue() {
  if (!state.ready || !state.proc) return;
  if (state.inFlight) return;
  if (state.queue.length === 0) return;

  const req = state.queue.shift();
  state.inFlight = req;
  req.startTime = Date.now();
  req.tokensSeen = '';
  req.lastTokenTime = Date.now();

  const msg = {
    type: 'user',
    message: { role: 'user', content: req.message },
  };

  try {
    state.proc.stdin.write(JSON.stringify(msg) + '\n');
  } catch (err) {
    logErr('stdin write failed', err.message);
    finishInFlight({ error: 'failed to write to claude stdin', detail: err.message }, 500);
    return;
  }

  if (req.ws) {
    req.heartbeat = setInterval(() => {
      if (state.inFlight !== req) return;
      if (Date.now() - req.lastTokenTime >= HEARTBEAT_INTERVAL_MS) {
        wsSend(req.ws, { type: 'heartbeat', content: 'working...' });
        req.lastTokenTime = Date.now();
      }
    }, HEARTBEAT_INTERVAL_MS);
  }

  req.timer = setTimeout(() => {
    if (state.inFlight === req) {
      logErr('request timed out — killing session to recover');
      finishInFlight({ error: 'request timed out', timeout_ms: REQUEST_TIMEOUT_MS }, 504);
      if (state.proc) state.proc.kill('SIGTERM');
    }
  }, REQUEST_TIMEOUT_MS);
}

function runAuthCheck(cb) {
  log('auth check: claude -p ping');
  const t = spawn(CLAUDE_PATH, ['-p', 'ping', '--output-format', 'json'], {
    env: childEnv,
    stdio: ['ignore', 'pipe', 'pipe'],
    cwd: CLAUDE_CWD,
    shell: IS_WINDOWS, // required so Node can invoke claude.cmd on Windows
  });
  let out = '';
  t.stdout.on('data', (d) => { out += d.toString(); });
  t.on('error', (err) => { state.authOk = false; state.lastError = `auth-check spawn: ${err.message}`; logErr('auth check spawn failed', err.message); cb(); });
  t.on('close', () => {
    let parsed;
    try { parsed = JSON.parse(out); } catch { parsed = null; }
    if (!parsed) {
      state.authOk = false;
      state.lastError = 'auth check produced unparseable output';
      logErr('auth check output unparseable:', out.slice(0, 200));
    } else if (parsed.is_error && /not logged in/i.test(parsed.result || '')) {
      state.authOk = false;
      state.lastError = 'Claude not authenticated';
      logErr('BRIDGE: Claude not authenticated — run `claude` interactively to log in, then restart the bridge (pm2 restart agent-bridge).');
    } else if (parsed.is_error) {
      state.authOk = false;
      state.lastError = `auth check error: ${parsed.result}`;
      logErr('auth check error:', parsed.result);
    } else {
      state.authOk = true;
      log('auth check passed');
    }
    cb();
  });
}

async function handleEndSession(ws) {
  const summary = {
    ts: new Date().toISOString(),
    session_id: state.sessionId,
    request_count: state.requestCount,
    bridge_uptime_ms: Date.now() - state.bootTime,
    session_uptime_ms: state.sessionStartTime ? Date.now() - state.sessionStartTime : null,
  };
  try {
    fs.appendFileSync(SESSION_LOG_PATH, JSON.stringify(summary) + '\n');
  } catch (e) {
    logErr('session log write failed', e.message);
  }
  if (process.env.BRIDGE_SUPABASE_URL && process.env.BRIDGE_SUPABASE_KEY) {
    try {
      const r = await fetch(`${process.env.BRIDGE_SUPABASE_URL}/rest/v1/session_logs`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': process.env.BRIDGE_SUPABASE_KEY,
          'Authorization': `Bearer ${process.env.BRIDGE_SUPABASE_KEY}`,
          'Prefer': 'return=minimal',
        },
        body: JSON.stringify(summary),
      });
      if (!r.ok) logErr('supabase session_logs POST', r.status, await r.text());
    } catch (e) {
      logErr('supabase session log failed', e.message);
    }
  }
  wsSend(ws, { type: 'session_ended', session_id: state.sessionId });
  try { ws.close(); } catch {}
}

const app = express();
app.use(express.json({ limit: '1mb' }));

app.post('/message', (req, res) => {
  const { message } = req.body || {};
  if (!message || typeof message !== 'string') {
    return res.status(400).json({ error: 'message must be a non-empty string' });
  }
  state.requestCount++;
  state.queue.push({ message, res });
  processQueue();
});

app.get('/health', (_req, res) => {
  res.json({
    ok: state.ready && state.authOk !== false,
    auth_ok: state.authOk,
    session_alive: state.proc != null,
    session_ready: state.ready,
    session_id: state.sessionId,
    session_uptime_ms: state.sessionStartTime ? Date.now() - state.sessionStartTime : null,
    bridge_uptime_ms: Date.now() - state.bootTime,
    queue_length: state.queue.length,
    in_flight: state.inFlight != null,
    request_count: state.requestCount,
    respawn_count: state.respawnCount,
    last_error: state.lastError,
    ws_clients: state.wsClients.size,
  });
});

const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws, req) => {
  state.wsClients.add(ws);
  log(`ws connected (${state.wsClients.size} total) from ${req.socket.remoteAddress}`);

  if (state.ready && state.authOk !== false) {
    wsSend(ws, { type: 'ready', session_id: state.sessionId });
  }

  ws.on('message', (data) => {
    let msg;
    try { msg = JSON.parse(data.toString()); } catch {
      wsSend(ws, { type: 'error', message: 'invalid JSON' });
      return;
    }

    if (msg.type === 'ping') { wsSend(ws, { type: 'pong' }); return; }

    if (msg.type === 'message') {
      if (!msg.content || typeof msg.content !== 'string') {
        wsSend(ws, { type: 'error', message: 'content must be a non-empty string' });
        return;
      }
      if (!state.ready || state.authOk === false) {
        wsSend(ws, { type: 'error', message: 'session not ready', detail: state.lastError });
        return;
      }
      state.requestCount++;
      state.queue.push({ message: msg.content, ws });
      processQueue();
      return;
    }

    if (msg.type === 'end_session') {
      handleEndSession(ws);
      return;
    }

    wsSend(ws, { type: 'error', message: `unknown message type: ${msg.type}` });
  });

  ws.on('close', () => {
    state.wsClients.delete(ws);
    log(`ws disconnected (${state.wsClients.size} remain)`);
  });

  ws.on('error', (err) => {
    logErr('ws error', err.message);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  log(`agent bridge listening on 0.0.0.0:${PORT} (http + ws)`);
  log(`claude binary: ${CLAUDE_PATH}`);
  log(`cwd for claude sessions: ${CLAUDE_CWD}`);
  runAuthCheck(() => {
    if (state.authOk) {
      startClaude();
    } else {
      logErr('BRIDGE: not starting persistent session — auth failed. Fix auth then restart pm2.');
    }
  });
});
