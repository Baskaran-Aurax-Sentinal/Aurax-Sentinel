//+------------------------------------------------------------------+
//|                                      GodFather_V3_10_SplitClean  |
//| Split Grid + Controlled Timed Booster                            |
//| Strict $3 refill | Per-order TP/trail | ProfitBank manual exit   |
//+------------------------------------------------------------------+
#property strict
#property version   "3.10"
#property copyright "GodFather"

#include <Trade/Trade.mqh>
CTrade trade;

//---------------- START MODE ----------------//
enum ENUM_GF_START_MODE
{
   MANUAL_ONLY = 0,
   AUTO_ONLY   = 1,
   BOTH        = 2
};

//---------------- MAIN INPUTS ----------------//
input ENUM_GF_START_MODE StartMode      = BOTH;
input int    MagicNumber                = 20260422;
input int    SlippagePoints             = 20;
input bool   EnableGlobalDDPause        = false;
input double GlobalDDPause              = -1000.0;

//---------------- GRID ENGINE ----------------//
input bool   EnableGridEngine           = true;
input double GridLotSize                = 0.01;
input int    MaxGridOrdersBuy           = 20;
input int    MaxGridOrdersSell          = 20;
input double GridSpacingUSD             = 3.0;      // same spacing for all grid levels
input double GridTP_USD                 = 5.0;      // broker-level TP for every grid/base order
input bool   EnableExactGridRefill      = true;
input double GridLevelToleranceUSD      = 0.50;
input double DuplicateRangeBlockUSD     = 0.50;

// Per-order trailing for grid/base/timed orders
input bool   EnableOrderTrailing        = true;
input double TrailStart_USD             = 2.0;
input double TrailLock_USD              = 1.0;
input double TrailGap_USD               = 2.0;
input bool   RemoveTPWhenTrailStarts    = true;

//---------------- TIMED BOOSTER ENGINE ----------------//
input bool   EnableTimedEntries         = true;
input double TimedLotSize               = 0.01;
input int    TimedAddIntervalSec        = 60;
input int    MaxTimedOrdersBuy          = 10;
input int    MaxTimedOrdersSell         = 10;
input int    MaxNegativeTimedOrders     = 3;
input double TimedStartMove_USD         = 0.0;      // 0 = base just needs to be positive
input double TimedMinSpacingUSD         = 1.0;
input double TimedTP_USD                = 5.0;

// Timed signal gates: ANY enabled signal can trigger timed entry
input bool   TimedUseEMAFilter          = true;
input ENUM_TIMEFRAMES TimedEMATF        = PERIOD_M5;
input int    TimedFastEMA               = 9;
input int    TimedSlowEMA               = 21;

input bool   TimedUseCandlePattern      = true;
input ENUM_TIMEFRAMES TimedCandleTF     = PERIOD_M15;
input double StrongCandleBodyPercent    = 60.0;     // body >= % of candle range

input bool   TimedUseMoveFromLastEntry  = false;
input double TimedMoveFromLastUSD       = 30.0;

//---------------- AUTO / MANUAL BASE ----------------//
input bool   AutoStartBuy               = true;     // default BUY auto start
input bool   AutoStartSell              = false;    // SELL manual by default
input bool   DetectManualBuy            = true;
input bool   DetectManualSell           = true;
input bool   StopNewOrdersWhenBaseClosed= true;

//---------------- PROFIT BANK MANUAL EXIT ----------------//
input bool   EnableProfitBank           = true;
input double ManualBankUsePercent       = 40.0;     // button can use only this % of profit bank
input bool   BankIncludeSwapCommission  = true;
input double CloseNegativeBufferUSD     = 0.20;     // leaves small buffer so bank is not overused
input double MaxSingleLossToCloseUSD    = 1000.0;   // safety: skip very large single loser

//---------------- COMMENTS ----------------//
string CMT_BUY_BASE    = "GF_AUTO_BUY_BASE";
string CMT_SELL_BASE   = "GF_AUTO_SELL_BASE";
string CMT_BUY_GRID    = "GF_GRID_BUY";
string CMT_SELL_GRID   = "GF_GRID_SELL";
string CMT_BUY_TIMED   = "GF_TIMED_BUY";
string CMT_SELL_TIMED  = "GF_TIMED_SELL";

//---------------- GLOBALS ----------------//
string   g_symbol = "";
datetime g_eaStartTime = 0;

bool     g_buyCycleActive      = false;
bool     g_buyManageOnly       = false;
ulong    g_buyBaseTicket       = 0;
double   g_buyBaseEntry        = 0.0;
datetime g_lastBuyTimedAdd     = 0;

bool     g_sellCycleActive     = false;
bool     g_sellManageOnly      = false;
ulong    g_sellBaseTicket      = 0;
double   g_sellBaseEntry       = 0.0;
datetime g_lastSellTimedAdd    = 0;

