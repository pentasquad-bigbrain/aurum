//+------------------------------------------------------------------+
//|  AurumSignal Pro EA  v3.0                                        |
//|  Dynamic lots · Basket · Recovery · Trailing · Equity Guard      |
//|  Breakeven · Profit Lock · Chart Panel · Rapid Scalp Mode        |
//+------------------------------------------------------------------+
#property copyright "Aurum Signal"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo pos;

//────────────────────────────────────────────────────────────────────
//  INPUTS
//────────────────────────────────────────────────────────────────────
input group "━━━  SIGNAL SOURCE  ━━━"
input string  BackendURL          = "https://aurum-bqno.onrender.com/latest-signal";
input int     PollSeconds         = 30;
input int     MinConfidence       = 70;
input bool    TradeOnBUY          = true;
input bool    TradeOnSELL         = true;
input bool    EnableTrading       = false;   // ⚠ MUST SET TRUE TO GO LIVE

input group "━━━  MONEY MANAGEMENT  ━━━"
input bool    DynamicLots         = true;
input double  RiskPercent         = 1.0;
input double  FixedLot            = 0.01;
input double  MaxLot              = 5.0;
input double  MinLot              = 0.01;

input group "━━━  BASKET  ━━━"
input bool    BasketMode          = true;
input int     MaxBasketTrades     = 5;
input double  BasketTP            = 50.0;
input double  BasketSL            = -30.0;

input group "━━━  RECOVERY  ━━━"
input bool    RecoveryMode        = false;
input double  RecoveryTrigger     = -15.0;
input double  RecoveryMult        = 1.5;
input int     MaxRecoveryLevels   = 3;

input group "━━━  SL / TRAILING / PROFIT LOCK  ━━━"
input bool    UseATRStop          = true;
input int     ATRPeriod           = 14;
input double  ATRMultiplier       = 1.5;
input bool    UseBreakEven        = true;
input double  BreakEvenPips       = 15.0;    // move SL to BE after X pips profit
input double  BreakEvenBuffer     = 2.0;     // lock BE + X extra pips
input bool    UseTrailing         = true;
input double  TrailStartPips      = 25.0;
input double  TrailStepPips       = 10.0;
input bool    UseProfitLock       = true;
input double  ProfitLockTriggerPct= 75.0;    // when trade reaches X% of TP distance...
input double  ProfitLockBufferPct = 40.0;    // ...lock in X% of TP distance as SL

input group "━━━  EQUITY PROTECTION  ━━━"
input bool    EquityGuard         = true;
input double  MaxDailyLossPct     = 3.0;
input double  MaxDrawdownPct      = 5.0;
input int     MaxOpenTrades       = 3;
input double  MinEquity           = 50.0;

input group "━━━  RAPID SCALP MODE  ━━━"
input int     ScalpMinConfidence  = 85;
input double  ScalpTPPips         = 8.0;
input double  ScalpSLPips         = 6.0;
input double  ScalpLotMultiplier  = 0.5;
input int     ScalpMaxTrades      = 3;
input int     ScalpPollSeconds    = 10;

input group "━━━  TRADE SAFETY  ━━━"
input int     MinGapAfterCloseMins = 5;      // min minutes to wait after any trade closes
input int     MaxTradesPerHour     = 4;      // hard cap on trades opened per hour
input int     MaxConsecLosses      = 3;      // pause X mins after N consecutive losses
input int     ConsecLossPauseMins  = 30;     // how long to pause after MaxConsecLosses
// IST trading window — hard wall, no signals outside this
input int     SessionStartIST_H   = 15;     // session open hour   IST (15 = 3pm)
input int     SessionStartIST_M   = 25;     // session open minute IST (25)
input int     SessionEndIST_H     = 21;     // session close hour  IST (21 = 9pm)
input int     SessionEndIST_M     = 30;     // session close minute IST (30)
// ADX filter — reject ranging markets at EA level regardless of LLM output
input double  MinADXToTrade       = 20.0;   // reject if ADX below this

//────────────────────────────────────────────────────────────────────
//  GLOBALS
//────────────────────────────────────────────────────────────────────
const int  MAGIC          = 20260003;
datetime   lastPollTime   = 0;
datetime   lastSigTime    = 0;
double     dayOpenEquity  = 0;
bool       tradingHalted  = false;
bool       scalpMode      = false;
int        atrHandle      = INVALID_HANDLE;
int        adxHandle      = INVALID_HANDLE;
string     lastSigType    = "";
int        lastSigConf    = 0;
int        lastTradeCount = 0;

// Panel object prefix
const string PFX = "AP_";

struct RecoveryTrack  { ulong ticket; int level; double lastLot; };
struct TradeSignalTag { ulong ticket; string genAt; string sigType; int conf; };
RecoveryTrack  recoveryMap[];
TradeSignalTag tradeTagMap[];   // maps open ticket → signal that triggered it

//── Trade Safety ─────────────────────────────────────────────────────
datetime   lastTradeCloseTime  = 0;   // when last trade closed
int        tradesThisHour      = 0;   // counter reset every hour
datetime   lastHourReset       = 0;   // timestamp of last hourly reset
datetime   pauseUntil          = 0;   // consecutive loss pause ends at

//── Win/Loss Tracker ─────────────────────────────────────────────────
int    statTotal       = 0;
int    statWins        = 0;
int    statLoss        = 0;
double statTotalPL     = 0.0;
double statBestTrade   = 0.0;
double statWorstTrade  = 0.0;
int    statConsecWins  = 0;   // max consecutive wins ever
int    statConsecLoss  = 0;   // max consecutive losses ever
int    statStreak      = 0;   // current streak (+ve=wins, -ve=losses)
int    statTodayTrades = 0;
double statTodayPL     = 0.0;
datetime statTodayDate = 0;

