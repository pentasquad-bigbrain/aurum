const express = require('express');
const cors = require('cors');
const WebSocket = require('ws');
const fetch = require('node-fetch');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors({ origin: '*' }));
app.use(express.json({ limit: '1mb' }));

const FINNHUB_API_KEY = process.env.FINNHUB_API_KEY;
const CLAUDE_API_KEY = process.env.CLAUDE_API_KEY;

// ── Candle state ──────────────────────────────────────────────────────────────
const BUFFER_SIZE = 200;
let candles = [];
let currentCandle = null;
let lastPrice = null;
let lastTickTime = null;
let finnhubConnected = false;

function minuteTs(ms) {
  return Math.floor(ms / 60000) * 60;
}

function processTick(price, timestamp, volume) {
  lastPrice = price;
  lastTickTime = Date.now();

  const ts = minuteTs(timestamp);

  if (!currentCandle) {
    currentCandle = { time: ts, open: price, high: price, low: price, close: price, volume: volume || 0 };
    return;
  }

  if (ts > currentCandle.time) {
    // Close the finished candle
    candles.push({ ...currentCandle });
    if (candles.length > BUFFER_SIZE) candles.shift();
    console.log(
      `[Candle] ${new Date(currentCandle.time * 1000).toISOString().slice(11, 16)}` +
      `  O:${currentCandle.open.toFixed(2)} H:${currentCandle.high.toFixed(2)}` +
      `  L:${currentCandle.low.toFixed(2)} C:${currentCandle.close.toFixed(2)}` +
      `  | buffer: ${candles.length}`
    );
    // Open new candle
    currentCandle = { time: ts, open: price, high: price, low: price, close: price, volume: volume || 0 };
  } else {
    currentCandle.high = Math.max(currentCandle.high, price);
    currentCandle.low = Math.min(currentCandle.low, price);
    currentCandle.close = price;
    currentCandle.volume += (volume || 0);
  }
}

// ── Finnhub WebSocket ─────────────────────────────────────────────────────────
let ws = null;
let reconnectTimer = null;

function connectFinnhub() {
  if (!FINNHUB_API_KEY) {
    console.error('[Finnhub] FINNHUB_API_KEY not set — cannot connect');
    return;
  }

  clearTimeout(reconnectTimer);

  console.log('[Finnhub] Connecting to wss://ws.finnhub.io...');
  ws = new WebSocket(`wss://ws.finnhub.io?token=${FINNHUB_API_KEY}`);

  ws.on('open', () => {
    finnhubConnected = true;
    console.log('[Finnhub] Connected. Subscribing to OANDA:XAU_USD...');
    ws.send(JSON.stringify({ type: 'subscribe', symbol: 'OANDA:XAU_USD' }));
  });

  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      if (msg.type === 'trade' && Array.isArray(msg.data)) {
        for (const t of msg.data) {
          processTick(t.p, t.t, t.v);
        }
      } else if (msg.type === 'ping') {
        ws.send(JSON.stringify({ type: 'pong' }));
      }
    } catch (e) {
      console.error('[Finnhub] Parse error:', e.message);
    }
  });

  ws.on('close', (code, reason) => {
    finnhubConnected = false;
    console.log(`[Finnhub] Disconnected (code ${code}). Reconnecting in 5s...`);
    reconnectTimer = setTimeout(connectFinnhub, 5000);
  });

  ws.on('error', (err) => {
    finnhubConnected = false;
    console.error('[Finnhub] WebSocket error:', err.message);
  });
}

// ── Routes ────────────────────────────────────────────────────────────────────
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    finnhub_connected: finnhubConnected,
    candles_count: candles.length,
    last_price: lastPrice,
    last_tick_age_ms: lastTickTime ? Date.now() - lastTickTime : null,
    current_candle: currentCandle,
    timestamp: new Date().toISOString()
  });
});

app.get('/candles', (req, res) => {
  const result = [...candles];
  if (currentCandle) result.push({ ...currentCandle });

  res.json({
    candles: result,
    count: result.length,
    last_price: lastPrice,
    finnhub_connected: finnhubConnected,
    timestamp: new Date().toISOString()
  });
});

app.post('/signal', async (req, res) => {
  try {
    const { prompt } = req.body;
    if (!prompt) return res.status(400).json({ error: 'prompt is required' });
    if (!CLAUDE_API_KEY) return res.status(500).json({ error: 'CLAUDE_API_KEY not configured' });

    console.log('[Signal] Calling Claude API...');

    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': CLAUDE_API_KEY,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: 'claude-haiku-4-5-20251001',
        max_tokens: 600,
        messages: [{ role: 'user', content: prompt }]
      })
    });

    const body = await response.text();

    if (!response.ok) {
      console.error('[Signal] Claude API error:', body);
      return res.status(response.status).json({ error: 'Claude API error', details: body });
    }

    const data = JSON.parse(body);
    const text = data.content[0].text;
    console.log('[Signal] Raw Claude response:', text.slice(0, 200));

    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      return res.status(500).json({ error: 'No JSON in Claude response', raw: text });
    }

    const signal = JSON.parse(jsonMatch[0]);
    console.log(`[Signal] ${signal.signal} ${signal.confidence}% | entry:${signal.entry} sl:${signal.sl} tp:${signal.tp}`);
    res.json(signal);

  } catch (e) {
    console.error('[Signal] Error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`\n╔══════════════════════════════════════╗`);
  console.log(`║   AURUM SIGNAL Backend  port:${PORT}    ║`);
  console.log(`╚══════════════════════════════════════╝\n`);

  if (!FINNHUB_API_KEY) {
    console.error('[Server] WARNING: FINNHUB_API_KEY not set');
  }
  if (!CLAUDE_API_KEY) {
    console.error('[Server] WARNING: CLAUDE_API_KEY not set');
  }

  connectFinnhub();
});