int      g_fastEmaHandle       = INVALID_HANDLE;
int      g_slowEmaHandle       = INVALID_HANDLE;

string BTN_CLOSE_NEG_BUY  = "GF_BTN_CLOSE_NEG_BUY";
string BTN_CLOSE_NEG_SELL = "GF_BTN_CLOSE_NEG_SELL";

//---------------- BASIC HELPERS ----------------//
double AskPrice(){ return SymbolInfoDouble(g_symbol, SYMBOL_ASK); }
double BidPrice(){ return SymbolInfoDouble(g_symbol, SYMBOL_BID); }

double NormPrice(double p)
{
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   return NormalizeDouble(p, digits);
}

bool SelectPos(ulong ticket)
{
   if(ticket == 0) return false;
   return PositionSelectByTicket(ticket);
}

bool ManualAllowed(){ return (StartMode == MANUAL_ONLY || StartMode == BOTH); }
bool AutoAllowed(){ return (StartMode == AUTO_ONLY || StartMode == BOTH); }

bool IsTimedComment(const string c)
{
   return (StringFind(c, CMT_BUY_TIMED) == 0 || StringFind(c, CMT_SELL_TIMED) == 0);
}

bool IsGridComment(const string c)
{
   return (StringFind(c, CMT_BUY_GRID) == 0 || StringFind(c, CMT_SELL_GRID) == 0);
}

bool IsBaseComment(const string c)
{
   return (c == CMT_BUY_BASE || c == CMT_SELL_BASE);
}

bool IsGridFamilyComment(const string c)
{
   return (IsGridComment(c) || IsBaseComment(c));
}

bool IsManagedComment(const string c)
{
   return (IsGridFamilyComment(c) || IsTimedComment(c));
}

bool CanAddAnyNewOrders()
{
   if(!EnableGlobalDDPause) return true;
   return (GetAllEAProfit() > GlobalDDPause);
}

double GetGridLevelDistance(int level)
{
   return (GridSpacingUSD * level);
}

string GridLevelComment(ENUM_POSITION_TYPE side, int level)
{
   if(side == POSITION_TYPE_BUY)
      return CMT_BUY_GRID + "_L" + IntegerToString(level);
   return CMT_SELL_GRID + "_L" + IntegerToString(level);
}

//---------------- POSITION CLASSIFICATION ----------------//
bool IsManualBaseTicket(ENUM_POSITION_TYPE side, ulong ticket)
{
   if(side == POSITION_TYPE_BUY) return (ticket == g_buyBaseTicket);
   return (ticket == g_sellBaseTicket);
}

bool IsCyclePosition(ENUM_POSITION_TYPE side, ulong ticket)
{
   if(!SelectPos(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != g_symbol) return false;
   if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) return false;

   long mg = (long)PositionGetInteger(POSITION_MAGIC);
   if(mg == MagicNumber) return true;
   if(mg == 0 && IsManualBaseTicket(side, ticket)) return true;
   return false;
}

bool IsEAOnlyCyclePosition(ENUM_POSITION_TYPE side, ulong ticket)
{
   if(!SelectPos(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != g_symbol) return false;
   if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) return false;
   return ((long)PositionGetInteger(POSITION_MAGIC) == MagicNumber);
}

int CountEAOnlyPositions(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsEAOnlyCyclePosition(side, ticket)) count++;
   }
   return count;
}

int CountGridEntriesOnly(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(IsGridComment(PositionGetString(POSITION_COMMENT))) count++;
   }
   return count;
}

int CountTimedPositions(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(IsTimedComment(PositionGetString(POSITION_COMMENT))) count++;
   }
   return count;
}

int CountNegativeTimedPositions(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(!IsTimedComment(PositionGetString(POSITION_COMMENT))) continue;
      if(PositionGetDouble(POSITION_PROFIT) < 0.0) count++;
   }
   return count;
}

int CountNegativePositions(ENUM_POSITION_TYPE side)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(PositionGetDouble(POSITION_PROFIT) < 0.0) count++;
   }
   return count;
}

double GetEAOnlyFloatingProfit(ENUM_POSITION_TYPE side)
{
   double p = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      p += PositionGetDouble(POSITION_PROFIT);
   }
   return p;
}

double GetAllEAProfit()
{
   double p = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == g_symbol && (long)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         p += PositionGetDouble(POSITION_PROFIT);
   }
   return p;
}

double GetLotSum(ENUM_POSITION_TYPE side)
{
   double lots = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double GetFamilyFloatingProfit(ENUM_POSITION_TYPE side, int family) // 0 grid/base, 1 timed
{
   double p = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(family == 0 && !IsGridFamilyComment(cmt)) continue;
      if(family == 1 && !IsTimedComment(cmt)) continue;
      p += PositionGetDouble(POSITION_PROFIT);
   }
   return p;
}