//────────────────────────────────────────────────────────────────────
//  INIT / DEINIT
//────────────────────────────────────────────────────────────────────
int OnInit() {
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   dayOpenEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   lastTradeCount = CountOurTrades();
   atrHandle = iATR(_Symbol, PERIOD_M1, ATRPeriod);
   if (atrHandle == INVALID_HANDLE) { Print("[Init] ATR handle failed"); return INIT_FAILED; }
   adxHandle = iADX(_Symbol, PERIOD_M1, 14);
   if (adxHandle == INVALID_HANDLE) { Print("[Init] ADX handle failed"); return INIT_FAILED; }

   LoadStats();
   CreatePanel();
   Print("AurumSignal Pro v3.0 | Trading: ", EnableTrading ? "LIVE" : "DISABLED");
   Print("[Stats] Loaded — Total:", statTotal, " W:", statWins, " L:", statLoss,
         " WR:", (statTotal > 0 ? DoubleToString((double)statWins/statTotal*100,1) : "0"), "%");
   Print("Allow WebRequest for: https://aurum-bqno.onrender.com");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   if (atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if (adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
   DeletePanel();
}

//────────────────────────────────────────────────────────────────────
//  MAIN TICK
//────────────────────────────────────────────────────────────────────
void OnTick() {
   // Daily reset
   static datetime lastDay = 0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if (today != lastDay) {
      dayOpenEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingHalted  = false;
      lastDay        = today;
      // Log yesterday's daily summary before resetting
      if (statTodayTrades > 0)
         LogDailySummary();
      statTodayTrades = 0;
      statTodayPL     = 0.0;
      statTodayDate   = today;
      Print("[Reset] New day. Equity: $", dayOpenEquity);
   }

   // Re-arm: if trades dropped to zero
   int curCount = CountOurTrades();
   if (curCount == 0 && lastTradeCount > 0) {
      lastSigTime       = 0;
      lastTradeCloseTime = TimeCurrent();
      // Do NOT reset lastPollTime — enforce MinGapAfterCloseMins before next trade
      ArrayResize(recoveryMap, 0);
      Print("[EA] Re-armed. Next trade allowed after ", MinGapAfterCloseMins, " min gap.");
   }
   lastTradeCount = curCount;

   // Hourly trade counter reset
   if (TimeCurrent() - lastHourReset >= 3600) {
      tradesThisHour = 0;
      lastHourReset  = TimeCurrent();
   }

   // Manage open trades
   ManageTrailingAndLocks();
   if (BasketMode)   ManageBasket();
   if (RecoveryMode) ManageRecovery();

   // Equity check
   if (EquityGuard && CheckEquityProtection()) {
      UpdatePanel();
      return;
   }
   if (tradingHalted) { UpdatePanel(); return; }

   // Poll signal
   int pollInterval = scalpMode ? ScalpPollSeconds : PollSeconds;
   if (TimeCurrent() - lastPollTime >= pollInterval) {
      lastPollTime = TimeCurrent();
      PollSignal();
   }

   UpdatePanel();
}

//────────────────────────────────────────────────────────────────────
//  CHART EVENTS (panel button clicks)
//────────────────────────────────────────────────────────────────────
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam) {
   if (id != CHARTEVENT_OBJECT_CLICK) return;

   if (sparam == PFX+"BTN_BUY") {
      if (EnableTrading) OpenBuy(0, 0);
      else Print("[Panel] EnableTrading=false");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   if (sparam == PFX+"BTN_SELL") {
      if (EnableTrading) OpenSell(0, 0);
      else Print("[Panel] EnableTrading=false");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   if (sparam == PFX+"BTN_CLOSE") {
      CloseAll("MANUAL PANEL");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   if (sparam == PFX+"BTN_SCALP") {
      ToggleScalpMode();
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   if (sparam == PFX+"BTN_HALT") {
      tradingHalted = !tradingHalted;
      if (tradingHalted) { CloseAll("MANUAL HALT"); Print("[Panel] Trading HALTED by user"); }
      else                Print("[Panel] Trading RESUMED by user");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   if (sparam == PFX+"BTN_RESUME") {
      tradingHalted = false;
      pauseUntil    = 0;
      lastPollTime  = 0;
      Print("[Panel] FORCE RESUME — all halts cleared, polling immediately");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   if (sparam == PFX+"BTN_RESETSTATS") {
      ResetStats();
      Print("[Stats] All stats reset by user");
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   ChartRedraw();
}

//────────────────────────────────────────────────────────────────────
//  EQUITY PROTECTION
//────────────────────────────────────────────────────────────────────
bool CheckEquityProtection() {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if (equity < MinEquity) {
      if (!tradingHalted) { CloseAll("MIN EQUITY"); tradingHalted = true;
         Print("[Guard] Equity $", equity, " below floor $", MinEquity); }
      return true;
   }
   double dailyDD = dayOpenEquity > 0 ? (dayOpenEquity - equity) / dayOpenEquity * 100.0 : 0;
   if (dailyDD >= MaxDailyLossPct) {
      if (!tradingHalted) { CloseAll("DAILY LOSS"); tradingHalted = true;
         Print("[Guard] Daily loss ", DoubleToString(dailyDD,1), "% exceeded"); }
      return true;
   }
   double dd = dayOpenEquity > 0 ? (dayOpenEquity - equity) / dayOpenEquity * 100.0 : 0;
   if (dd >= MaxDrawdownPct) {
      if (!tradingHalted) { CloseAll("MAX DRAWDOWN"); tradingHalted = true;
         Print("[Guard] Drawdown ", DoubleToString(dd,1), "% exceeded"); }
      return true;
   }
   return false;
}

//────────────────────────────────────────────────────────────────────
//  POLL SIGNAL
//────────────────────────────────────────────────────────────────────
void PollSignal() {
   char post[], result[]; string headers;
   int res = WebRequest("GET", BackendURL, "Content-Type: application/json\r\n",
                        5000, post, result, headers);
   if (res == -1) {
      Print("[Poll] ✗ WebRequest FAILED err=", GetLastError(),
            " — Go MT5 Tools→Options→Expert Advisors and add: ", BackendURL);
      return;
   }

   string json    = CharArrayToString(result);
   string sigType = ExtractStr(json, "signal");
   string genAt   = ExtractStr(json, "generated_at");
   int    conf    = (int)ExtractNum(json, "confidence");
   double sl      = ExtractNum(json, "sl");
   double tp      = ExtractNum(json, "tp");
   double entry   = ExtractNum(json, "entry");

   Print("[Poll] Response: signal=", sigType, " conf=", conf,
         " genAt=", genAt, " trades=", CountOurTrades());

   if (sigType == "") { Print("[Poll] ✗ No signal in response"); return; }

   // ← FIX: always update panel display, including for WAIT
   lastSigType = sigType;
   lastSigConf = conf;

   // Log every signal received to file
   LogSignal(sigType, conf, entry, sl, tp, genAt);

   if (sigType == "WAIT") { Print("[Poll] Signal=WAIT — no trade"); return; }

   datetime sigTime = StringToTime(genAt);

   // Only skip if: same timestamp AND positions already open from this signal
   // Zero trades → always allow re-entry regardless of timestamp
   if (sigTime != 0 && sigTime == lastSigTime && CountOurTrades() > 0) {
      Print("[Poll] Same signal already active (", genAt, ") — skip");
      return;
   }
   lastSigTime = sigTime;

   int minConf = scalpMode ? ScalpMinConfidence : MinConfidence;
   if (conf < minConf) {
      Print("[Poll] ✗ Confidence ", conf, "% < threshold ", minConf, "% — skip");
      return;
   }

   if (!EnableTrading) {
      Print("[Poll] ✗ EnableTrading=FALSE — set it to TRUE in EA inputs to go live!");
      return;
   }

   if (tradingHalted) {
      Print("[Poll] ✗ Trading halted by equity guard");
      return;
   }

   // ── Session filter ────────────────────────────────────────────
   if (!IsAllowedSession()) return;

   // ── Minimum gap after last close ──────────────────────────────
   if (lastTradeCloseTime > 0) {
      int gapSecs = (int)(TimeCurrent() - lastTradeCloseTime);
      int required = MinGapAfterCloseMins * 60;
      if (gapSecs < required) {
         Print("[Poll] ✗ Gap cooldown: ", (required-gapSecs)/60, " min remaining");
         return;
      }
   }

   // ── Consecutive loss pause ────────────────────────────────────
   if (TimeCurrent() < pauseUntil) {
      Print("[Poll] ✗ Paused after ", MaxConsecLosses, " losses. Resumes: ",
            TimeToString(pauseUntil, TIME_DATE|TIME_MINUTES));
      return;
   }

   // ── Hourly trade cap ──────────────────────────────────────────
   if (tradesThisHour >= MaxTradesPerHour) {
      Print("[Poll] ✗ Max trades/hour reached (", tradesThisHour, "/", MaxTradesPerHour, ")");
      return;
   }

   int maxTrades = scalpMode ? ScalpMaxTrades : MaxBasketTrades;
   int openNow   = CountOurTrades();
   if (openNow >= maxTrades) {
      Print("[Poll] ✗ Max trades reached (", openNow, "/", maxTrades, ")");
      return;
   }

   // ── ADX hard rejection — EA-level, ignores LLM output ────────
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   if (CopyBuffer(adxHandle, 0, 0, 1, adxBuf) > 0) {
      double adxVal = adxBuf[0];
      if (adxVal < MinADXToTrade) {
         Print("[ADX] ", DoubleToString(adxVal, 1), " < ", MinADXToTrade,
               " — ranging market, trade REJECTED regardless of signal");
         return;
      }
      Print("[ADX] ", DoubleToString(adxVal, 1), " >= ", MinADXToTrade, " — trending, OK");
   }

   Print("[Poll] ✓ Opening ", sigType, " | conf=", conf, "% | lot=auto | SL=", sl, " TP=", tp);
   tradesThisHour++;
   if (sigType == "BUY"  && TradeOnBUY)  OpenBuy(sl, tp);
   if (sigType == "SELL" && TradeOnSELL) OpenSell(sl, tp);
}

//────────────────────────────────────────────────────────────────────
//  OPEN BUY / SELL
//────────────────────────────────────────────────────────────────────
void OpenBuy(double sigSL, double sigTP) {
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pip    = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double slDist, tpDist;

   if (scalpMode) {
      slDist = ScalpSLPips * pip;
      tpDist = ScalpTPPips * pip;
   } else {
      slDist = CalcSLDistance(true, sigSL, ask);
      tpDist = (sigTP > 0) ? MathAbs(sigTP - ask) : slDist * 2.0;
   }

   double lot = CalcLot(slDist);
   if (scalpMode) lot = NormLot(lot * ScalpLotMultiplier);

   double sl = NormalizeDouble(ask - slDist, _Digits);
   double tp = NormalizeDouble(ask + tpDist, _Digits);

   string comment = scalpMode ? "AurumSignal SCALP BUY" : "AurumSignal BUY";
   Print("[BUY] Lot:", lot, " Ask:", ask, " SL:", sl, " TP:", tp, scalpMode ? " [SCALP]" : "");

   if (trade.Buy(lot, _Symbol, ask, sl, tp, comment)) {
      ulong tkt = trade.ResultOrder();
      Print("[BUY] ✓ Ticket #", tkt);
      LogTradeOpen("BUY", lastSigConf, ask, sl, tp, lot, tkt);
      TagTrade(tkt);
   } else
      Print("[BUY] ✗ ", trade.ResultRetcodeDescription());
}

void OpenSell(double sigSL, double sigTP) {
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pip    = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double slDist, tpDist;

   if (scalpMode) {
      slDist = ScalpSLPips * pip;
      tpDist = ScalpTPPips * pip;
   } else {
      slDist = CalcSLDistance(false, sigSL, bid);
      tpDist = (sigTP > 0) ? MathAbs(bid - sigTP) : slDist * 2.0;
   }

   double lot = CalcLot(slDist);
   if (scalpMode) lot = NormLot(lot * ScalpLotMultiplier);

   double sl = NormalizeDouble(bid + slDist, _Digits);
   double tp = NormalizeDouble(bid - tpDist, _Digits);

   string comment = scalpMode ? "AurumSignal SCALP SELL" : "AurumSignal SELL";
   Print("[SELL] Lot:", lot, " Bid:", bid, " SL:", sl, " TP:", tp, scalpMode ? " [SCALP]" : "");

   if (trade.Sell(lot, _Symbol, bid, sl, tp, comment)) {
      ulong tkt = trade.ResultOrder();
      Print("[SELL] ✓ Ticket #", tkt);
      LogTradeOpen("SELL", lastSigConf, bid, sl, tp, lot, tkt);
      TagTrade(tkt);
   } else
      Print("[SELL] ✗ ", trade.ResultRetcodeDescription());
}

//────────────────────────────────────────────────────────────────────
//  SL DISTANCE
//────────────────────────────────────────────────────────────────────
double CalcSLDistance(bool isBuy, double sigSL, double price) {
   if (UseATRStop) {
      double atr[]; ArraySetAsSeries(atr, true);
      if (CopyBuffer(atrHandle, 0, 0, 1, atr) > 0 && atr[0] > 0)
         return atr[0] * ATRMultiplier;
   }
   if (sigSL > 0) return MathAbs(price - sigSL);
   return 20.0 * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
}

//────────────────────────────────────────────────────────────────────
//  LOT CALCULATION
//────────────────────────────────────────────────────────────────────
double CalcLot(double slDist) {
   if (!DynamicLots) return NormLot(FixedLot);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMon  = balance * (RiskPercent / 100.0);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tickSize <= 0 || tickVal <= 0 || slDist <= 0) return NormLot(MinLot);
   double lot = riskMon / ((slDist / tickSize) * tickVal);
   return NormLot(lot);
}

double NormLot(double lot) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathRound(lot / step) * step;
   return MathMax(MinLot, MathMin(MaxLot, lot));
}

//────────────────────────────────────────────────────────────────────
//  BASKET
//────────────────────────────────────────────────────────────────────
void ManageBasket() {
   double pl = GetBasketPL();
   if (pl == 0 && CountOurTrades() == 0) return;
   if (pl >= BasketTP)  { Print("[Basket] TP $", pl); CloseAll("BASKET TP"); }
   if (pl <= BasketSL)  { Print("[Basket] SL $", pl); CloseAll("BASKET SL"); }
}

double GetBasketPL() {
   double t = 0;
   for (int i = PositionsTotal()-1; i >= 0; i--)
      if (pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MAGIC)
         t += pos.Profit() + pos.Swap() + pos.Commission();
   return t;
}

//────────────────────────────────────────────────────────────────────
//  RECOVERY
//────────────────────────────────────────────────────────────────────
void ManageRecovery() {
   static datetime lastRecTime = 0;
   if (TimeCurrent() - lastRecTime < PollSeconds) return;

   for (int i = PositionsTotal()-1; i >= 0; i--) {
      if (!pos.SelectByIndex(i) || pos.Symbol()!=_Symbol || pos.Magic()!=MAGIC) continue;
      if (pos.Profit() > RecoveryTrigger) continue;

      int recLv = 0; double lastLot = pos.Volume(); int mapIdx = -1;
      for (int j = 0; j < ArraySize(recoveryMap); j++)
         if (recoveryMap[j].ticket == pos.Ticket()) { recLv=recoveryMap[j].level; lastLot=recoveryMap[j].lastLot; mapIdx=j; break; }

      if (recLv >= MaxRecoveryLevels) continue;

      double recLot = NormLot(lastLot * RecoveryMult);
      bool ok = false;
      if (pos.PositionType()==POSITION_TYPE_BUY)
         ok = trade.Buy(recLot,  _Symbol, SymbolInfoDouble(_Symbol,SYMBOL_ASK), 0, 0, "Recovery L"+(string)(recLv+1));
      else
         ok = trade.Sell(recLot, _Symbol, SymbolInfoDouble(_Symbol,SYMBOL_BID), 0, 0, "Recovery L"+(string)(recLv+1));

      if (ok) {
         lastRecTime = TimeCurrent();
         Print("[Recovery] Lvl ", recLv+1, " lot:", recLot, " parent:", pos.Ticket());
         if (mapIdx >= 0) { recoveryMap[mapIdx].level=recLv+1; recoveryMap[mapIdx].lastLot=recLot; }
         else { int sz=ArraySize(recoveryMap); ArrayResize(recoveryMap,sz+1); recoveryMap[sz].ticket=pos.Ticket(); recoveryMap[sz].level=1; recoveryMap[sz].lastLot=recLot; }
      }
   }
}

//────────────────────────────────────────────────────────────────────
//  TRAILING + BREAKEVEN + PROFIT LOCK
//────────────────────────────────────────────────────────────────────
void ManageTrailingAndLocks() {
   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;

   for (int i = PositionsTotal()-1; i >= 0; i--) {
      if (!pos.SelectByIndex(i) || pos.Symbol()!=_Symbol || pos.Magic()!=MAGIC) continue;

      bool   isBuy     = (pos.PositionType() == POSITION_TYPE_BUY);
      double openPrice = pos.PriceOpen();
      double curSL     = pos.StopLoss();
      double curTP     = pos.TakeProfit();
      double curPrice  = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                               : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profPips  = isBuy ? (curPrice - openPrice) / pip
                               : (openPrice - curPrice) / pip;
      double newSL     = curSL;

      // ── 1. Breakeven ───────────────────────────────────────────
      if (UseBreakEven && profPips >= BreakEvenPips) {
         double beSL = isBuy
            ? NormalizeDouble(openPrice + BreakEvenBuffer * pip, _Digits)
            : NormalizeDouble(openPrice - BreakEvenBuffer * pip, _Digits);
         if (isBuy  && beSL > newSL) newSL = beSL;
         if (!isBuy && (newSL == 0 || beSL < newSL)) newSL = beSL;
      }

      // ── 2. Profit lock (when approaching TP) ──────────────────
      if (UseProfitLock && curTP > 0) {
         double tpDist   = MathAbs(curTP - openPrice);
         double curProf  = isBuy ? curPrice - openPrice : openPrice - curPrice;
         if (tpDist > 0 && (curProf / tpDist * 100.0) >= ProfitLockTriggerPct) {
            double lockSL = isBuy
               ? NormalizeDouble(openPrice + tpDist * ProfitLockBufferPct / 100.0, _Digits)
               : NormalizeDouble(openPrice - tpDist * ProfitLockBufferPct / 100.0, _Digits);
            if (isBuy  && lockSL > newSL) newSL = lockSL;
            if (!isBuy && (newSL == 0 || lockSL < newSL)) newSL = lockSL;
         }
      }

      // ── 3. Trailing stop ───────────────────────────────────────
      if (UseTrailing && profPips >= TrailStartPips) {
         double trailSL = isBuy
            ? NormalizeDouble(curPrice - TrailStepPips * pip, _Digits)
            : NormalizeDouble(curPrice + TrailStepPips * pip, _Digits);
         if (isBuy  && trailSL > newSL) newSL = trailSL;
         if (!isBuy && (newSL == 0 || trailSL < newSL)) newSL = trailSL;
      }

      // ── Apply if changed ───────────────────────────────────────
      if (newSL > 0 && newSL != curSL) {
         if (trade.PositionModify(pos.Ticket(), newSL, curTP))
            Print("[SL] #", pos.Ticket(), " ", DoubleToString(curSL,_Digits),
                  " → ", DoubleToString(newSL,_Digits),
                  " | pips:", DoubleToString(profPips,1));
      }
   }
}

//────────────────────────────────────────────────────────────────────
//  SCALP MODE TOGGLE
//────────────────────────────────────────────────────────────────────
void ToggleScalpMode() {
   scalpMode = !scalpMode;
   lastSigTime = 0; // re-arm immediately
   if (scalpMode)
      Print("[Scalp] Mode ON  TP:", ScalpTPPips, " pips  SL:", ScalpSLPips, " pips  Conf>=", ScalpMinConfidence, "%");
   else
      Print("[Scalp] Mode OFF");
}

//────────────────────────────────────────────────────────────────────
//  FILE LOGGING  (saved to: MT5\MQL5\Files\AurumSignal_Log.csv)
//────────────────────────────────────────────────────────────────────
const string LOG_FILE = "AurumSignal_Log.csv";

void EnsureLogHeader() {
   // Write header only if file does not exist yet
   if (FileIsExist(LOG_FILE)) return;
   int fh = FileOpen(LOG_FILE, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if (fh == INVALID_HANDLE) return;
   FileWrite(fh,
      "DateTime","Event","Signal","Confidence",
      "Entry","SL","TP","Lot","Ticket",
      "Profit","Outcome","WinRate%","TotalPL","Notes");
   FileClose(fh);
}

void WriteLog(string event, string sig, int conf,
              double entry, double sl, double tp,
              double lot, ulong ticket,
              double profit, string outcome, string notes="") {
   EnsureLogHeader();
   int fh = FileOpen(LOG_FILE, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if (fh == INVALID_HANDLE) {
      Print("[Log] Cannot open file. Error:", GetLastError());
      return;
   }
   FileSeek(fh, 0, SEEK_END);
   double wr = statTotal > 0 ? (double)statWins / statTotal * 100.0 : 0;
   FileWrite(fh,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      event, sig, (string)conf,
      DoubleToString(entry, 2), DoubleToString(sl, 2), DoubleToString(tp, 2),
      DoubleToString(lot, 2), (string)ticket,
      DoubleToString(profit, 2), outcome,
      DoubleToString(wr, 1),
      DoubleToString(statTotalPL, 2),
      notes);
   FileClose(fh);
}

void LogSignal(string sig, int conf, double entry, double sl, double tp, string genAt) {
   // Only log each unique signal once (by genAt timestamp)
   static string lastLoggedGenAt = "";
   if (genAt == lastLoggedGenAt) return;
   lastLoggedGenAt = genAt;
   WriteLog("SIGNAL", sig, conf, entry, sl, tp, 0, 0, 0, "", "genAt="+genAt);
}

void LogTradeOpen(string dir, int conf, double price, double sl, double tp, double lot, ulong ticket) {
   WriteLog("TRADE_OPEN", dir, conf, price, sl, tp, lot, ticket, 0, "", scalpMode?"SCALP":"NORMAL");
}

void LogTradeClose(ulong deal, double profit, string outcome, double wr) {
   string dir      = HistoryDealGetInteger(deal, DEAL_TYPE)==DEAL_TYPE_BUY ? "BUY" : "SELL";
   double closePrice = HistoryDealGetDouble(deal, DEAL_PRICE);
   double lot        = HistoryDealGetDouble(deal, DEAL_VOLUME);
   ulong  ticket     = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   WriteLog("TRADE_CLOSE", dir, lastSigConf, closePrice, 0, 0, lot, ticket,
            profit, outcome,
            "streak="+(string)statStreak+" wr="+DoubleToString(wr,1)+"%");
}

void LogDailySummary() {
   double wr = statTotal > 0 ? (double)statWins / statTotal * 100.0 : 0;
   WriteLog("DAY_SUMMARY", "", 0, 0, 0, 0, 0, 0,
            statTodayPL,
            statTodayPL >= 0 ? "PROFIT" : "LOSS",
            "today_trades="+(string)statTodayTrades+
            " total_wr="+DoubleToString(wr,1)+"%"+
            " alltime_pl=$"+DoubleToString(statTotalPL,2));
}

//────────────────────────────────────────────────────────────────────
//  WIN/LOSS TRACKER
//────────────────────────────────────────────────────────────────────
void TagTrade(ulong ticket) {
   int sz = ArraySize(tradeTagMap);
   ArrayResize(tradeTagMap, sz + 1);
   tradeTagMap[sz].ticket  = ticket;
   tradeTagMap[sz].genAt   = TimeToString(lastSigTime, TIME_DATE|TIME_SECONDS);
   tradeTagMap[sz].sigType = lastSigType;
   tradeTagMap[sz].conf    = lastSigConf;
}

string GetTagGenAt(ulong ticket) {
   for (int i = 0; i < ArraySize(tradeTagMap); i++)
      if (tradeTagMap[i].ticket == ticket) return tradeTagMap[i].genAt;
   return TimeToString(lastSigTime, TIME_DATE|TIME_SECONDS);
}

void PostOutcomeToWeb(ulong ticket, string outcome, double profit) {
   string genAt = GetTagGenAt(ticket);
   string body  = StringFormat(
      "{\"generated_at\":\"%s\",\"ticket\":%I64u,\"outcome\":\"%s\","
      "\"profit\":%.2f,\"signal\":\"%s\",\"confidence\":%d}",
      genAt, ticket, outcome, profit, lastSigType, lastSigConf);

   char   postData[]; StringToCharArray(body, postData, 0, StringLen(body));
   char   result[];   string headers;
   string outUrl = StringSubstr(BackendURL, 0, StringFind(BackendURL, "/latest-signal"))
                   + "/trade-outcome";

   int res = WebRequest("POST", outUrl, "Content-Type: application/json\r\n",
                        5000, postData, result, headers);
   if (res == -1)
      Print("[Outcome] WebRequest failed err=", GetLastError());
   else
      Print("[Outcome] Posted to web: ", outcome, " $", DoubleToString(profit,2), " → ", outUrl);
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result) {
   // Only process completed deal additions (position closes)
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if (!HistoryDealSelect(trans.deal))            return;

   // Must be our magic number
   if ((int)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MAGIC) return;

   // Must be a closing deal
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if (sym != _Symbol) return;

   // Update totals
   statTotal++;
   statTotalPL   += profit;
   statTodayTrades++;
   statTodayPL   += profit;

   if (profit >= 0) {
      statWins++;
      if (profit > statBestTrade) statBestTrade = profit;
      statStreak = (statStreak >= 0) ? statStreak + 1 : 1;
      if (statStreak > statConsecWins) statConsecWins = statStreak;
   } else {
      statLoss++;
      if (profit < statWorstTrade) statWorstTrade = profit;
      statStreak = (statStreak <= 0) ? statStreak - 1 : -1;
      if (MathAbs(statStreak) > statConsecLoss) statConsecLoss = (int)MathAbs(statStreak);
   }

   double wr = statTotal > 0 ? (double)statWins / statTotal * 100.0 : 0;
   lastTradeCloseTime = TimeCurrent();
   string outcome = profit >= 0 ? "WIN" : "LOSS";

   // Consecutive loss pause
   if (profit < 0 && MathAbs(statStreak) >= MaxConsecLosses) {
      pauseUntil = TimeCurrent() + ConsecLossPauseMins * 60;
      Print("[Safety] ", MaxConsecLosses, " consecutive losses — pausing until ",
            TimeToString(pauseUntil, TIME_DATE|TIME_MINUTES));
   }

   Print("[Stats] ", outcome, "  $", DoubleToString(profit, 2),
         "  |  WR: ", DoubleToString(wr, 1), "%",
         "  W:", statWins, " L:", statLoss,
         "  Streak:", statStreak,
         "  TotalPL: $", DoubleToString(statTotalPL, 2));

   LogTradeClose(trans.deal, profit, outcome, wr);
   PostOutcomeToWeb(HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID), outcome, profit);
   SaveStats();
}

bool IsAllowedSession() {
   // ── Convert GMT to IST (UTC + 5h30m) ─────────────────────────
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int totalMins = dt.hour * 60 + dt.min + 330; // +330 min = +5h30m
   if (totalMins >= 1440) totalMins -= 1440;     // wrap past midnight

   int istH    = totalMins / 60;
   int istM    = totalMins % 60;
   int istTime = istH * 100 + istM;              // e.g. 1525 = 15:25

   int winStart = SessionStartIST_H * 100 + SessionStartIST_M; // default 1525
   int winEnd   = SessionEndIST_H   * 100 + SessionEndIST_M;   // default 2130

   if (istTime < winStart || istTime > winEnd) {
      static int lastPrintedIST = -1;
      if (istTime != lastPrintedIST) {
         Print("[Session] IST ", istH, ":", (istM<10?"0":""), istM,
               " — OUTSIDE window ", winStart, "-", winEnd, " IST. No trading.");
         lastPrintedIST = istTime;
      }
      return false;
   }

   // Sub-session label for panel/log
   string label;
   if (istTime >= 1525 && istTime < 1730)
      label = "LONDON-NY OVERLAP (PRIME)";
   else
      label = "NY SESSION";

   Print("[Session] IST ", istH, ":", (istM<10?"0":""), istM, " — ", label, " — gate OPEN");
   return true;
}

void SaveStats() {
   GlobalVariableSet("AurumStat_Total",   (double)statTotal);
   GlobalVariableSet("AurumStat_Wins",    (double)statWins);
   GlobalVariableSet("AurumStat_Loss",    (double)statLoss);
   GlobalVariableSet("AurumStat_TotalPL", statTotalPL);
   GlobalVariableSet("AurumStat_Best",    statBestTrade);
   GlobalVariableSet("AurumStat_Worst",   statWorstTrade);
   GlobalVariableSet("AurumStat_ConsecW", (double)statConsecWins);
   GlobalVariableSet("AurumStat_ConsecL", (double)statConsecLoss);
   GlobalVariableSet("AurumStat_Streak",  (double)statStreak);
   GlobalVariableSet("AurumStat_TdayT",   (double)statTodayTrades);
   GlobalVariableSet("AurumStat_TdayPL",  statTodayPL);
}

void LoadStats() {
   if (!GlobalVariableCheck("AurumStat_Total")) return; // first run
   statTotal       = (int)GlobalVariableGet("AurumStat_Total");
   statWins        = (int)GlobalVariableGet("AurumStat_Wins");
   statLoss        = (int)GlobalVariableGet("AurumStat_Loss");
   statTotalPL     = GlobalVariableGet("AurumStat_TotalPL");
   statBestTrade   = GlobalVariableGet("AurumStat_Best");
   statWorstTrade  = GlobalVariableGet("AurumStat_Worst");
   statConsecWins  = (int)GlobalVariableGet("AurumStat_ConsecW");
   statConsecLoss  = (int)GlobalVariableGet("AurumStat_ConsecLoss");
   statStreak      = (int)GlobalVariableGet("AurumStat_Streak");
   statTodayTrades = (int)GlobalVariableGet("AurumStat_TdayT");
   statTodayPL     = GlobalVariableGet("AurumStat_TdayPL");
}

void ResetStats() {
   statTotal=0; statWins=0; statLoss=0; statTotalPL=0;
   statBestTrade=0; statWorstTrade=0; statConsecWins=0;
   statConsecLoss=0; statStreak=0; statTodayTrades=0; statTodayPL=0;
   SaveStats();
}

//────────────────────────────────────────────────────────────────────
//  CLOSE ALL
//────────────────────────────────────────────────────────────────────
void CloseAll(string reason) {
   Print("[CloseAll] ", reason);
   for (int i = PositionsTotal()-1; i >= 0; i--)
      if (pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MAGIC)
         trade.PositionClose(pos.Ticket());
   ArrayResize(recoveryMap, 0);
}

int CountOurTrades() {
   int n = 0;
   for (int i = PositionsTotal()-1; i >= 0; i--)
      if (pos.SelectByIndex(i) && pos.Symbol()==_Symbol && pos.Magic()==MAGIC) n++;
   return n;
}

//────────────────────────────────────────────────────────────────────
//  PANEL  — create once, update every tick
//────────────────────────────────────────────────────────────────────
void CreatePanel() {
   int x = 10, y = 20, w = 270, lh = 18;

   // Background — taller to fit stats section
   MakeRect(PFX+"BG", x-4, y-4, w, 430, C'10,15,23', C'30,40,60', 160);

   // Title
   MakeLabel(PFX+"TITLE", x+8, y+4, "⬡ AURUM SIGNAL PRO  v3", 11, clrGold);

   // Dividers & info labels
   MakeLabel(PFX+"L_SIG",    x+8, y+26,  "Signal:", 9, C'80,140,180');
   MakeLabel(PFX+"L_PRICE",  x+8, y+44,  "Price:",  9, C'80,140,180');
   MakeLabel(PFX+"L_TRADES", x+8, y+62,  "Trades:", 9, C'80,140,180');
   MakeLabel(PFX+"L_BPL",    x+8, y+80,  "Basket:", 9, C'80,140,180');
   MakeLabel(PFX+"L_DAYPNL", x+8, y+98,  "Day P&L:",9, C'80,140,180');
   MakeLabel(PFX+"L_EQ",     x+8, y+116, "Equity:", 9, C'80,140,180');
   MakeLabel(PFX+"L_LOT",    x+8, y+134, "Lot:",    9, C'80,140,180');
   MakeLabel(PFX+"L_ATR",    x+8, y+152, "ATR SL:", 9, C'80,140,180');

   // Value labels (updated each tick)
   MakeLabel(PFX+"V_SIG",    x+72, y+26,  "—",  9, clrWhite);
   MakeLabel(PFX+"V_PRICE",  x+72, y+44,  "—",  9, clrWhite);
   MakeLabel(PFX+"V_TRADES", x+72, y+62,  "—",  9, clrWhite);
   MakeLabel(PFX+"V_BPL",    x+72, y+80,  "—",  9, clrWhite);
   MakeLabel(PFX+"V_DAYPNL", x+72, y+98,  "—",  9, clrWhite);
   MakeLabel(PFX+"V_EQ",     x+72, y+116, "—",  9, clrWhite);
   MakeLabel(PFX+"V_LOT",    x+72, y+134, "—",  9, clrWhite);
   MakeLabel(PFX+"V_ATR",    x+72, y+152, "—",  9, clrWhite);

   // Status row
   MakeLabel(PFX+"V_STATUS", x+8,  y+170, "Status: READY", 9, clrLimeGreen);

   // Buttons row 1: BUY | SELL | CLOSE ALL
   MakeButton(PFX+"BTN_BUY",   x+6,   y+192, 74, 22, "  BUY",   C'0,100,60',   clrWhite);
   MakeButton(PFX+"BTN_SELL",  x+84,  y+192, 74, 22, "  SELL",  C'100,20,40',  clrWhite);
   MakeButton(PFX+"BTN_CLOSE", x+162, y+192, 100, 22, "CLOSE ALL",C'40,30,10', clrGold);

   // Buttons row 2: SCALP | HALT
   MakeButton(PFX+"BTN_SCALP", x+6,  y+220, 150, 24, "⚡ SCALP MODE: OFF", C'20,20,50', clrGold);
   MakeButton(PFX+"BTN_HALT",    x+162, y+220, 100, 24, "HALT",         C'60,20,10',  clrOrangeRed);
   MakeButton(PFX+"BTN_RESUME",  x+6,   y+250, 256, 20, "FORCE RESUME (bypass halt)", C'10,35,20', clrLimeGreen);

   // Feature flags row
   MakeLabel(PFX+"V_FLAGS", x+8, y+252, "...", 8, C'80,80,100');

   // ── Stats section divider ──────────────────────────────────────
   MakeLabel(PFX+"L_STATDIV",  x+8, y+272, "────── WIN/LOSS TRACKER ──────", 8, C'50,60,80');

   // Stat labels (left column)
   MakeLabel(PFX+"L_STOTAL",   x+8,  y+290, "Trades:",    9, C'80,140,180');
   MakeLabel(PFX+"L_SWR",      x+8,  y+307, "Win Rate:",  9, C'80,140,180');
   MakeLabel(PFX+"L_STPL",     x+8,  y+324, "Total P&L:", 9, C'80,140,180');
   MakeLabel(PFX+"L_SSTREAK",  x+8,  y+341, "Streak:",    9, C'80,140,180');
   MakeLabel(PFX+"L_SBEST",    x+8,  y+358, "Best:",      9, C'80,140,180');
   MakeLabel(PFX+"L_SWORST",   x+8,  y+375, "Worst:",     9, C'80,140,180');

   // Stat values (right-ish)
   MakeLabel(PFX+"V_STOTAL",   x+90, y+290, "—", 9, clrWhite);
   MakeLabel(PFX+"V_SWR",      x+90, y+307, "—", 9, clrWhite);
   MakeLabel(PFX+"V_STPL",     x+90, y+324, "—", 9, clrWhite);
   MakeLabel(PFX+"V_SSTREAK",  x+90, y+341, "—", 9, clrWhite);
   MakeLabel(PFX+"V_SBEST",    x+90, y+358, "—", 9, clrLimeGreen);
   MakeLabel(PFX+"V_SWORST",   x+90, y+375, "—", 9, clrOrangeRed);

   // Today label + RESET button
   MakeLabel(PFX+"V_STODAY",   x+8,  y+393, "Today: 0 trades  $0.00", 8, C'100,100,130');
   MakeButton(PFX+"BTN_RESETSTATS", x+162, y+388, 100, 18, "RESET STATS", C'30,20,10', C'150,90,40');

   ChartRedraw();
}

void UpdatePanel() {
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double dayPL     = equity - dayOpenEquity;
   double basketPL  = GetBasketPL();
   int    trades    = CountOurTrades();
   double pip       = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double price     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ATR stop in pips
   double atrPips = 0;
   double atr[]; ArraySetAsSeries(atr, true);
   if (CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) atrPips = atr[0] * ATRMultiplier / pip;

   // Dynamic lot preview
   double previewLot = CalcLot(atr[0] > 0 ? atr[0]*ATRMultiplier : 20*pip);
   if (scalpMode) previewLot = NormLot(previewLot * ScalpLotMultiplier);

   // Signal display
   color sigCol = lastSigType=="BUY" ? clrLimeGreen : lastSigType=="SELL" ? clrOrangeRed : clrSilver;
   string sigStr = lastSigType=="" ? "—" : lastSigType + "  " + (string)lastSigConf + "%";

   LabelSet(PFX+"V_SIG",    sigStr,  sigCol);
   LabelSet(PFX+"V_PRICE",  "$" + DoubleToString(price, 2), clrWhite);
   LabelSet(PFX+"V_TRADES", (string)trades + " open", trades > 0 ? clrGold : clrSilver);
   LabelSet(PFX+"V_BPL",    "$" + DoubleToString(basketPL, 2),  basketPL >= 0 ? clrLimeGreen : clrOrangeRed);
   LabelSet(PFX+"V_DAYPNL", "$" + DoubleToString(dayPL, 2),     dayPL >= 0   ? clrLimeGreen : clrOrangeRed);
   LabelSet(PFX+"V_EQ",     "$" + DoubleToString(equity, 2), clrWhite);
   LabelSet(PFX+"V_LOT",    DoubleToString(previewLot, 2) + (DynamicLots ? " (auto)" : " (fixed)"), clrGold);
   LabelSet(PFX+"V_ATR",    DoubleToString(atrPips, 1) + " pips", clrSilver);

   // Status
   string status;
   color  statusCol;
   if (tradingHalted)     { status = "⛔ HALTED";          statusCol = clrOrangeRed; }
   else if (!EnableTrading){ status = "⚠ DISABLED (go live)"; statusCol = clrYellow; }
   else if (scalpMode)    { status = "⚡ SCALP MODE ACTIVE";  statusCol = C'255,210,0'; }
   else                   { status = "✓ ACTIVE — waiting";    statusCol = clrLimeGreen; }
   LabelSet(PFX+"V_STATUS", status, statusCol);

   // Scalp button
   string scalpTxt = scalpMode ? "⚡ SCALP MODE: ON  " : "⚡ SCALP MODE: OFF";
   color  scalpBG  = scalpMode ? C'60,50,0' : C'20,20,50';
   ObjectSetString(0,  PFX+"BTN_SCALP", OBJPROP_TEXT, scalpTxt);
   ObjectSetInteger(0, PFX+"BTN_SCALP", OBJPROP_BGCOLOR, scalpBG);

   // Feature flags
   string flags = "";
   flags += (UseBreakEven  ? "BE✓ " : "BE✗ ");
   flags += (UseTrailing   ? "TRAIL✓ " : "TRAIL✗ ");
   flags += (UseProfitLock ? "LOCK✓ " : "LOCK✗ ");
   flags += (RecoveryMode  ? "REC✓ " : "REC✗ ");
   flags += (EquityGuard   ? "GUARD✓" : "GUARD✗");
   LabelSet(PFX+"V_FLAGS", flags, C'100,100,130');

   // ── Stats section ─────────────────────────────────────────────
   double wr = statTotal > 0 ? (double)statWins / statTotal * 100.0 : 0.0;

   // Trades: "18  W:12  L:6"
   string totalStr = (string)statTotal + "   W:" + (string)statWins + "  L:" + (string)statLoss;
   LabelSet(PFX+"V_STOTAL", totalStr, clrWhite);

   // Win rate with colour gradient
   color wrCol = wr >= 60 ? clrLimeGreen : wr >= 50 ? clrGold : clrOrangeRed;
   LabelSet(PFX+"V_SWR", DoubleToString(wr, 1) + "%", wrCol);

   // Total P&L
   color plCol = statTotalPL >= 0 ? clrLimeGreen : clrOrangeRed;
   LabelSet(PFX+"V_STPL", "$" + DoubleToString(statTotalPL, 2), plCol);

   // Current streak
   string streakStr;
   color  streakCol;
   if (statStreak > 0) { streakStr = "+" + (string)statStreak + " wins";  streakCol = clrLimeGreen; }
   else if (statStreak < 0) { streakStr = (string)MathAbs(statStreak) + " losses"; streakCol = clrOrangeRed; }
   else { streakStr = "—"; streakCol = clrSilver; }
   LabelSet(PFX+"V_SSTREAK", streakStr + "  (max W:" + (string)statConsecWins + " L:" + (string)statConsecLoss + ")", streakCol);

   // Best / worst
   LabelSet(PFX+"V_SBEST",  "$" + DoubleToString(statBestTrade, 2),  clrLimeGreen);
   LabelSet(PFX+"V_SWORST", "$" + DoubleToString(statWorstTrade, 2), clrOrangeRed);

   // Today
   color todayCol = statTodayPL >= 0 ? clrLimeGreen : clrOrangeRed;
   LabelSet(PFX+"V_STODAY",
            "Today: " + (string)statTodayTrades + " trades   $" + DoubleToString(statTodayPL, 2),
            todayCol);

   ChartRedraw();
}

void DeletePanel() {
   string names[] = {
      "BG","TITLE",
      "L_SIG","L_PRICE","L_TRADES","L_BPL","L_DAYPNL","L_EQ","L_LOT","L_ATR",
      "V_SIG","V_PRICE","V_TRADES","V_BPL","V_DAYPNL","V_EQ","V_LOT","V_ATR",
      "V_STATUS","V_FLAGS",
      "BTN_BUY","BTN_SELL","BTN_CLOSE","BTN_SCALP","BTN_HALT","BTN_RESUME",
      "L_STATDIV",
      "L_STOTAL","L_SWR","L_STPL","L_SSTREAK","L_SBEST","L_SWORST",
      "V_STOTAL","V_SWR","V_STPL","V_SSTREAK","V_SBEST","V_SWORST",
      "V_STODAY","BTN_RESETSTATS"
   };
   for (int i = 0; i < ArraySize(names); i++)
      ObjectDelete(0, PFX + names[i]);
}

//────────────────────────────────────────────────────────────────────
//  PANEL HELPERS
//────────────────────────────────────────────────────────────────────
void MakeRect(string name, int x, int y, int w, int h, color bg, color border, int transp) {
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,      w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,      h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,    bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,     0);
}

void MakeLabel(string name, int x, int y, string txt, int sz, color clr) {
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   sz);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetString(0,  name, OBJPROP_FONT,       "Consolas");
   ObjectSetString(0,  name, OBJPROP_TEXT,       txt);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,     1);
}

void MakeButton(string name, int x, int y, int w, int h, string txt, color bg, color clr) {
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,     h);
   ObjectSetString(0,  name, OBJPROP_TEXT,      txt);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  9);
   ObjectSetString(0,  name, OBJPROP_FONT,      "Consolas");
   ObjectSetInteger(0, name, OBJPROP_BACK,      false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,    2);
}

void LabelSet(string name, string txt, color clr) {
   ObjectSetString(0,  name, OBJPROP_TEXT,  txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//────────────────────────────────────────────────────────────────────
//  JSON UTILS
//────────────────────────────────────────────────────────────────────
string ExtractStr(string json, string key) {
   string s = "\""+key+"\":\""; int i = StringFind(json,s);
   if (i<0) return "";
   i += StringLen(s);
   int e = StringFind(json,"\"",i);
   return e<0 ? "" : StringSubstr(json,i,e-i);
}
double ExtractNum(string json, string key) {
   string s = "\""+key+"\":"; int i = StringFind(json,s);
   if (i<0) return 0;
   i += StringLen(s);
   if (StringSubstr(json,i,1)=="\"") i++;
   string n="";
   for (int j=i;j<i+24;j++) { string c=StringSubstr(json,j,1); if(c==","||c=="}"||c=="\""||c==" "||c=="\n") break; n+=c; }
   return StringToDouble(n);
}
//+------------------------------------------------------------------+
