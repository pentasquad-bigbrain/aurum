const express = require('express');
const WebSocket = require('ws');
const fetch = require('node-fetch');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

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
  console.log('🔌 Connecting to Finnhub WebSocket...');
  
  ws = new WebSocket(FINNHUB_WS);
  
  ws.on('open', () => {
    console.log('✓ Connected to Finnhub WebSocket');
    // Subscribe to XAUUSD (Commodities)
    ws.send(JSON.stringify({ type: 'subscribe', symbol: 'XAUUSD' }));
    reconnectAttempts = 0;
  });

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data);
      
      // Finnhub sends trade data with structure: { type: 'trade', data: [ { s, p, t, v }, ... ] }
      if (msg.type === 'trade' && msg.data && Array.isArray(msg.data)) {
        msg.data.forEach(trade => {
          const price = trade.p; // price
          const time = trade.t; // timestamp in milliseconds
          
          // Current minute bucket
          const minuteBucket = Math.floor(time / 60000) * 60000;
          
          // Initialize new candle if needed
          if (!currentCandle || Math.floor(currentCandle.time / 60000) !== Math.floor(minuteBucket / 60000)) {
            // Save previous candle if exists
            if (currentCandle) {
              candles.push(currentCandle);
              if (candles.length > MAX_CANDLES) {
                candles.shift();
              }
              console.log(`✓ [${new Date(currentCandle.time).toLocaleTimeString()}] XAU/USD: ${currentCandle.close.toFixed(2)} | Open: ${currentCandle.open.toFixed(2)} | High: ${currentCandle.high.toFixed(2)} | Low: ${currentCandle.low.toFixed(2)}`);
            }
            
            // Start new candle
            currentCandle = {
              time: minuteBucket,
              open: price,
              high: price,
              low: price,
              close: price,
              volume: 1
            };
          } else {
            // Update current candle
            currentCandle.close = price;
            currentCandle.high = Math.max(currentCandle.high, price);
            currentCandle.low = Math.min(currentCandle.low, price);
            currentCandle.volume += 1;
          }
          
          lastTickTime = Date.now();
        });
      }
    } catch (err) {
      console.error('Error parsing Finnhub message:', err.message);
    }
  });

  ws.on('error', (err) => {
    console.error('WebSocket error:', err.message);
  });

  ws.on('close', () => {
    console.log('⚠ WebSocket closed. Attempting reconnect...');
    if (reconnectAttempts < MAX_RECONNECT) {
      reconnectAttempts++;
      setTimeout(connectFinnhub, 3000 * reconnectAttempts);
    } else {
      console.error('❌ Max reconnect attempts reached.');
    }
  });
}

// ── API ENDPOINTS ─────────────────────────────────────────────────────────────

// GET /candles - Return latest candles
app.get('/candles', (req, res) => {
  // Include current candle in response
  const allCandles = [...candles];
  if (currentCandle) {
    allCandles.push(currentCandle);
  }
  
  if (allCandles.length === 0) {
    return res.status(503).json({ 
      error: 'Waiting for Finnhub live data. May take 10-30 seconds.',
      status: 'initializing',
      candles: []
    });
  }
  
  res.json({ 
    candles: allCandles, 
    count: allCandles.length, 
    timestamp: Date.now(),
    lastTick: lastTickTime
  });
});

// POST /signal - Proxy Claude API call
app.post('/signal', async (req, res) => {
  try {
    const { model, max_tokens, messages } = req.body;
    
    if (!messages || !messages.length) {
      return res.status(400).json({ error: 'No messages provided' });
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
    
    if (!response.ok) {
      console.error('Claude API error:', data);
      return res.status(response.status).json(data);
    }

    res.json(data);
  } catch (err) {
    console.error('Signal endpoint error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// GET /health - Health check
app.get('/health', (req, res) => {
  const allCandles = [...candles];
  if (currentCandle) {
    allCandles.push(currentCandle);
  }
  
  const status = allCandles.length > 0 ? 'live' : 'initializing';
  res.json({
    status: 'ok',
    finnhub: status,
    candles: allCandles.length,
    latestPrice: allCandles.length > 0 ? allCandles[allCandles.length - 1].close : null,
    lastTick: lastTickTime,
    timestamp: Date.now()
  });
});

// GET / - Root endpoint
app.get('/', (req, res) => {
  res.json({
    service: 'AURUM SIGNAL Backend (Finnhub WebSocket)',
    endpoints: {
      'GET /health': 'Health check',
      'GET /candles': 'Get live candles from Finnhub',
      'POST /signal': 'Send prompt to Claude AI'
    },
    status: 'Connected to Finnhub for real-time XAUUSD'
  });
});

// ── SERVER ────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`\n╔════════════════════════════════════════╗`);
  console.log(`║   AURUM SIGNAL Backend (Finnhub)      ║`);
  console.log(`║   Listening on port ${PORT}                ║`);
  console.log(`║   Real-time XAUUSD WebSocket          ║`);
  console.log(`╚════════════════════════════════════════╝\n`);
  connectFinnhub();
});

process.on('SIGINT', () => {
  console.log('\nShutting down...');
  if (ws) ws.close();
  process.exit(0);
});