double GetLatestTimedEntryPrice(ENUM_POSITION_TYPE side)
{
   double latestPrice = 0.0;
   datetime latestTime = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      if(!IsTimedComment(PositionGetString(POSITION_COMMENT))) continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(latestPrice == 0.0 || t > latestTime)
      {
         latestTime = t;
         latestPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return latestPrice;
}

bool HasSameRangeOrder(ENUM_POSITION_TYPE side, double price, double tolerance, int family) // 0 grid/base, 1 timed, 9 all EA
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(family == 0 && !IsGridFamilyComment(cmt)) continue;
      if(family == 1 && !IsTimedComment(cmt)) continue;
      if(family == 9 && !IsManagedComment(cmt)) continue;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(openPrice - price) <= tolerance) return true;
   }
   return false;
}

//---------------- BASE DETECTION / RESET ----------------//
bool GetLatestManualBase(ENUM_POSITION_TYPE side, ulong &ticketOut, double &entryOut)
{
   ticketOut = 0; entryOut = 0.0;
   bool found = false;
   datetime latest = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != 0) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || t > latest)
      {
         found = true;
         latest = t;
         ticketOut = ticket;
         entryOut = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return found;
}

bool GetLatestEAByComment(ENUM_POSITION_TYPE side, const string commentText, ulong &ticketOut, double &entryOut)
{
   ticketOut = 0; entryOut = 0.0;
   bool found = false;
   datetime latest = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side) continue;
      if(PositionGetString(POSITION_COMMENT) != commentText) continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || t > latest)
      {
         found = true;
         latest = t;
         ticketOut = ticket;
         entryOut = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return found;
}

void ResetBuySide()
{
   g_buyCycleActive = false; g_buyManageOnly = false; g_buyBaseTicket = 0; g_buyBaseEntry = 0.0;
   g_lastBuyTimedAdd = 0;
}

void ResetSellSide()
{
   g_sellCycleActive = false; g_sellManageOnly = false; g_sellBaseTicket = 0; g_sellBaseEntry = 0.0;
   g_lastSellTimedAdd = 0;
}

void ActivateSide(ENUM_POSITION_TYPE side, ulong ticket, double entry, bool manual)
{
   if(side == POSITION_TYPE_BUY)
   {
      g_buyCycleActive = true; g_buyManageOnly = false; g_buyBaseTicket = ticket; g_buyBaseEntry = entry;
      g_lastBuyTimedAdd = 0;
      Print("GodFather V3.10: BUY base activated. Manual=", manual, " Entry=", entry);
   }
   else
   {
      g_sellCycleActive = true; g_sellManageOnly = false; g_sellBaseTicket = ticket; g_sellBaseEntry = entry;
      g_lastSellTimedAdd = 0;
      Print("GodFather V3.10: SELL base activated. Manual=", manual, " Entry=", entry);
   }
}

//---------------- ORDER PLACEMENT ----------------//
double CalcTP(ENUM_POSITION_TYPE side, const string commentText, double entryPrice)
{
   double move = (IsTimedComment(commentText) ? TimedTP_USD : GridTP_USD);
   if(move <= 0.0) return 0.0;
   if(side == POSITION_TYPE_BUY) return NormPrice(entryPrice + move);
   return NormPrice(entryPrice - move);
}

