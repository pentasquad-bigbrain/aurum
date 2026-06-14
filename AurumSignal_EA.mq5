//+------------------------------------------------------------------+
//| AurumSignal EA — Auto-trades from Aurum Signal backend           |
//| Polls https://aurum-bqno.onrender.com/latest-signal every 30s   |
//+------------------------------------------------------------------+
#property copyright "Aurum Signal"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

// ── Inputs ────────────────────────────────────────────────────────
input string   BackendURL      = "https://aurum-bqno.onrender.com/latest-signal";
input int      PollSeconds     = 30;          // how often to check for new signal
input double   LotSize         = 0.01;        // trade size
input int      Slippage        = 20;          // max slippage in points
input bool     TradeOnBUY      = true;        // execute BUY signals
input bool     TradeOnSELL     = true;        // execute SELL signals
input int      MinConfidence   = 70;          // ignore signals below this %
input bool     CloseOnOpposite = true;        // close open trade if opposite signal
input bool     EnableTrading   = false;       // SAFETY: must set TRUE to trade live

// ── Globals ───────────────────────────────────────────────────────
CTrade         trade;
CPositionInfo  posInfo;
datetime       lastSignalTime  = 0;
string         lastSignalType  = "";
datetime       lastPollTime    = 0;

//+------------------------------------------------------------------+
//| Expert init                                                       |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(20260001);
   trade.SetDeviationInPoints(Slippage);

   // MT5 must allow WebRequest for the backend domain
   // Go to: Tools → Options → Expert Advisors → Allow WebRequest for listed URLs
   // Add: https://aurum-bqno.onrender.com

   Print("AurumSignal EA started. Trading: ", EnableTrading ? "LIVE" : "DISABLED (set EnableTrading=true)");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
   if (TimeCurrent() - lastPollTime < PollSeconds) return;
   lastPollTime = TimeCurrent();
   PollSignal();
}

//+------------------------------------------------------------------+
//| Poll backend for latest signal                                    |
//+------------------------------------------------------------------+
void PollSignal() {
   char   post[];
   char   result[];
   string headers;

   string reqHeaders = "Content-Type: application/json\r\n";
   int    timeout    = 5000; // 5 seconds

   int res = WebRequest("GET", BackendURL, reqHeaders, timeout, post, result, headers);

   if (res == -1) {
      int err = GetLastError();
      Print("WebRequest failed. Error: ", err,
            " — Did you add the URL in Tools→Options→Expert Advisors?");
      return;
   }

   string json = CharArrayToString(result);
   // Print("Raw signal: ", json); // uncomment for debugging

   // ── Parse JSON fields ──────────────────────────────────────────
   string signalType  = ExtractString(json, "signal");
   string generatedAt = ExtractString(json, "generated_at");
   int    confidence  = (int)ExtractDouble(json, "confidence");
   double entry       = ExtractDouble(json, "entry");
   double sl          = ExtractDouble(json, "sl");
   double tp          = ExtractDouble(json, "tp");

   if (signalType == "") { Print("Could not parse signal JSON"); return; }

   // ── Deduplicate — skip if same timestamp ───────────────────────
   datetime sigTime = StringToTime(generatedAt);
   if (sigTime == lastSignalTime) return;
   lastSignalTime = sigTime;

   Print("══ New Signal ══ ", signalType, " | ", confidence, "% | Entry:", entry,
         " SL:", sl, " TP:", tp, " | ", generatedAt);

   // ── Confidence filter ──────────────────────────────────────────
   if (confidence < MinConfidence) {
      Print("Signal confidence ", confidence, "% below threshold ", MinConfidence, "% — skipping");
      return;
   }

   if (!EnableTrading) {
      Print("EnableTrading=false — signal received but not executed");
      return;
   }

   // ── Execute ────────────────────────────────────────────────────
   if (signalType == "BUY"  && TradeOnBUY)  ExecuteBuy(sl, tp);
   if (signalType == "SELL" && TradeOnSELL) ExecuteSell(sl, tp);
   if (signalType == "WAIT") {
      Print("WAIT signal — no trade action");
   }
}

//+------------------------------------------------------------------+
//| Open BUY                                                          |
//+------------------------------------------------------------------+
void ExecuteBuy(double sl, double tp) {
   // Close any open SELL first
   if (CloseOnOpposite) ClosePositions(POSITION_TYPE_SELL);

   if (posInfo.SelectByMagic(_Symbol, 20260001)) {
      if (posInfo.PositionType() == POSITION_TYPE_BUY) {
         Print("BUY already open — skipping duplicate");
         return;
      }
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   bool ok = trade.Buy(LotSize, _Symbol, ask, sl, tp, "AurumSignal BUY");
   if (ok) Print("BUY opened at ", ask, " SL:", sl, " TP:", tp);
   else    Print("BUY failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Open SELL                                                         |
//+------------------------------------------------------------------+
void ExecuteSell(double sl, double tp) {
   if (CloseOnOpposite) ClosePositions(POSITION_TYPE_BUY);

   if (posInfo.SelectByMagic(_Symbol, 20260001)) {
      if (posInfo.PositionType() == POSITION_TYPE_SELL) {
         Print("SELL already open — skipping duplicate");
         return;
      }
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok = trade.Sell(LotSize, _Symbol, bid, sl, tp, "AurumSignal SELL");
   if (ok) Print("SELL opened at ", bid, " SL:", sl, " TP:", tp);
   else    Print("SELL failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Close all positions of a given type                               |
//+------------------------------------------------------------------+
void ClosePositions(ENUM_POSITION_TYPE type) {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (posInfo.SelectByIndex(i)) {
         if (posInfo.Symbol() == _Symbol &&
             posInfo.Magic()  == 20260001 &&
             posInfo.PositionType() == type) {
            trade.PositionClose(posInfo.Ticket());
            Print("Closed position #", posInfo.Ticket());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Simple JSON string extractor                                      |
//+------------------------------------------------------------------+
string ExtractString(string json, string key) {
   string search = "\"" + key + "\":\"";
   int start = StringFind(json, search);
   if (start == -1) return "";
   start += StringLen(search);
   int end = StringFind(json, "\"", start);
   if (end == -1) return "";
   return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| Simple JSON number extractor                                      |
//+------------------------------------------------------------------+
double ExtractDouble(string json, string key) {
   string search = "\"" + key + "\":";
   int start = StringFind(json, search);
   if (start == -1) return 0;
   start += StringLen(search);
   // skip any quote character (for string numbers)
   if (StringSubstr(json, start, 1) == "\"") start++;
   string num = "";
   for (int i = start; i < start + 20; i++) {
      string c = StringSubstr(json, i, 1);
      if (c == "," || c == "}" || c == "\"" || c == " ") break;
      num += c;
   }
   return StringToDouble(num);
}
//+------------------------------------------------------------------+
