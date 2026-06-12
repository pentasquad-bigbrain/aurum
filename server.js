const express = require('express');
const WebSocket = require('ws');
const fetch = require('node-fetch');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

// ── CONFIG ────────────────────────────────────────────────────────────────────
const CLAUDE_API_KEY = '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';
const BINANCE_WS = 'wss://stream.binance.com:9443/ws/xauusdtm@kline_1m'; // Binance Futures 1m candles
const MAX_CANDLES = 150;
const PORT = process.env.PORT || 8080;

// ── STATE ─────────────────────────────────────────────────────────────────────
let candles = [];
let ws = null;
let reconnectAttempts = 0;
const MAX_RECONNECT = 5;

// ── BINANCE WEBSOCKET ─────────────────────────────────────────────────────────
function connectBinance() {
  console.log('Connecting to Binance WebSocket...');
  
  ws = new WebSocket(BINANCE_WS);
  
  ws.on('open', () => {
    console.log('✓ Connected to Binance WebSocket');
    reconnectAttempts = 0;
  });

  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data);
      const k = msg.k; // kline object
      
      // Only process closed candles
      if (k.x === true) {
        const candle = {
          time: k.t, // milliseconds
          open: parseFloat(k.o),
          high: parseFloat(k.h),
          low: parseFloat(k.l),
          close: parseFloat(k.c),
          volume: parseFloat(k.v)
        };
        
        candles.push(candle);
        if (candles.length > MAX_CANDLES) {
          candles.shift();
        }
        
        console.log(`[${new Date().toLocaleTimeString()}] XAU/USD: ${candle.close.toFixed(2)}`);
      }
    } catch (err) {
      console.error('Error parsing Binance message:', err.message);
    }
  });

  ws.on('error', (err) => {
    console.error('WebSocket error:', err.message);
  });

  ws.on('close', () => {
    console.log('WebSocket closed. Attempting reconnect...');
    if (reconnectAttempts < MAX_RECONNECT) {
      reconnectAttempts++;
      setTimeout(connectBinance, 3000 * reconnectAttempts);
    } else {
      console.error('Max reconnect attempts reached.');
    }
  });
}

// ── API ENDPOINTS ─────────────────────────────────────────────────────────────

// GET /candles - Return latest candles
app.get('/candles', (req, res) => {
  if (candles.length === 0) {
    return res.status(503).json({ error: 'No candle data yet. Waiting for Binance connection...' });
  }
  res.json({ candles, count: candles.length, timestamp: Date.now() });
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
  const status = ws && ws.readyState === WebSocket.OPEN ? 'connected' : 'disconnected';
  res.json({
    status: 'ok',
    binance: status,
    candles: candles.length,
    latestPrice: candles.length > 0 ? candles[candles.length - 1].close : null,
    timestamp: Date.now()
  });
});

// GET / - Root endpoint
app.get('/', (req, res) => {
  res.json({
    service: 'AURUM SIGNAL Backend',
    endpoints: {
      'GET /health': 'Health check',
      'GET /candles': 'Get latest 150 candles from Binance',
      'POST /signal': 'Send prompt to Claude AI'
    }
  });
});

// ── SERVER ────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`\n╔══════════════════════════════════════╗`);
  console.log(`║   AURUM SIGNAL Backend Server        ║`);
  console.log(`║   Listening on port ${PORT}              ║`);
  console.log(`╚══════════════════════════════════════╝\n`);
  connectBinance();
});

process.on('SIGINT', () => {
  console.log('\nShutting down...');
  if (ws) ws.close();
  process.exit(0);
});