bool PlaceBuy(const string commentText, double lots)
{
   double entry = AskPrice();
   double tp = CalcTP(POSITION_TYPE_BUY, commentText, entry);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = trade.Buy(lots, g_symbol, 0.0, 0.0, tp, commentText);
   if(!ok)
      Print("BUY failed: ", commentText, " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription(), " error=", GetLastError());
   return ok;
}

bool PlaceSell(const string commentText, double lots)
{
   double entry = BidPrice();
   double tp = CalcTP(POSITION_TYPE_SELL, commentText, entry);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok = trade.Sell(lots, g_symbol, 0.0, 0.0, tp, commentText);
   if(!ok)
      Print("SELL failed: ", commentText, " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription(), " error=", GetLastError());
   return ok;
}

//---------------- BASE START ----------------//
void DetectManualBaseOrders()
{
   if(!ManualAllowed()) return;
   ulong tk = 0; double pr = 0.0;

   if(DetectManualBuy && !g_buyCycleActive)
      if(GetLatestManualBase(POSITION_TYPE_BUY, tk, pr)) ActivateSide(POSITION_TYPE_BUY, tk, pr, true);

   if(DetectManualSell && !g_sellCycleActive)
      if(GetLatestManualBase(POSITION_TYPE_SELL, tk, pr)) ActivateSide(POSITION_TYPE_SELL, tk, pr, true);
}

void CheckAutoStart()
{
   if(!AutoAllowed() || !CanAddAnyNewOrders()) return;
   ulong tk = 0; double pr = 0.0;

   if(AutoStartBuy && !g_buyCycleActive)
   {
      if(PlaceBuy(CMT_BUY_BASE, GridLotSize))
         if(GetLatestEAByComment(POSITION_TYPE_BUY, CMT_BUY_BASE, tk, pr)) ActivateSide(POSITION_TYPE_BUY, tk, pr, false);
   }

   if(AutoStartSell && !g_sellCycleActive)
   {
      if(PlaceSell(CMT_SELL_BASE, GridLotSize))
         if(GetLatestEAByComment(POSITION_TYPE_SELL, CMT_SELL_BASE, tk, pr)) ActivateSide(POSITION_TYPE_SELL, tk, pr, false);
   }
}

void UpdateBaseAliveState()
{
   if(g_buyCycleActive && !g_buyManageOnly && StopNewOrdersWhenBaseClosed && !SelectPos(g_buyBaseTicket))
   {
      g_buyManageOnly = true;
      Print("GodFather V3.10: BUY base closed. BUY side manage-only.");
   }

   if(g_sellCycleActive && !g_sellManageOnly && StopNewOrdersWhenBaseClosed && !SelectPos(g_sellBaseTicket))
   {
      g_sellManageOnly = true;
      Print("GodFather V3.10: SELL base closed. SELL side manage-only.");
   }
}

void ValidateResetConditions()
{
   if(g_buyCycleActive && CountEAOnlyPositions(POSITION_TYPE_BUY) == 0 && !SelectPos(g_buyBaseTicket)) ResetBuySide();
   if(g_sellCycleActive && CountEAOnlyPositions(POSITION_TYPE_SELL) == 0 && !SelectPos(g_sellBaseTicket)) ResetSellSide();
}

//---------------- BROKER TP BACKUP / TRAILING ----------------//
void ApplyBrokerTPBackup()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      string cmt = PositionGetString(POSITION_COMMENT);

      if(!IsManagedComment(cmt)) continue;

      if(RemoveTPWhenTrailStarts && sl != 0.0)
      {
         bool positiveSL = false;
         if(side == POSITION_TYPE_BUY && sl > entry) positiveSL = true;
         if(side == POSITION_TYPE_SELL && sl < entry) positiveSL = true;
         if(positiveSL && tp != 0.0)
            trade.PositionModify(ticket, sl, 0.0);
         if(positiveSL) continue;
      }

      double wantTP = CalcTP(side, cmt, entry);
      if(wantTP > 0.0 && (tp == 0.0 || MathAbs(tp - wantTP) > (_Point * 2)))
         trade.PositionModify(ticket, sl, wantTP);
   }
}

void ManageTrailing()
{
   if(!EnableOrderTrailing) return;

   double bid = BidPrice();
   double ask = AskPrice();

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      string cmt = PositionGetString(POSITION_COMMENT);
      if(!IsManagedComment(cmt)) continue;

      if(side == POSITION_TYPE_BUY && bid >= entry + TrailStart_USD)
      {
         double lockSL = NormPrice(entry + TrailLock_USD);
         double trailSL = NormPrice(bid - TrailGap_USD);
         double wantedSL = MathMax(lockSL, trailSL);
         double wantedTP = RemoveTPWhenTrailStarts ? 0.0 : tp;
         if(sl == 0.0 || wantedSL > sl + (_Point * 2) || (RemoveTPWhenTrailStarts && tp != 0.0))
            trade.PositionModify(ticket, wantedSL, wantedTP);
      }

      if(side == POSITION_TYPE_SELL && ask <= entry - TrailStart_USD)
      {
         double lockSL = NormPrice(entry - TrailLock_USD);
         double trailSL = NormPrice(ask + TrailGap_USD);
         double wantedSL = MathMin(lockSL, trailSL);
         double wantedTP = RemoveTPWhenTrailStarts ? 0.0 : tp;
         if(sl == 0.0 || wantedSL < sl - (_Point * 2) || (RemoveTPWhenTrailStarts && tp != 0.0))
            trade.PositionModify(ticket, wantedSL, wantedTP);
      }
   }
}

//---------------- STRICT GRID ----------------//
bool HasGridLevelOpen(ENUM_POSITION_TYPE side, int level, double levelPrice)
{
   string exactComment = GridLevelComment(side, level);
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(!IsGridComment(cmt)) continue;
      if(cmt == exactComment) return true;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(openPrice - levelPrice) <= GridLevelToleranceUSD) return true;
   }
   return false;
}

