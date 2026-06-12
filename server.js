cat > /home/claude/server-final.js << 'JSEOF'
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

// Preflight for all routes
app.options('*', cors());

// ── CONFIG ────────────────────────────────────────────────────────────────────
const CLAUDE_API_KEY = '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';
const FINNHUB_API_KEY = 'd8lurc1r01qnkjl91p60d8lurc1r01qnkjl91p6g';
const FINNHUB_WS = 'wss://ws.finnhub.io?token=' + FINNHUB_API_KEY;
const MAX_CANDLES = 150;
const PORT = process.env.PORT || 8080;

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
    console.log('[Finnhub] ✓ Connected');
    ws.send(JSON.stringify({ type: 'subscribe', symbol: 'XAUUSD' }));
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
              console.log(`[Finnhub] Candle closed: ${currentCandle.close.toFixed(2)}`);
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
    console.log('[Finnhub] Closed. Reconnecting...');
    if (reconnectAttempts < MAX_RECONNECT) {
      reconnectAttempts++;
      setTimeout(connectFinnhub, 3000 * reconnectAttempts);
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
      error: 'Waiting for Finnhub data',
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
      return res.status(400).json({ error: 'No messages' });
    }

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
      return res.status(response.status).json(data);
    }

    res.json(data);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /health
app.get('/health', (req, res) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.json({
    status: 'ok',
    service: 'AURUM SIGNAL Backend',
    candles: candles.length + (currentCandle ? 1 : 0),
    finnhub: candles.length > 0 ? 'connected' : 'connecting',
    timestamp: Date.now()
  });
});

// GET /
app.get('/', (req, res) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.json({ status: 'AURUM SIGNAL Backend Running' });
});

// ── SERVER ────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`\n[Server] AURUM SIGNAL Backend`);
  console.log(`[Server] Running on port ${PORT}`);
  console.log(`[Server] CORS enabled for all origins\n`);
  connectFinnhub();
});

process.on('SIGINT', () => {
  if (ws) ws.close();
  process.exit(0);
});
JSEOF
cp /home/claude/server-final.js /mnt/user-data/outputs/server-final.js
echo "✓ Final server created with aggressive CORS"