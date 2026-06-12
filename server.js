const express = require('express');
const WebSocket = require('ws');
const fetch = require('node-fetch');
const cors = require('cors');

const app = express();

// ── AGGRESSIVE CORS ──────────────────────────────────────────────────────────
app.use(cors({
  origin: '*',
  credentials: false,
  methods: ['GET', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type']
}));

app.use(express.json());
app.options('*', cors());

// ── CONFIG FROM ENVIRONMENT ──────────────────────────────────────────────────
const CLAUDE_API_KEY = process.env.CLAUDE_API_KEY;
const FINNHUB_API_KEY = process.env.FINNHUB_API_KEY;
const FINNHUB_WS = 'wss://ws.finnhub.io?token=' + FINNHUB_API_KEY;
const MAX_CANDLES = 150;
const PORT = process.env.PORT || 8080;

// Validate environment variables
if (!CLAUDE_API_KEY) {
  console.error('[Error] CLAUDE_API_KEY environment variable not set');
  process.exit(1);
}
if (!FINNHUB_API_KEY) {
  console.error('[Error] FINNHUB_API_KEY environment variable not set');
  process.exit(1);
}

console.log('[Config] CLAUDE_API_KEY loaded ✓');
console.log('[Config] FINNHUB_API_KEY loaded ✓');

// ── STATE ─────────────────────────────────────────────────────────────────────
let candles = [];
let ws = null;
let reconnectAttempts = 0;
const MAX_RECONNECT = 5;
let currentCandle = null;
let lastTickTime = 0;

// ── FINNHUB WEBSOCKET ─────────────────────────────────────────────────────────
function connectFinnhub() {
  console.log('[Finnhub] Connecting...');
  
  ws = new WebSocket(FINNHUB_WS);
  
  ws.on('open', () => {
    console.log('[Finnhub] ✓ Connected to WebSocket');
    ws.send(JSON.stringify({ type: 'subscribe', symbol: 'XAUUSD' }));
    console.log('[Finnhub] ✓ Subscribed to XAUUSD');
    reconnectAttempts = 0;
  });

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data);
      
      if (msg.type === 'trade' && msg.data && Array.isArray(msg.data)) {
        msg.data.forEach(trade => {
          const price = trade.p;
          const time = trade.t;
          const minuteBucket = Math.floor(time / 60000) * 60000;
          
          if (!currentCandle || Math.floor(currentCandle.time / 60000) !== Math.floor(minuteBucket / 60000)) {
            if (currentCandle) {
              candles.push(currentCandle);
              if (candles.length > MAX_CANDLES) candles.shift();
              console.log(`[Finnhub] Candle: ${new Date(currentCandle.time).toLocaleTimeString()} | Close: ${currentCandle.close.toFixed(2)}`);
            }
            currentCandle = {
              time: minuteBucket,
              open: price,
              high: price,
              low: price,
              close: price,
              volume: 1
            };
          } else {
            currentCandle.close = price;
            currentCandle.high = Math.max(currentCandle.high, price);
            currentCandle.low = Math.min(currentCandle.low, price);
            currentCandle.volume += 1;
          }
          lastTickTime = Date.now();
        });
      }
    } catch (err) {
      console.error('[Finnhub] Parse error:', err.message);
    }
  });

  ws.on('error', (err) => {
    console.error('[Finnhub] Error:', err.message);
  });

  ws.on('close', () => {
    console.log('[Finnhub] Closed. Reconnecting in 3 seconds...');
    if (reconnectAttempts < MAX_RECONNECT) {
      reconnectAttempts++;
      setTimeout(connectFinnhub, 3000 * reconnectAttempts);
    } else {
      console.error('[Finnhub] Max reconnection attempts reached');
    }
  });
}

// ── API ENDPOINTS ─────────────────────────────────────────────────────────────

// GET /candles
app.get('/candles', (req, res) => {
  const allCandles = [...candles];
  if (currentCandle) allCandles.push(currentCandle);
  
  res.header('Content-Type', 'application/json');
  res.header('Access-Control-Allow-Origin', '*');
  
  if (allCandles.length === 0) {
    return res.status(503).json({ 
      error: 'Waiting for Finnhub data. May take 10-30 seconds.',
      status: 'initializing',
      candles: []
    });
  }
  
  res.json({ 
    candles: allCandles, 
    count: allCandles.length, 
    timestamp: Date.now()
  });
});

// POST /signal
app.post('/signal', async (req, res) => {
  try {
    const { model, max_tokens, messages } = req.body;
    
    if (!messages || !messages.length) {
      return res.status(400).json({ error: 'No messages provided' });
    }

    console.log('[Claude] Sending signal request...');

    const response = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': CLAUDE_API_KEY,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: model || 'claude-haiku-4-5',
        max_tokens: max_tokens || 1000,
        messages
      })
    });

    const data = await response.json();
    res.header('Access-Control-Allow-Origin', '*');
    
    if (!response.ok) {
      console.error('[Claude] API error:', data);
      return res.status(response.status).json(data);
    }

    console.log('[Claude] ✓ Signal generated');
    res.json(data);
  } catch (err) {
    console.error('[Claude] Error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// GET /health
app.get('/health', (req, res) => {
  res.header('Access-Control-Allow-Origin', '*');
  const total = candles.length + (currentCandle ? 1 : 0);
  res.json({
    status: 'ok',
    service: 'AURUM SIGNAL Backend',
    candles: total,
    finnhub: total > 0 ? 'connected' : 'connecting',
    latestPrice: total > 0 ? candles[candles.length - 1]?.close : null,
    timestamp: Date.now()
  });
});

// GET /
app.get('/', (req, res) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.json({ 
    status: 'ok',
    service: 'AURUM SIGNAL Backend',
    endpoints: ['/candles', '/signal', '/health']
  });
});

// ── SERVER ────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`\n╔════════════════════════════════════════╗`);
  console.log(`║   AURUM SIGNAL Backend (Environment)   ║`);
  console.log(`║   Port: ${PORT}                              ║`);
  console.log(`║   CORS: Enabled for all origins        ║`);
  console.log(`╚════════════════════════════════════════╝\n`);
  connectFinnhub();
});

process.on('SIGINT', () => {
  console.log('\n[Server] Shutting down...');
  if (ws) ws.close();
  process.exit(0);
});