void HandleBuyStrictGridRefill()
{
   if(!EnableGridEngine || !g_buyCycleActive || g_buyManageOnly || g_buyBaseEntry <= 0.0) return;
   if(CountGridEntriesOnly(POSITION_TYPE_BUY) >= MaxGridOrdersBuy) return;

   double bid = BidPrice();
   for(int level = 1; level <= MaxGridOrdersBuy; level++)
   {
      if(CountGridEntriesOnly(POSITION_TYPE_BUY) >= MaxGridOrdersBuy) return;
      double levelPrice = NormPrice(g_buyBaseEntry - GetGridLevelDistance(level));
      if(bid <= levelPrice)
      {
         if(!HasGridLevelOpen(POSITION_TYPE_BUY, level, levelPrice) && !HasSameRangeOrder(POSITION_TYPE_BUY, levelPrice, DuplicateRangeBlockUSD, 0))
         {
            PlaceBuy(GridLevelComment(POSITION_TYPE_BUY, level), GridLotSize);
            return;
         }
      }
      else return;
   }
}

void HandleSellStrictGridRefill()
{
   if(!EnableGridEngine || !g_sellCycleActive || g_sellManageOnly || g_sellBaseEntry <= 0.0) return;
   if(CountGridEntriesOnly(POSITION_TYPE_SELL) >= MaxGridOrdersSell) return;

   double ask = AskPrice();
   for(int level = 1; level <= MaxGridOrdersSell; level++)
   {
      if(CountGridEntriesOnly(POSITION_TYPE_SELL) >= MaxGridOrdersSell) return;
      double levelPrice = NormPrice(g_sellBaseEntry + GetGridLevelDistance(level));
      if(ask >= levelPrice)
      {
         if(!HasGridLevelOpen(POSITION_TYPE_SELL, level, levelPrice) && !HasSameRangeOrder(POSITION_TYPE_SELL, levelPrice, DuplicateRangeBlockUSD, 0))
         {
            PlaceSell(GridLevelComment(POSITION_TYPE_SELL, level), GridLotSize);
            return;
         }
      }
      else return;
   }
}

void HandleGridEntries()
{
   if(!EnableGridEngine || !CanAddAnyNewOrders()) return;
   HandleBuyStrictGridRefill();
   HandleSellStrictGridRefill();
}

//---------------- TIMED SIGNALS ----------------//
bool BasePositive(ENUM_POSITION_TYPE side)
{
   if(side == POSITION_TYPE_BUY)
   {
      if(!SelectPos(g_buyBaseTicket)) return false;
      return (BidPrice() >= g_buyBaseEntry + TimedStartMove_USD);
   }
   if(!SelectPos(g_sellBaseTicket)) return false;
   return (AskPrice() <= g_sellBaseEntry - TimedStartMove_USD);
}

bool TimedSpacingAllows(ENUM_POSITION_TYPE side)
{
   double lastTimed = GetLatestTimedEntryPrice(side);
   if(lastTimed <= 0.0) return true;
   double nowPrice = (side == POSITION_TYPE_BUY ? AskPrice() : BidPrice());
   return (MathAbs(nowPrice - lastTimed) >= TimedMinSpacingUSD);
}

bool GetEMA(int handle, double &value)
{
   value = 0.0;
   if(handle == INVALID_HANDLE) return false;
   double buffer[1];
   if(CopyBuffer(handle, 0, 0, 1, buffer) <= 0) return false;
   value = buffer[0];
   return true;
}

bool TimedEMAAllows(ENUM_POSITION_TYPE side)
{
   if(!TimedUseEMAFilter) return false;
   double fast = 0.0, slow = 0.0;
   if(!GetEMA(g_fastEmaHandle, fast) || !GetEMA(g_slowEmaHandle, slow)) return false;
   if(side == POSITION_TYPE_BUY) return (fast > slow);
   return (fast < slow);
}

bool TimedCandlePatternAllows(ENUM_POSITION_TYPE side)
{
   if(!TimedUseCandlePattern) return false;

   double o1 = iOpen(g_symbol, TimedCandleTF, 1);
   double c1 = iClose(g_symbol, TimedCandleTF, 1);
   double h1 = iHigh(g_symbol, TimedCandleTF, 1);
   double l1 = iLow(g_symbol, TimedCandleTF, 1);
   double o2 = iOpen(g_symbol, TimedCandleTF, 2);
   double c2 = iClose(g_symbol, TimedCandleTF, 2);

   if(o1 == 0.0 || c1 == 0.0 || h1 == 0.0 || l1 == 0.0) return false;
   double range = h1 - l1;
   if(range <= 0.0) return false;
   double bodyPercent = (MathAbs(c1 - o1) / range) * 100.0;

   bool bullishStrong = (c1 > o1 && bodyPercent >= StrongCandleBodyPercent);
   bool bearishStrong = (c1 < o1 && bodyPercent >= StrongCandleBodyPercent);
   bool bullishEngulf = (c2 < o2 && c1 > o1 && c1 > o2 && o1 < c2);
   bool bearishEngulf = (c2 > o2 && c1 < o1 && c1 < o2 && o1 > c2);

   if(side == POSITION_TYPE_BUY) return (bullishStrong || bullishEngulf);
   return (bearishStrong || bearishEngulf);
}

bool TimedMoveFromLastAllows(ENUM_POSITION_TYPE side)
{
   if(!TimedUseMoveFromLastEntry) return false;
   double anchor = GetLatestTimedEntryPrice(side);
   if(anchor <= 0.0)
      anchor = (side == POSITION_TYPE_BUY ? g_buyBaseEntry : g_sellBaseEntry);
   if(anchor <= 0.0) return false;

   if(side == POSITION_TYPE_BUY)
      return (AskPrice() >= anchor + TimedMoveFromLastUSD);
   return (BidPrice() <= anchor - TimedMoveFromLastUSD);
}

bool TimedSignalAllows(ENUM_POSITION_TYPE side)
{
   bool anyEnabled = (TimedUseEMAFilter || TimedUseCandlePattern || TimedUseMoveFromLastEntry);
   if(!anyEnabled) return true;
   if(TimedEMAAllows(side)) return true;
   if(TimedCandlePatternAllows(side)) return true;
   if(TimedMoveFromLastAllows(side)) return true;
   return false;
}

string TimedSignalText(ENUM_POSITION_TYPE side)
{
   if(TimedEMAAllows(side)) return "EMA";
   if(TimedCandlePatternAllows(side)) return "M15 candle";
   if(TimedMoveFromLastAllows(side)) return "$30 move";
   if(!(TimedUseEMAFilter || TimedUseCandlePattern || TimedUseMoveFromLastEntry)) return "No filter";
   return "Waiting signal";
}

string TimedBlockReason(ENUM_POSITION_TYPE side)
{
   if(!EnableTimedEntries) return "OFF";
   if(!CanAddAnyNewOrders()) return "DD pause";
   if(side == POSITION_TYPE_BUY)
   {
      if(!g_buyCycleActive) return "No base";
      if(g_buyManageOnly) return "Manage only";
      if(!SelectPos(g_buyBaseTicket)) return "Base closed";
      if(!BasePositive(side)) return "Base not positive";
      if(CountTimedPositions(side) >= MaxTimedOrdersBuy) return "Max timed";
   }
   else
   {
      if(!g_sellCycleActive) return "No base";
      if(g_sellManageOnly) return "Manage only";
      if(!SelectPos(g_sellBaseTicket)) return "Base closed";
      if(!BasePositive(side)) return "Base not positive";
      if(CountTimedPositions(side) >= MaxTimedOrdersSell) return "Max timed";
   }
   if(CountNegativeTimedPositions(side) >= MaxNegativeTimedOrders) return "Timed neg cap";
   if(!TimedSpacingAllows(side)) return "Spacing block";
   if(!TimedSignalAllows(side)) return TimedSignalText(side);
   return "READY:" + TimedSignalText(side);
}

void HandleTimedEntries()
{
   if(!EnableTimedEntries || !CanAddAnyNewOrders()) return;
   datetime now = TimeCurrent();

   if(g_buyCycleActive && !g_buyManageOnly && BasePositive(POSITION_TYPE_BUY))
   {
      if(CountTimedPositions(POSITION_TYPE_BUY) < MaxTimedOrdersBuy &&
         CountNegativeTimedPositions(POSITION_TYPE_BUY) < MaxNegativeTimedOrders &&
         TimedSpacingAllows(POSITION_TYPE_BUY) &&
         TimedSignalAllows(POSITION_TYPE_BUY))
      {
         if(g_lastBuyTimedAdd == 0 || (now - g_lastBuyTimedAdd) >= TimedAddIntervalSec)
         {
            double px = AskPrice();
            if(!HasSameRangeOrder(POSITION_TYPE_BUY, px, DuplicateRangeBlockUSD, 1))
            {
               if(PlaceBuy(CMT_BUY_TIMED, TimedLotSize)) g_lastBuyTimedAdd = now;
            }
         }
      }
   }

   if(g_sellCycleActive && !g_sellManageOnly && BasePositive(POSITION_TYPE_SELL))
   {
      if(CountTimedPositions(POSITION_TYPE_SELL) < MaxTimedOrdersSell &&
         CountNegativeTimedPositions(POSITION_TYPE_SELL) < MaxNegativeTimedOrders &&
         TimedSpacingAllows(POSITION_TYPE_SELL) &&
         TimedSignalAllows(POSITION_TYPE_SELL))
      {
         if(g_lastSellTimedAdd == 0 || (now - g_lastSellTimedAdd) >= TimedAddIntervalSec)
         {
            double px = BidPrice();
            if(!HasSameRangeOrder(POSITION_TYPE_SELL, px, DuplicateRangeBlockUSD, 1))
            {
               if(PlaceSell(CMT_SELL_TIMED, TimedLotSize)) g_lastSellTimedAdd = now;
            }
         }
      }
   }
}

//---------------- PROFIT BANK ----------------//
double GetProfitBank()
{
   if(!EnableProfitBank) return 0.0;
   double bank = 0.0;
   if(!HistorySelect(g_eaStartTime, TimeCurrent())) return 0.0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != g_symbol) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double p = HistoryDealGetDouble(deal, DEAL_PROFIT);
      if(BankIncludeSwapCommission)
         p += HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
      if(p > 0.0) bank += p;
   }
   return bank;
}

void CloseNegativeUsingBank(ENUM_POSITION_TYPE side)
{
   double available = GetProfitBank() * ManualBankUsePercent / 100.0;
   if(available <= CloseNegativeBufferUSD) return;

   while(available > CloseNegativeBufferUSD)
   {
      ulong worstTicket = 0;
      double worstProfit = 0.0;

      for(int i = 0; i < PositionsTotal(); i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsEAOnlyCyclePosition(side, ticket)) continue;
         double p = PositionGetDouble(POSITION_PROFIT);
         if(p >= 0.0) continue;
         if(MathAbs(p) > MaxSingleLossToCloseUSD) continue;
         if(worstTicket == 0 || p < worstProfit)
         {
            worstTicket = ticket;
            worstProfit = p;
         }
      }

      if(worstTicket == 0) break;
      double need = MathAbs(worstProfit) + CloseNegativeBufferUSD;
      if(need > available) break;

      if(trade.PositionClose(worstTicket))
         available -= need;
      else
         break;
   }
}

//---------------- DASHBOARD / BUTTONS ----------------//
void CreateOrUpdateLabel(const string name, const string text, int x, int y, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void CreateButton(const string name, const string text, int x, int y, int w, int h, color bg)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
}

void DeleteDashboard()
{
   string names[10] = {"GFV310_TITLE","GFV310_BUY","GFV310_SELL","GFV310_TIMED_BUY","GFV310_TIMED_SELL","GFV310_GRID","GFV310_BANK","GFV310_FLOAT",BTN_CLOSE_NEG_BUY,BTN_CLOSE_NEG_SELL};
   for(int i = 0; i < 10; i++) ObjectDelete(0, names[i]);
}

string ModeText()
{
   if(StartMode == MANUAL_ONLY) return "MANUAL_ONLY";
   if(StartMode == AUTO_ONLY) return "AUTO_ONLY";
   return "BOTH";
}

void UpdateDashboard()
{
   string title = "GodFather V3.10 | " + g_symbol + " | Mode:" + ModeText() + " | Split Engine | Basket/Recovery OFF";

   string buyTxt = "BUY  Active:" + (g_buyCycleActive ? "Y" : "N") +
                   " MOnly:" + (g_buyManageOnly ? "Y" : "N") +
                   " Grid:" + IntegerToString(CountGridEntriesOnly(POSITION_TYPE_BUY)) +
                   " Timed:" + IntegerToString(CountTimedPositions(POSITION_TYPE_BUY)) +
                   " Neg:" + IntegerToString(CountNegativePositions(POSITION_TYPE_BUY)) +
                   " Lot:" + DoubleToString(GetLotSum(POSITION_TYPE_BUY), 2) +
                   " P/L:" + DoubleToString(GetEAOnlyFloatingProfit(POSITION_TYPE_BUY), 2);

   string sellTxt = "SELL Active:" + (g_sellCycleActive ? "Y" : "N") +
                    " MOnly:" + (g_sellManageOnly ? "Y" : "N") +
                    " Grid:" + IntegerToString(CountGridEntriesOnly(POSITION_TYPE_SELL)) +
                    " Timed:" + IntegerToString(CountTimedPositions(POSITION_TYPE_SELL)) +
                    " Neg:" + IntegerToString(CountNegativePositions(POSITION_TYPE_SELL)) +
                    " Lot:" + DoubleToString(GetLotSum(POSITION_TYPE_SELL), 2) +
                    " P/L:" + DoubleToString(GetEAOnlyFloatingProfit(POSITION_TYPE_SELL), 2);

   string timedBuy = "Timed BUY  Status:" + TimedBlockReason(POSITION_TYPE_BUY) +
                     " NegTimed:" + IntegerToString(CountNegativeTimedPositions(POSITION_TYPE_BUY)) + "/" + IntegerToString(MaxNegativeTimedOrders) +
                     " Float:" + DoubleToString(GetFamilyFloatingProfit(POSITION_TYPE_BUY, 1), 2);

   string timedSell = "Timed SELL Status:" + TimedBlockReason(POSITION_TYPE_SELL) +
                      " NegTimed:" + IntegerToString(CountNegativeTimedPositions(POSITION_TYPE_SELL)) + "/" + IntegerToString(MaxNegativeTimedOrders) +
                      " Float:" + DoubleToString(GetFamilyFloatingProfit(POSITION_TYPE_SELL, 1), 2);

   string gridTxt = "Grid: $" + DoubleToString(GridSpacingUSD, 2) + " exact refill | TP:$" + DoubleToString(GridTP_USD, 2) +
                    " | Trail start/lock/gap: " + DoubleToString(TrailStart_USD, 1) + "/" + DoubleToString(TrailLock_USD, 1) + "/" + DoubleToString(TrailGap_USD, 1);

   double bank = GetProfitBank();
   string bankTxt = "ProfitBank:" + DoubleToString(bank, 2) +
                    " | Button usable " + DoubleToString(ManualBankUsePercent, 1) + "% = " + DoubleToString(bank * ManualBankUsePercent / 100.0, 2);

   string floatTxt = "Total EA Float:" + DoubleToString(GetAllEAProfit(), 2) +
                     " | AutoBuy:" + (AutoStartBuy ? "ON" : "OFF") +
                     " AutoSell:" + (AutoStartSell ? "ON" : "OFF") +
                     " | TP backup ON";

   CreateOrUpdateLabel("GFV310_TITLE", title, 10, 20, clrGold);
   CreateOrUpdateLabel("GFV310_BUY", buyTxt, 10, 40, clrLime);
   CreateOrUpdateLabel("GFV310_SELL", sellTxt, 10, 60, clrTomato);
   CreateOrUpdateLabel("GFV310_TIMED_BUY", timedBuy, 10, 80, clrAqua);
   CreateOrUpdateLabel("GFV310_TIMED_SELL", timedSell, 10, 100, clrAqua);
   CreateOrUpdateLabel("GFV310_GRID", gridTxt, 10, 120, clrWhite);
   CreateOrUpdateLabel("GFV310_BANK", bankTxt, 10, 140, clrYellow);
   CreateOrUpdateLabel("GFV310_FLOAT", floatTxt, 10, 160, clrWhite);

   CreateButton(BTN_CLOSE_NEG_BUY, "Close NEG BUY using Bank", 10, 185, 185, 24, clrDarkGreen);
   CreateButton(BTN_CLOSE_NEG_SELL, "Close NEG SELL using Bank", 205, 185, 190, 24, clrMaroon);
}

//---------------- MT5 EVENTS ----------------//
int OnInit()
{
   g_symbol = _Symbol;
   g_eaStartTime = TimeCurrent();
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(TimedUseEMAFilter)
   {
      g_fastEmaHandle = iMA(g_symbol, TimedEMATF, TimedFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_slowEmaHandle = iMA(g_symbol, TimedEMATF, TimedSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_fastEmaHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE)
         Print("GodFather V3.10: EMA handle failed. EMA timed signal will wait until valid.");
   }

   UpdateDashboard();
   Print("GodFather V3.10 initialized on ", g_symbol, " | Mode=", ModeText());
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fastEmaHandle != INVALID_HANDLE) IndicatorRelease(g_fastEmaHandle);
   if(g_slowEmaHandle != INVALID_HANDLE) IndicatorRelease(g_slowEmaHandle);
   DeleteDashboard();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;

   if(sparam == BTN_CLOSE_NEG_BUY)
   {
      CloseNegativeUsingBank(POSITION_TYPE_BUY);
      ObjectSetInteger(0, BTN_CLOSE_NEG_BUY, OBJPROP_STATE, false);
   }
   else if(sparam == BTN_CLOSE_NEG_SELL)
   {
      CloseNegativeUsingBank(POSITION_TYPE_SELL);
      ObjectSetInteger(0, BTN_CLOSE_NEG_SELL, OBJPROP_STATE, false);
   }
}

void OnTick()
{
   DetectManualBaseOrders();
   CheckAutoStart();
   UpdateBaseAliveState();

   ApplyBrokerTPBackup();
   ManageTrailing();

   HandleGridEntries();       // independent strict $3 grid
   HandleTimedEntries();      // controlled timed booster

   ApplyBrokerTPBackup();
   ManageTrailing();

   ValidateResetConditions();
   UpdateDashboard();
}
//+------------------------------------------------------------------+
