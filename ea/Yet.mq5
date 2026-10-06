//+------------------------------------------------------------------+
//|                                                     Yetimmm.mq5  |
//|  Yetimmm - XAUUSD continuous risk-sequence Expert Advisor        |
//|  MetaTrader 5 | Telegram control | State recovery | Trade log    |
//+------------------------------------------------------------------+
#property copyright "Yetimmm"
#property version   "2.11"
#property description "Yetimmm | XAUUSD | Two-level Stop Buy / Stop Sell switch + risk sequence | Telegram integration"

#include <Trade\Trade.mqh>

//--- v2.11: SECOND REVIEW FIXES
//---   * BREACH_MARKET slippage is now REAL: the market request carries the expected price (so Max Slippage Check acts as a price guard)
//---     AND the fill is compared with that expected price after execution (Deviation was always 0 before). A rejected reversal returns
//---     to WAITING_REENTRY (direction is not lost) and is retried after a cooldown.
//---   * History recovery no longer depends on a fixed 1-hour window: the scan marker advances ONLY after every position found in the
//---     scanned range was registered (6 h safety overlap, last processed deal time as fallback). Positions are registered AND processed
//---     in chronological order, so a long outage with several trades rebuilds the risk sequence in the right order.
//---   * Netting: a position that absorbed foreign volume while the bot was OFFLINE is now detected from its history (foreign entry deals)
//---     and treated as TAINTED even when it was already closed before the bot returned.
//---   * Combined margin check: a missing Buy Stop / Sell Stop pair is placed only when the margin of BOTH missing orders is available
//---     (InpCombinedMargin) - no more "one side exists, the other is rejected for NO MONEY".
//---   * Market reversal: permanent failures (invalid volume, long/short only, close only, volume limit) and failures that persist
//---     (YT_REV_MAX_HARD attempts) switch the bot to ERROR / MANUAL ACTION instead of retrying forever. /start or new levels resume the reversal.
//---   * InpPriceFallback can no longer turn a manual / stop-out / EA close into an "SL" or "TP": it is used only when the deal reason is unknown.

//--- v2.10: HARDENING (review fixes)
//---   * Netting: external volume merged into the bot position is DETECTED, persisted (per position) and NEVER closed by the bot;
//---     every automatic close is refused while tainted and the contaminated result does NOT feed the risk sequence.
//---   * BREACH_MARKET: full pre-flight (SL/TP side, Stops Level, volume, margin) against the REAL market price; the lot is sized from the
//---     REAL execution price to the SL level (so the risk stays = requested risk); TP = real entry + real SL distance x R/R.
//---     Default policy is now BREACH_MARKET (SL hit -> the opposite direction is opened at once, even when the price already crossed the level).
//---   * Position without SL/TP = CRITICAL PROTECTION FAILURE: aggressive retry, critical alert, sequence frozen, emergency close after a timeout.
//---   * Magic Number guard: orphan Yetimmm orders/positions of a previous Magic block the start (no silent abandonment).
//---   * Cleanup: InpSLDistance / g_sld / g_recheckOrders removed; labels say what they really do (post-fill check, alert-only spread, recovery target).

//--- v2.00: LEVEL-SWITCH PHILOSOPHY (Upper = Buy Entry + Sell SL | Lower = Sell Entry + Buy SL)
//---   * SL of each order is the OPPOSITE level (no SL distance input any more); TP = (Upper-Lower) x Risk/Reward
//---   * ONE position at most: the unwanted pending order is removed when one fills; extra positions are closed (oldest kept)
//---   * Verified Stop-Loss close (DEAL_REASON_SL) -> BOTH Buy Stop @Upper and Sell Stop @Lower are prepared again (WAITING_REENTRY
//---     until both are on the server). TP ends the sequence (TP_RESET). Any other close reason -> no automatic re-creation.
//---   * Optional BREACH_MARKET: when the stop-out itself already crossed the opposite level (a pending order cannot exist there)
//---     the opposite direction is opened at market instead of waiting.
//--- v1.31: STOP sweep (orders first, then positions, verified) | DeleteOrder classifies by History (never "DELETED" for a FILLED order)
//---        tracked ticket == the ONLY actual order (panel + reconcile) | levels change the REAL pending order during a sequence
//---        (queued only while a real position is open) | SL/RR settings reconcile immediately
//--- v1.30: REAL MT5 state only (no virtual state)
//---   Every panel value == the real pending order on the server (ticket, price, SL, TP, volume).
//---   APPLY: Validate (incl. broker rules) -> Compare with ACTUAL MT5 -> CREATE / MODIFY / REMOVE / NOTHING
//---          -> Server retcode -> Verify the order on the server -> Panel.   No "wait for a tick" for user requests.
//---   Real tickets are tracked; manual MT5 edits / deletions are DETECTED and handled by an explicit policy.
//--- v1.20: dynamic Stop Buy / Stop Sell control
//---   Desired State -> Validate -> Reconcile -> Modify/Create/Remove -> Verify -> Sync
//---   Existing pending orders are MODIFIED in place (same ticket) instead of delete + re-create.

//--- bot states (no "cycle" concept anywhere)
enum ENUM_YT_STATE
  {
   YT_IDLE=0,
   YT_ARMED=1,
   YT_BUY_ACTIVE=2,
   YT_SELL_ACTIVE=3,
   YT_WAITING_REENTRY=4,
   YT_TP_RESET=5,
   YT_STOPPED=6,
   YT_ERROR=7
  };

//--- what to do when a pending order fills with slippage above the Max Slippage Check
//--- (MT5 cannot cap slippage on server-triggered stop orders, so it is enforced right after the fill)
enum ENUM_YT_DEV_ACTION
  {
   YT_DEV_REJECT=0,   // Reject: close the position immediately
   YT_DEV_ALERT=1     // Alert only (legacy behaviour)
  };

//--- synchronisation status of one pending order (Desired State vs Actual State on the server)
enum ENUM_YT_SYNC
  {
   YS_IDLE=0,         // no order desired on this side
   YS_SYNCED=1,       // server holds exactly the desired order
   YS_UPDATING=2,     // MODIFY in progress / awaiting server confirmation
   YS_CREATING=3,     // CREATE in progress
   YS_REMOVING=4,     // REMOVE in progress
   YS_FAILED=5,       // the server rejected the last request (old state kept)
   YS_WAITING=6,      // desired, but NOT on the server (shown as NOT PLACED + reason)
   YS_PLACED=7,       // sent AND found on the server with the requested values (shown briefly, then SYNCED)
   YS_MISSING=8,      // the tracked ticket vanished from the server (deleted / expired outside the EA)
   YS_EXTERNAL=9,     // the order was changed outside the EA (in the MT5 terminal)
   YS_FILLED=10,      // the pending order was triggered by MT5 -> real position
   YS_REMOVED=11      // the pending order was deleted and the deletion was verified on the server
  };

//--- what to do when the user moves a pending order manually in MT5
enum ENUM_YT_EXT
  {
   YT_EXT_ADOPT=0,    // MT5 is authoritative: the new price is adopted into the panel level (SL/TP re-derived)
   YT_EXT_RESTORE=1,  // the panel is authoritative: the order is moved back
   YT_EXT_HOLD=2      // do nothing automatically: flag it and wait for APPLY
  };

//--- APPLY of new levels while a risk sequence is running
enum ENUM_YT_SEQ
  {
   YT_SEQ_APPLY_NOW=0, // the REAL pending order(s) are moved immediately; only while a real POSITION is open they wait for its close
   YT_SEQ_QUEUE=1      // legacy: new levels always wait for the next TP
  };

//--- what to do when the user deletes a pending order manually in MT5
enum ENUM_YT_MISS
  {
   YT_MISS_HOLD=0,    // flag MISSING, manual intervention (APPLY / START) required
   YT_MISS_RECREATE=1 // flag MISSING and place it again (strategy allows it)
  };

//--- after a verified SL: what if the OPPOSITE level has already been crossed (a stop order cannot be placed there)?
enum ENUM_YT_BREACH
  {
   BREACH_WAIT=0,     // pending orders only: wait until the level can be placed (after a gap the move may be MISSED)
   BREACH_MARKET=1    // DEFAULT: open the opposite direction at market right after the SL (pre-flighted, lot from the real price)
  };

//--- which pending orders the bot must keep alive
#define YM_NONE 0
#define YM_BOTH 1
#define YM_BUY  2
#define YM_SELL 3

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Trading Levels ==="
input double InpBuyStop        = 0.0;     // Buy Stop Price
input double InpSellStop       = 0.0;     // Sell Stop Price

input group "=== Risk Management ==="
input double InpInitialRisk    = 1.0;     // Initial Risk ($) - lot is rounded DOWN to the broker step: real risk <= requested
input double InpTargetProfit   = 20.0;    // Recovery Target ($) - extra profit the NEXT trade must earn on top of the accumulated loss (sizes the next risk; does NOT stop the EA)
input double InpRiskReward     = 20.0;    // Risk/Reward (TP = SL distance x this)
input bool   InpResetRiskOnStart = true;  // Reset risk sequence when started after STOP

input group "=== Execution ==="
input int    InpMaxDeviation   = 30;      // Max Slippage Check (points) - checked AFTER every fill (stop orders cannot be capped by MT5); a market reversal also sends it as a price guard
input ENUM_YT_DEV_ACTION InpDevAction = YT_DEV_REJECT; // Action when a fill exceeds the Max Slippage Check
input int    InpWarnSpread     = 60;      // Spread Alert (points) - ALERT ONLY, trading is never blocked
input double InpMinLevelGap    = 0.0;     // Minimum gap between Buy/Sell levels ($)
input ENUM_YT_BREACH InpBreachPolicy = BREACH_MARKET; // After an SL: opposite level already crossed -> MARKET (immediate) or WAIT (pending only)
input bool   InpPriceFallback  = false;   // Classify SL/TP by exit price ONLY when the deal reason is unknown (never for manual / stop-out / EA closes; off = strict: DEAL_REASON only)
input bool   InpCombinedMargin  = true;    // Place a missing Buy Stop / Sell Stop pair only when the margin of BOTH missing orders is available (off = each order is checked alone)
input int    InpProtectCloseSec = 20;     // Position WITHOUT SL/TP: emergency-close after N seconds of failed protection (0 = never close, alert + retry only)

input group "=== Manual changes in MT5 ==="
input ENUM_YT_EXT  InpExtPolicy  = YT_EXT_ADOPT;   // Order moved in MT5 (ADOPT = MT5 sets ENTRY only; SL/TP re-derived)
input ENUM_YT_MISS InpMissPolicy = YT_MISS_HOLD;   // Pending order deleted manually in MT5
input ENUM_YT_SEQ  InpSeqPolicy  = YT_SEQ_APPLY_NOW; // Levels changed during a sequence

input group "=== System ==="
input long   InpMagic          = 20260101; // Magic Number (changing it while Yetimmm orders/positions of the old Magic exist blocks the start)
input bool   InpIgnoreOrphans  = false;    // Start even if orders/positions of ANOTHER Magic carry the "Yetimmm" comment (second instance / deliberate)
input bool   InpShowPanel      = true;     // Show Yetimmm panel

input group "=== Telegram ==="
input bool   InpTgEnable       = false;   // Enable Telegram
input string InpTgToken        = "";      // Telegram Bot Token
input string InpTgAuthorized   = "";      // Authorized Chat/User IDs (comma separated)
input bool   InpTgNotify       = true;    // Telegram Notifications
input bool   InpTgControl      = true;    // Telegram Control Enabled
input int    InpTgPollSec      = 2;       // Telegram polling interval (sec)

input group "=== Mini App Bridge (Cloudflare Worker) ==="
input bool   InpBrEnable       = false;   // Enable Mini App bridge
input string InpBrUrl          = "";      // Worker URL (e.g. https://limt-trading-backend.xxx.workers.dev) - add it to Tools > Options > Expert Advisors > Allowed URLs
input string InpBrKey          = "";      // Bridge Key (same value as BRIDGE_KEY secret in the Worker)
input int    InpBrPollSec      = 3;       // Bridge sync interval (sec)

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define UI "YTP_"
#define YT_REV_MAX_HARD    20       // market-reversal attempts that fail for a NON-transient reason before the bot goes to ERROR / MANUAL ACTION
#define YT_SCAN_BUFFER_SEC 21600    // history recovery safety overlap (6 h): every position is registered / logged once, so an overlap is harmless
const string TRADE_HEADER="TradeNo;OrderTicket;DealIn;DealOut;PositionID;Type;ExecType;Entry;Exit;SL;TP;Lot;RequestedRisk;TheoLossAtSL;TheoProfitAtTP;GrossProfit;Commission;Swap;NetPL;SpreadAtOpen;DeviationPts;OpenTime;CloseTime;CloseReason;BalanceBefore;BalanceAfter;AccLossBefore;AccLossAfter;RiskBefore;NextRisk;OrigBuyLevel;OrigSellLevel;Magic;Symbol;Status;Notes";
const string ORDER_HEADER="Time;Event;Side;OrderType;Price;Lot;Ticket;Magic;Symbol;Retcode;Note";

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
struct SStats
  {
   int    total,wins,losses,buys,sells,winBuy,loseBuy,winSell,loseSell;
   double totProfit,totLoss,net,avgProfit,avgLoss,maxProfit,maxLoss;
   double commission,swap,volume,highRisk,highLot,winRate;
   int    streak,consSL,consTP;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        g_trade;
string        g_sym;
long          g_magic=0;
int           g_digits=2;
int           g_lotDigits=2;
double        g_point=0.01;
double        g_tick=0.01;

ENUM_YT_STATE g_state=YT_IDLE;
int           g_mode=YM_NONE;
double        g_buyLevel=0.0;
double        g_sellLevel=0.0;
double        g_initRisk=1.0;
double        g_curRisk=1.0;
double        g_accLoss=0.0;
int           g_seq=0;
long          g_tradeNo=0;
bool          g_fresh=false;
ulong         g_lastDeal=0;
int           g_lastSLSide=0;      // 1 = a Buy was stopped out, 2 = a Sell was stopped out (0 = none)
ulong         g_nextExtraMs=0;

bool          g_connected=true;
bool          g_dirty=true;
bool          g_busy=false;
ulong         g_nextPlaceMs=0;
ulong         g_lastSyncMs=0;
int           g_failCount=0;
string        g_blockReason="";
string        g_waitReason="";
datetime      g_activeNoPosSince=0;
int           g_lastPosCount=0;
bool          g_spreadWarned=false;
bool          g_stateRecovered=false;

//--- Desired vs Actual synchronisation (index 0 = BUY STOP, 1 = SELL STOP)
int           g_sync[2]={0,0};              // ENUM_YT_SYNC per side
string        g_syncMsg[2]={"",""};
bool          g_reqBusy[2]={false,false};   // a server request for this side is in flight: no second one is sent
ulong         g_retryMs[2]={0,0};           // earliest time a failed / unconfirmed request may be repeated
int           g_failCnt[2]={0,0};
double        g_failLvl[2]={0.0,0.0};       // desired level of the last failed request (a NEW level bypasses the back-off)
bool          g_unconf[2]={false,false};    // server accepted the modify but the order does not show the new values yet
ulong         g_nextDelMs=0;

//--- REAL tickets (buyStopTicket / sellStopTicket) + the last snapshot verified on the server (index 0 = BUY STOP, 1 = SELL STOP)
ulong         g_stopTicket[2]={0,0};
double        g_snapPx[2]={0.0,0.0};
double        g_snapSL[2]={0.0,0.0};
double        g_snapTP[2]={0.0,0.0};
double        g_snapVol[2]={0.0,0.0};
bool          g_hold[2]={false,false};      // external change / missing order: no automatic action until APPLY / START
ulong         g_missMs[2]={0,0};            // first time a tracked ticket was not found (history may lag behind)
ulong         g_guardMs[2]={0,0};           // server said DONE but the order is not visible yet: do not send a second one
ulong         g_guardTk[2]={0,0};
bool          g_restartPass=false;          // a fill was registered inside Reconcile: stop this pass, re-evaluate from the new state
ulong         g_placedMs[2]={0,0};          // PLACED stays visible for a few seconds before it becomes SYNCED
string        g_uiMsg="";
color         g_uiMsgCol=clrSilver;
string        g_applyNote="";
bool          g_uiChanged=false;
string        g_uiTxt[];                    // panel cache: only changed rows are written
color         g_uiCol[];

//--- runtime configuration (inputs are the defaults; the panel can override and the values persist in a config file)
double        g_target=20.0;
double        g_rr=20.0;
int           g_maxDev=30;
int           g_warn=60;
bool          g_tgEn=false;
bool          g_tgNot=true;
bool          g_tgCtl=true;
string        g_tgTok="";
string        g_tgAuth="";
string        g_ckKey[];
string        g_ckVal[];

//--- levels entered while a sequence is running: they start only after the next TP
double        g_pendBuy=0.0;
double        g_pendSell=0.0;

//--- Netting protection / contract size / deviation / panel state
bool          g_netting=false;
bool          g_extBlock=false;
bool          g_netTaint=false;
double        g_contract=0.0;
bool          g_csWarned=false;
bool          g_cmWarned=false;        // combined-margin alert state
int           g_revHard=0;             // consecutive NON-transient market-reversal failures
ulong         g_nextDevCloseMs=0;

//--- protection guard: a position without SL/TP is a CRITICAL failure for this strategy
bool          g_unprot=false;          // some own position currently lacks SL and/or TP
ulong         g_unprotPid=0;
ulong         g_unprotSinceMs=0;
ulong         g_protNextMs=0;          // earliest time of the next protection attempt
int           g_protTries=0;
ulong         g_nextRevMs=0;           // earliest time of the next market-reversal attempt
int           g_revFails=0;
int           g_page=0;
bool          g_uiTgEn=false;
bool          g_uiTgNot=false;
bool          g_uiTgCtl=false;
string        g_edBuy="";
string        g_edSell="";
string        g_edRisk="";
bool          g_edHave=false;
bool          g_inited=false;      // OnInit completed: only then may OnDeinit overwrite the saved state

bool          g_stopCleanup=false;
int           g_stopTries=0;
int           g_stopCode=1;
long          g_stopChat=0;
datetime      g_stopLastTry=0;

SStats        g_st;
ulong         g_loggedPos[];
ulong         g_loggedDeal[];

string        g_alKey[];
datetime      g_alTime[];

//--- Telegram
long          g_tgIds[];
long          g_tgLast=0;
bool          g_tgOk=false;
datetime      g_tgLastOk=0;
datetime      g_tgLastPoll=0;
datetime      g_tgLastErrLog=0;
string        g_qText[];
long          g_qChat[];
string        g_qMarkup[];
int           g_qTry[];
string        g_lastCmdKey="";
datetime      g_lastCmdTime=0;
string        g_confAction="";
string        g_confNonce="";
datetime      g_confExpire=0;

//--- panel
string        g_rowKeys[32]={"Bot Status","Symbol",
                             "BUY STOP  Requested","BUY STOP  MT5 Actual","BUY STOP  Status",
                             "SELL STOP Requested","SELL STOP MT5 Actual","SELL STOP Status",
                             "Current Position","Current Order","Last Action",
                             "Trade Sequence","Current Risk","Current Lot","Accumulated Loss","Next Risk","Theoretical TP Profit",
                             "Risk/Reward","Connection","Spread","Current Trade #","Total Trades","Winning Trades",
                             "Losing Trades","Total Profit","Total Loss","Net P/L","Win Rate","Telegram",
                             "BUY STOP  SL | TP | Lot","SELL STOP SL | TP | Lot","Position SL | TP | Ticket"};

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void YLog(const string s) { Print("[Yetimmm] ",s); }
string D2(const double v) { return DoubleToString(v,2); }
string PX(const double v) { return DoubleToString(v,g_digits); }
string LotS(const double v) { return DoubleToString(v,g_lotDigits); }
string Money(const double v) { return (v<0.0?"-$":"+$")+DoubleToString(MathAbs(v),2); }
string TNo(const long n) { return StringFormat("%04d",(int)n); }
string UL(const ulong v) { return StringFormat("%I64u",v); }
string Clean(const string s) { string r=s; StringReplace(r,";",","); StringReplace(r,"\r"," "); StringReplace(r,"\n"," "); return r; }
double NP(const double p) { return NormalizeDouble(p,g_digits); }
double RoundTick(const double p)
  {
   if(g_tick>0.0) return NormalizeDouble(MathRound(p/g_tick)*g_tick,g_digits);
   return NP(p);
  }
bool PriceEq(const double a,const double b) { return MathAbs(a-b)<(g_tick>0.0?g_tick/2.0:g_point/2.0); }

string StateText()
  {
   switch(g_state)
     {
      case YT_IDLE:            return "IDLE";
      case YT_ARMED:           return "ARMED";
      case YT_BUY_ACTIVE:      return "BUY_ACTIVE";
      case YT_SELL_ACTIVE:     return "SELL_ACTIVE";
      case YT_WAITING_REENTRY: return "WAITING_REENTRY";
      case YT_TP_RESET:        return "TP_RESET";
      case YT_STOPPED:         return "STOPPED";
      case YT_ERROR:           return "ERROR";
     }
   return "UNKNOWN";
  }

string RunStatus()
  {
   if(g_state==YT_STOPPED) return "STOPPED";
   if(g_state==YT_ERROR)   return "ERROR";
   if(g_state==YT_IDLE || g_state==YT_TP_RESET) return "RUNNING (WAITING FOR LEVELS)";
   return "RUNNING";
  }

//+------------------------------------------------------------------+
//| Global-variable persistence                                      |
//+------------------------------------------------------------------+
string GN(const string k) { return "YT"+IntegerToString(g_magic)+"_"+k; }
bool   GHas(const string k) { return GlobalVariableCheck(GN(k)); }
double GV(const string k,const double def=0.0) { string n=GN(k); if(GlobalVariableCheck(n)) return GlobalVariableGet(n); return def; }
void   GS(const string k,const double v) { GlobalVariableSet(GN(k),v); }

string PNm(const ulong pid,const string k) { return GN("P"+UL(pid)+"_"+k); }
bool   PHas(const ulong pid,const string k) { return GlobalVariableCheck(PNm(pid,k)); }
double PGV(const ulong pid,const string k,const double def=0.0) { string n=PNm(pid,k); if(GlobalVariableCheck(n)) return GlobalVariableGet(n); return def; }
void   PSet(const ulong pid,const string k,const double v) { GlobalVariableSet(PNm(pid,k),v); }

void ClearPosGV(const ulong pid)
  {
   string keys[]={"N","R","AL","BB","SP","DV","SLP","TPP","LOT","LB","LS","TY","ET","CRC","ENT","ORD","PM","TAINT"};
   for(int i=0;i<ArraySize(keys);i++) GlobalVariableDel(PNm(pid,keys[i]));
  }

//+------------------------------------------------------------------+
//| Runtime configuration (panel-editable, persisted in a file)      |
//| Rule: if an EA input was changed since the last run, the input   |
//| wins; otherwise the value saved from the panel is restored.      |
//+------------------------------------------------------------------+
void CfgSet(const string k,const string v)
  {
   for(int i=0;i<ArraySize(g_ckKey);i++)
      if(g_ckKey[i]==k) { g_ckVal[i]=v; return; }
   int n=ArraySize(g_ckKey);
   ArrayResize(g_ckKey,n+1);
   ArrayResize(g_ckVal,n+1);
   g_ckKey[n]=k;
   g_ckVal[n]=v;
  }

bool CfgHas(const string k)
  {
   for(int i=0;i<ArraySize(g_ckKey);i++) if(g_ckKey[i]==k) return true;
   return false;
  }

string CfgGet(const string k,const string def="")
  {
   for(int i=0;i<ArraySize(g_ckKey);i++) if(g_ckKey[i]==k) return g_ckVal[i];
   return def;
  }

string CfgFile() { return "Yetimmm_"+IntegerToString(g_magic)+"_Config.cfg"; }

void CfgLoadFile()
  {
   ArrayResize(g_ckKey,0);
   ArrayResize(g_ckVal,0);
   int h=FileOpen(CfgFile(),FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE) return;
   while(!FileIsEnding(h))
     {
      string line=FileReadString(h);
      StringTrimRight(line);
      int p=StringFind(line,"=");
      if(p<=0) continue;
      CfgSet(StringSubstr(line,0,p),StringSubstr(line,p+1));
     }
   FileClose(h);
  }

void CfgSaveFile()
  {
   int h=FileOpen(CfgFile(),FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
     {
      YLog("Config file error ("+CfgFile()+") code "+IntegerToString(GetLastError()));
      return;
     }
   for(int i=0;i<ArraySize(g_ckKey);i++) FileWriteString(h,g_ckKey[i]+"="+g_ckVal[i]+"\r\n");
   FileClose(h);
  }

double CfgD(const string key,const double inp)
  {
   bool changed=(!CfgHas("in_"+key) || MathAbs(StringToDouble(CfgGet("in_"+key))-inp)>1e-9);
   double eff=(changed || !CfgHas(key))?inp:StringToDouble(CfgGet(key));
   CfgSet("in_"+key,DoubleToString(inp,8));
   CfgSet(key,DoubleToString(eff,8));
   return eff;
  }

bool CfgB(const string key,const bool inp)
  {
   bool changed=(!CfgHas("in_"+key) || (CfgGet("in_"+key)=="1")!=inp);
   bool eff=(changed || !CfgHas(key))?inp:(CfgGet(key)=="1");
   CfgSet("in_"+key,inp?"1":"0");
   CfgSet(key,eff?"1":"0");
   return eff;
  }

string CfgS(const string key,const string inp)
  {
   bool changed=(!CfgHas("in_"+key) || CfgGet("in_"+key)!=inp);
   string eff=(changed || !CfgHas(key))?inp:CfgGet(key);
   CfgSet("in_"+key,inp);
   CfgSet(key,eff);
   return eff;
  }

void CfgPutAll()
  {
   CfgSet("target",DoubleToString(g_target,8));
   CfgSet("rr",DoubleToString(g_rr,8));
   CfgSet("maxdev",DoubleToString((double)g_maxDev,8));
   CfgSet("warn",DoubleToString((double)g_warn,8));
   CfgSet("tgen",g_tgEn?"1":"0");
   CfgSet("tgnot",g_tgNot?"1":"0");
   CfgSet("tgctl",g_tgCtl?"1":"0");
   CfgSet("tgtok",g_tgTok);
   CfgSet("tgauth",g_tgAuth);
  }

void CfgInit()
  {
   CfgLoadFile();
   g_target=CfgD("target",InpTargetProfit);
   g_rr=CfgD("rr",InpRiskReward);
   g_maxDev=(int)CfgD("maxdev",(double)InpMaxDeviation);
   g_warn=(int)CfgD("warn",(double)InpWarnSpread);
   g_tgEn=CfgB("tgen",InpTgEnable);
   g_tgNot=CfgB("tgnot",InpTgNotify);
   g_tgCtl=CfgB("tgctl",InpTgControl);
   g_tgTok=CfgS("tgtok",InpTgToken);
   g_tgAuth=CfgS("tgauth",InpTgAuthorized);
   //--- a corrupted/edited config file must never produce unusable parameters
   if(!MathIsValidNumber(g_rr) || g_rr<=0.0 ||
      !MathIsValidNumber(g_target) || g_target<0.0 || g_maxDev<0 || g_warn<0)
     {
      YLog("Config file values invalid - falling back to EA inputs.");
      g_target=InpTargetProfit; g_rr=InpRiskReward;
      g_maxDev=InpMaxDeviation; g_warn=InpWarnSpread;
      g_tgEn=InpTgEnable; g_tgNot=InpTgNotify; g_tgCtl=InpTgControl;
      g_tgTok=InpTgToken; g_tgAuth=InpTgAuthorized;
      CfgPutAll();
     }
   CfgSaveFile();
  }

void SaveState()
  {
   GS("STATE",(double)g_state);
   GS("MODE",(double)g_mode);
   GS("BL",g_buyLevel);
   GS("SLV",g_sellLevel);
   GS("IR",g_initRisk);
   GS("CRK",g_curRisk);
   GS("AL",g_accLoss);
   GS("SEQ",(double)g_seq);
   GS("TNO",(double)g_tradeNo);
   GS("FRESH",g_fresh?1.0:0.0);
   GS("LDEAL",(double)g_lastDeal);
   GS("PBL",g_pendBuy);
   GS("PSL",g_pendSell);
   GS("LSLS",(double)g_lastSLSide);
   GlobalVariablesFlush();
  }

void LoadState()
  {
   if(GHas("STATE"))
     {
      g_state=(ENUM_YT_STATE)(int)GV("STATE",0);
      g_mode=(int)GV("MODE",0);
      g_buyLevel=GV("BL",0);
      g_sellLevel=GV("SLV",0);
      g_initRisk=GV("IR",InpInitialRisk);
      g_curRisk=GV("CRK",g_initRisk);
      g_accLoss=GV("AL",0);
      g_seq=(int)GV("SEQ",0);
      g_tradeNo=(long)GV("TNO",0);
      g_fresh=(GV("FRESH",0)>0.5);
      g_lastDeal=(ulong)GV("LDEAL",0);
      g_pendBuy=GV("PBL",0);
      g_pendSell=GV("PSL",0);
      g_lastSLSide=(int)GV("LSLS",0);
      //--- v2.00 migration: a single-side re-entry saved by an older version becomes "both sides"
      if((g_state==YT_ARMED || g_state==YT_WAITING_REENTRY) && (g_mode==YM_BUY || g_mode==YM_SELL)) g_mode=YM_BOTH;
      g_stateRecovered=true;
     }
   else
     {
      g_state=YT_IDLE; g_mode=YM_NONE; g_buyLevel=0; g_sellLevel=0;
      g_initRisk=InpInitialRisk; g_curRisk=InpInitialRisk; g_accLoss=0; g_seq=0;
      g_tradeNo=(long)GV("TNO",0); g_fresh=false; g_lastDeal=0; g_pendBuy=0; g_pendSell=0; g_lastSLSide=0;
      g_stateRecovered=false;
     }
   if(g_state==YT_BUY_ACTIVE || g_state==YT_SELL_ACTIVE) g_activeNoPosSince=0;
  }

void ResetRisk()
  {
   g_accLoss=0.0;
   g_seq=0;
   g_curRisk=g_initRisk;
  }

double NextRiskFor(const double L)
  {
   if(L<=1e-9) return g_initRisk;
   return (L+g_target)/g_rr;
  }

//+------------------------------------------------------------------+
//| Alerts                                                           |
//+------------------------------------------------------------------+
bool AlertThrottle(const string key,const int sec)
  {
   for(int i=0;i<ArraySize(g_alKey);i++)
      if(g_alKey[i]==key)
        {
         if(TimeLocal()-g_alTime[i]<sec) return false;
         g_alTime[i]=TimeLocal();
         return true;
        }
   int n=ArraySize(g_alKey);
   ArrayResize(g_alKey,n+1);
   ArrayResize(g_alTime,n+1);
   g_alKey[n]=key;
   g_alTime[n]=TimeLocal();
   return true;
  }

void ClearAlert(const string key)
  {
   for(int i=0;i<ArraySize(g_alKey);i++)
      if(g_alKey[i]==key) g_alTime[i]=0;
  }

void RaiseAlert(const string key,const string msg,const bool popup=true,const bool tg=true)
  {
   if(!AlertThrottle(key,60)) return;
   Print("[Yetimmm] ALERT: ",msg);
   if(popup && !MQLInfoInteger(MQL_TESTER)) Alert("Yetimmm: ",msg);
   if(tg) TgQueue("⚠️ "+msg);
  }

//+------------------------------------------------------------------+
//| File logging (Orders log / Trades log)                           |
//+------------------------------------------------------------------+
string TradeFile() { return "Yetimmm_"+IntegerToString(g_magic)+"_Trades.csv"; }
string OrderFile() { return "Yetimmm_"+IntegerToString(g_magic)+"_Orders.csv"; }

void AppendLine(const string file,const string header,const string line)
  {
   int h=FileOpen(file,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
     {
      YLog("File error ("+file+") code "+IntegerToString(GetLastError()));
      return;
     }
   if(FileSize(h)==0) FileWriteString(h,header+"\r\n");
   FileSeek(h,0,SEEK_END);
   FileWriteString(h,line+"\r\n");
   FileFlush(h);
   FileClose(h);
  }

string OTypeStr(const long t)
  {
   switch((int)t)
     {
      case ORDER_TYPE_BUY_STOP:  return "BUY_STOP";
      case ORDER_TYPE_SELL_STOP: return "SELL_STOP";
      case ORDER_TYPE_BUY:       return "BUY";
      case ORDER_TYPE_SELL:      return "SELL";
      case ORDER_TYPE_BUY_LIMIT: return "BUY_LIMIT";
      case ORDER_TYPE_SELL_LIMIT:return "SELL_LIMIT";
     }
   return "OTHER";
  }

void LogOrder(const string ev,const long otype,const double price,const double lot,const ulong ticket,const uint rc,const string note)
  {
   string side="";
   if(otype==ORDER_TYPE_BUY_STOP || otype==ORDER_TYPE_BUY) side="BUY";
   else if(otype==ORDER_TYPE_SELL_STOP || otype==ORDER_TYPE_SELL) side="SELL";
   string line=TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+";"+ev+";"+side+";"+OTypeStr(otype)+";"+PX(price)+";"+LotS(lot)+";"+
               UL(ticket)+";"+IntegerToString(g_magic)+";"+g_sym+";"+IntegerToString((int)rc)+";"+Clean(note);
   AppendLine(OrderFile(),ORDER_HEADER,line);
  }

bool IsLoggedPos(const ulong pid)
  {
   for(int i=0;i<ArraySize(g_loggedPos);i++) if(g_loggedPos[i]==pid) return true;
   return false;
  }
bool IsLoggedDeal(const ulong d)
  {
   if(d==0) return false;
   for(int i=0;i<ArraySize(g_loggedDeal);i++) if(g_loggedDeal[i]==d) return true;
   return false;
  }
void MarkLogged(const ulong pid,const ulong d)
  {
   int n=ArraySize(g_loggedPos); ArrayResize(g_loggedPos,n+1); g_loggedPos[n]=pid;
   n=ArraySize(g_loggedDeal);    ArrayResize(g_loggedDeal,n+1); g_loggedDeal[n]=d;
  }

void StatsReset()
  {
   ZeroMemory(g_st);
  }

void StatsAdd(const double net,const double comm,const double swap,const string type,const double lot,const double risk,const string reason)
  {
   g_st.total++;
   bool buy=(type=="BUY");
   bool rej=(reason=="Deviation Reject");
   if(buy) g_st.buys++; else g_st.sells++;
   if(net>0.0)
     {
      g_st.wins++; g_st.totProfit+=net;
      if(net>g_st.maxProfit) g_st.maxProfit=net;
      if(buy) g_st.winBuy++; else g_st.winSell++;
      if(!rej) g_st.streak=(g_st.streak>0)?g_st.streak+1:1;
     }
   else if(net<0.0)
     {
      g_st.losses++; g_st.totLoss+=MathAbs(net);
      if(MathAbs(net)>g_st.maxLoss) g_st.maxLoss=MathAbs(net);
      if(buy) g_st.loseBuy++; else g_st.loseSell++;
      if(!rej) g_st.streak=(g_st.streak<0)?g_st.streak-1:-1;
     }
   g_st.net=g_st.totProfit-g_st.totLoss;
   g_st.commission+=comm;
   g_st.swap+=swap;
   g_st.volume+=lot;
   if(risk>g_st.highRisk) g_st.highRisk=risk;
   if(lot>g_st.highLot) g_st.highLot=lot;
   if(reason=="SL") g_st.consSL++; else if(!rej) g_st.consSL=0;
   if(reason=="TP") g_st.consTP++; else if(!rej) g_st.consTP=0;
   g_st.avgProfit=(g_st.wins>0)?g_st.totProfit/g_st.wins:0.0;
   g_st.avgLoss=(g_st.losses>0)?g_st.totLoss/g_st.losses:0.0;
   g_st.winRate=(g_st.total>0)?100.0*g_st.wins/g_st.total:0.0;
  }

//--- load the persistent trade log: fills the dedupe arrays and the statistics
void LoadTradeLog()
  {
   ArrayResize(g_loggedPos,0);
   ArrayResize(g_loggedDeal,0);
   StatsReset();
   int h=FileOpen(TradeFile(),FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE) return;
   bool first=true;
   while(!FileIsEnding(h))
     {
      string line=FileReadString(h);
      if(StringLen(line)==0) continue;
      if(first) { first=false; continue; }
      string f[];
      int c=StringSplit(line,';',f);
      if(c<30) continue;
      ulong pid=(ulong)StringToInteger(f[4]);
      ulong dout=(ulong)StringToInteger(f[3]);
      MarkLogged(pid,dout);
      if(c>34 && StringFind(f[34],"TAINTED")>=0) continue;     // Netting-contaminated rows are not part of the statistics
      StatsAdd(StringToDouble(f[18]),StringToDouble(f[16]),StringToDouble(f[17]),f[5],StringToDouble(f[11]),StringToDouble(f[12]),f[23]);
     }
   FileClose(h);
  }

int ReadTradeLines(string &lines[])
  {
   ArrayResize(lines,0);
   int h=FileOpen(TradeFile(),FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE) return 0;
   bool first=true;
   while(!FileIsEnding(h))
     {
      string line=FileReadString(h);
      if(StringLen(line)==0) continue;
      if(first) { first=false; continue; }
      int n=ArraySize(lines);
      ArrayResize(lines,n+1);
      lines[n]=line;
     }
   FileClose(h);
   return ArraySize(lines);
  }

//+------------------------------------------------------------------+
//| Symbol / price helpers                                           |
//+------------------------------------------------------------------+
//--- v2.00: Upper = Buy Entry + Sell SL, Lower = Sell Entry + Buy SL
//--- SL distance = Upper - Lower. 0.0 when no valid pair of levels exists: a distance is never invented.
double SLDist()
  {
   if(g_buyLevel>0.0 && g_sellLevel>0.0 && g_buyLevel>g_sellLevel) return g_buyLevel-g_sellLevel;
   return 0.0;
  }
//--- 0.0 = no valid opposite level (callers treat it as "cannot compute")
double SLPrice(const bool buy,const double entry)
  {
   if(buy  && g_sellLevel>0.0 && g_sellLevel<entry) return RoundTick(g_sellLevel);
   if(!buy && g_buyLevel>0.0  && g_buyLevel>entry)  return RoundTick(g_buyLevel);
   return 0.0;
  }
double TPPrice(const bool buy,const double entry)
  {
   double d=SLDist()*g_rr;
   if(d<=0.0) return 0.0;
   return RoundTick(buy?entry+d:entry-d);
  }

//--- Contract Size: cross-check + last-resort fallback for the loss-per-lot calculation
bool ProfitCcyIsAccount()
  {
   return (SymbolInfoString(g_sym,SYMBOL_CURRENCY_PROFIT)==AccountInfoString(ACCOUNT_CURRENCY));
  }

void VerifyContract(const double dist,const double brokerPerLot)
  {
   if(g_contract<=0.0 || !ProfitCcyIsAccount() || dist<=0.0) return;
   double expected=dist*g_contract;
   if(MathAbs(brokerPerLot-expected)/expected>0.02 && !g_csWarned)
     {
      g_csWarned=true;
      string m="Contract Size check: broker loss per lot "+D2(brokerPerLot)+" differs from SL distance x Contract Size ("+D2(dist)+" x "+DoubleToString(g_contract,2)+" = "+D2(expected)+
               "). Lot sizing uses the broker value (OrderCalcProfit). Verify the symbol specification.";
      YLog(m);
      RaiseAlert("CSIZE",m,true,true);
     }
  }

//--- loss of ONE lot between an explicit entry and an explicit SL (broker specifications)
double PerLotLossSL(const bool buy,const double entry,const double sl)
  {
   if(sl<=0.0 || entry<=0.0 || MathAbs(entry-sl)<1e-12) return 0.0;
   double profit=0.0;
   ENUM_ORDER_TYPE ot=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(OrderCalcProfit(ot,g_sym,1.0,entry,sl,profit) && profit<0.0)
     {
      VerifyContract(MathAbs(entry-sl),-profit);
      return -profit;
     }
   double tv=SymbolInfoDouble(g_sym,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv<=0.0) tv=SymbolInfoDouble(g_sym,SYMBOL_TRADE_TICK_VALUE);
   if(tv>0.0 && g_tick>0.0) return MathAbs(entry-sl)/g_tick*tv;
   if(g_contract>0.0 && ProfitCcyIsAccount()) return MathAbs(entry-sl)*g_contract;
   return 0.0;
  }

//--- stop-order sizing: entry = the level, SL = the opposite level
double PerLotLoss(const bool buy,const double entry)
  {
   return PerLotLossSL(buy,entry,SLPrice(buy,entry));
  }

//--- Risk Amount -> Lot, using real broker specifications (explicit entry AND explicit SL)
bool CalcLotSL(const double risk,const bool buy,const double entry,const double sl,double &lot,double &estLoss,string &err)
  {
   lot=0.0; estLoss=0.0; err="";
   double perLot=PerLotLossSL(buy,entry,sl);
   if(perLot<=0.0) { err="Cannot determine loss per lot from broker specifications."; return false; }
   double step=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_MAX);
   if(step<=0.0) step=vmin>0.0?vmin:0.01;
   double raw=risk/perLot;
   double fl=MathFloor(raw/step+1e-7)*step;
   fl=NormalizeDouble(fl,g_lotDigits);
   if(fl<vmin-1e-9) { err="Required lot is below broker minimum volume."; return false; }
   if(fl>vmax+1e-9) { err="Required lot exceeds broker maximum volume."; return false; }
   lot=fl;
   estLoss=fl*perLot;
   double margin=0.0;
   ENUM_ORDER_TYPE ot=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(OrderCalcMargin(ot,g_sym,fl,entry,margin))
      if(margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
        { err="Insufficient margin for required risk."; return false; }
   return true;
  }

//--- stop-order sizing: SL = the opposite level
bool CalcLot(const double risk,const bool buy,const double entry,double &lot,double &estLoss,string &err)
  {
   return CalcLotSL(risk,buy,entry,SLPrice(buy,entry),lot,estLoss,err);
  }

//--- PRE-FLIGHT of a MARKET order against the REAL prices (the same discipline PlacementOk applies to pending orders):
//--- trading allowed for the direction, SL and TP present, on the correct side of the market, outside the broker Stops Level
bool MarketPreflight(const bool buy,const double sl,const double tp,string &why)
  {
   why="";
   MqlTick t;
   if(!SymbolInfoTick(g_sym,t) || t.ask<=0.0 || t.bid<=0.0) { why="No market prices"; return false; }
   long tm=SymbolInfoInteger(g_sym,SYMBOL_TRADE_MODE);
   if(tm==SYMBOL_TRADE_MODE_DISABLED || tm==SYMBOL_TRADE_MODE_CLOSEONLY) { why="Trading is disabled for this symbol"; return false; }
   if(tm==SYMBOL_TRADE_MODE_LONGONLY && !buy)  { why="Only long trades are allowed on this symbol"; return false; }
   if(tm==SYMBOL_TRADE_MODE_SHORTONLY && buy)  { why="Only short trades are allowed on this symbol"; return false; }
   if((SymbolInfoInteger(g_sym,SYMBOL_ORDER_MODE) & SYMBOL_ORDER_MARKET)==0) { why="Market orders are not allowed on this symbol"; return false; }
   if(!MathIsValidNumber(sl) || !MathIsValidNumber(tp) || sl<=0.0 || tp<=0.0) { why="SL/TP could not be computed"; return false; }
   double stopsLvl=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_STOPS_LEVEL)*g_point;
   if(buy)
     {
      if(sl>=t.bid)                          why="SL "+PX(sl)+" is not below the Bid "+PX(t.bid);
      else if(t.bid-sl<stopsLvl-1e-9)        why="SL "+PX(sl)+" is inside the Stops Level ("+PX(stopsLvl)+")";
      else if(tp<=t.bid)                     why="TP "+PX(tp)+" is not above the Bid "+PX(t.bid);
      else if(tp-t.bid<stopsLvl-1e-9)        why="TP "+PX(tp)+" is inside the Stops Level ("+PX(stopsLvl)+")";
     }
   else
     {
      if(sl<=t.ask)                          why="SL "+PX(sl)+" is not above the Ask "+PX(t.ask);
      else if(sl-t.ask<stopsLvl-1e-9)        why="SL "+PX(sl)+" is inside the Stops Level ("+PX(stopsLvl)+")";
      else if(tp>=t.ask)                     why="TP "+PX(tp)+" is not below the Ask "+PX(t.ask);
      else if(t.ask-tp<stopsLvl-1e-9)        why="TP "+PX(tp)+" is inside the Stops Level ("+PX(stopsLvl)+")";
     }
   return (why=="");
  }

string ValidateRisk(const double r)
  {
   if(!MathIsValidNumber(r) || r<=0.0) return "Initial Risk must be greater than zero.";
   return "";
  }

string ValidateLevels(const double buy,const double sell)
  {
   if(!MathIsValidNumber(buy) || !MathIsValidNumber(sell) || buy<=0.0 || sell<=0.0) return "Prices must be positive numbers.";
   if(MathAbs(buy-sell)<(g_tick>0.0?g_tick/2.0:g_point/2.0)) return "Buy Stop and Sell Stop must not be equal.";
   if(buy<sell) return "Buy Stop must be higher than Sell Stop.";
   if(MathAbs(buy-NP(buy))>1e-9 || MathAbs(sell-NP(sell))>1e-9) return "Prices have more decimals than the symbol allows.";
   if(g_tick>0.0)
     {
      double q1=buy/g_tick, q2=sell/g_tick;
      if(MathAbs(q1-MathRound(q1))>1e-3 || MathAbs(q2-MathRound(q2))>1e-3) return "Prices must be multiples of the tick size ("+DoubleToString(g_tick,g_digits)+").";
     }
   if(buy-sell<InpMinLevelGap-1e-9) return "Distance between levels is below the minimum gap ("+D2(InpMinLevelGap)+").";
   long tm=SymbolInfoInteger(g_sym,SYMBOL_TRADE_MODE);
   if(tm==SYMBOL_TRADE_MODE_DISABLED || tm==SYMBOL_TRADE_MODE_CLOSEONLY) return "Trading is disabled for this symbol.";
   double stopsLvl=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_STOPS_LEVEL)*g_point;
   if(buy-sell<stopsLvl-1e-9) return "Distance between the levels (= Stop Loss) is below the broker minimum stops level.";
   return "";
  }

//+------------------------------------------------------------------+
//| Own positions / orders                                           |
//+------------------------------------------------------------------+
int OwnPositions(ulong &tk[])
  {
   ArrayResize(tk,0);
   int n=PositionsTotal();
   for(int i=0;i<n;i++)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=g_magic) continue;
      int k=ArraySize(tk);
      ArrayResize(tk,k+1);
      tk[k]=t;
     }
   return ArraySize(tk);
  }

int OwnOrders(ulong &tk[])
  {
   ArrayResize(tk,0);
   int n=OrdersTotal();
   for(int i=0;i<n;i++)
     {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_sym) continue;
      if((long)OrderGetInteger(ORDER_MAGIC)!=g_magic) continue;
      int k=ArraySize(tk);
      ArrayResize(tk,k+1);
      tk[k]=t;
     }
   return ArraySize(tk);
  }

//--- find a live position by its identifier and leave it selected
bool FindLive(const ulong pid,ulong &ticket)
  {
   int n=PositionsTotal();
   for(int i=0;i<n;i++)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==pid) { ticket=t; return true; }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Real-ticket tracking: ticket + last snapshot verified on server  |
//+------------------------------------------------------------------+
void TrkStore(const int s)
  {
   string i=IntegerToString(s);
   GS("TKT"+i,(double)g_stopTicket[s]);
   GS("TKP"+i,g_snapPx[s]);
   GS("TKS"+i,g_snapSL[s]);
   GS("TKQ"+i,g_snapTP[s]);
   GS("TKV"+i,g_snapVol[s]);
  }

void TrkLoad()
  {
   for(int s=0;s<2;s++)
     {
      string i=IntegerToString(s);
      g_stopTicket[s]=(ulong)GV("TKT"+i,0.0);
      g_snapPx[s]=GV("TKP"+i,0.0);
      g_snapSL[s]=GV("TKS"+i,0.0);
      g_snapTP[s]=GV("TKQ"+i,0.0);
      g_snapVol[s]=GV("TKV"+i,0.0);
     }
  }

void TrkDrop(const int s)
  {
   g_stopTicket[s]=0;
   g_snapPx[s]=0.0; g_snapSL[s]=0.0; g_snapTP[s]=0.0; g_snapVol[s]=0.0;
   g_missMs[s]=0;
   TrkStore(s);
  }

void TrkDropTicket(const ulong ticket)
  {
   for(int s=0;s<2;s++)
      if(g_stopTicket[s]==ticket) TrkDrop(s);
  }

//--- the baseline = what the server REALLY holds for this ticket right now
bool TrkTake(const bool buy,const ulong ticket)
  {
   if(ticket==0 || !OrderSelect(ticket)) return false;
   int s=buy?0:1;
   g_stopTicket[s]=ticket;
   g_snapPx[s]=OrderGetDouble(ORDER_PRICE_OPEN);
   g_snapSL[s]=OrderGetDouble(ORDER_SL);
   g_snapTP[s]=OrderGetDouble(ORDER_TP);
   g_snapVol[s]=OrderGetDouble(ORDER_VOLUME_CURRENT);
   g_missMs[s]=0;
   TrkStore(s);
   return true;
  }

//--- outside Armed states nothing is tracked or held any more
void TrkPrune()
  {
   for(int s=0;s<2;s++)
     {
      g_hold[s]=false;
      g_missMs[s]=0;
      if(g_stopTicket[s]!=0 && !OrderSelect(g_stopTicket[s])) TrkDrop(s);
     }
  }

bool g_delFilled=false;   // set by DeleteOrder when the order was NOT deleted because MT5 filled it

bool DeleteOrder(const ulong ticket,const string reason)
  {
   g_delFilled=false;
   double price=0.0,vol=0.0; long type=-1;
   if(OrderSelect(ticket))
     {
      price=OrderGetDouble(ORDER_PRICE_OPEN);
      vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
      type=OrderGetInteger(ORDER_TYPE);
     }
   bool r=g_trade.OrderDelete(ticket);
   uint rc=g_trade.ResultRetcode();
   bool ok=(r && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED));
   if(ok)
     {
      //--- a successful call is not enough: the order must really be gone from the server
      for(int w=0;w<6 && OrderSelect(ticket);w++) Sleep(60);
      if(OrderSelect(ticket)) ok=false;
     }
   string ev=ok?"DELETED":"DELETE_FAILED";
   string why=reason;
   if(!ok && !OrderSelect(ticket))
     {
      //--- the ticket vanished although our delete did not succeed: a vanished order is NOT automatically a deleted order
      bool inH=false;
      for(int w=0;w<5 && !(inH=HistoryOrderSelect(ticket));w++) Sleep(60);
      long hs=inH?HistoryOrderGetInteger(ticket,ORDER_STATE):-1;
      if(inH && (hs==ORDER_STATE_FILLED || hs==ORDER_STATE_PARTIAL))
        {
         g_delFilled=true;
         TrkDropTicket(ticket);
         LogOrder("FILLED_BEFORE_DELETE",type,price,vol,ticket,rc,reason+" | order was FILLED by MT5, a position exists");
         YLog("Order #"+UL(ticket)+" was FILLED before it could be deleted - NOT reported as deleted ("+reason+")");
         g_dirty=true;
         return false;
        }
      ok=true;
      if(inH && hs==ORDER_STATE_EXPIRED)       { ev="EXPIRED";  why=reason+" | expired on the server"; }
      else if(inH && hs==ORDER_STATE_CANCELED) { ev="DELETED";  why=reason+" | cancelled (confirmed by history)"; }
      else if(!inH)                            { ev="DELETED_UNCONFIRMED"; why=reason+" | gone from the server, history not available yet"; }
     }
   if(ok) TrkDropTicket(ticket);
   LogOrder(ev,type,price,vol,ticket,rc,why);
   YLog((ok?"Order "+ev+" #":"Order Delete FAILED #")+UL(ticket)+" ("+why+")");
   return ok;
  }

//+------------------------------------------------------------------+
//| Desired State / Actual State synchronisation                     |
//| DESIRED = what the bot wants on the server (level, SL, TP, lot)  |
//| ACTUAL  = what the server really holds                           |
//| Reconcile compares both per side and sends the smallest request: |
//| KEEP / MODIFY (same ticket) / CREATE / REMOVE                    |
//+------------------------------------------------------------------+
int SideIdx(const bool buy) { return buy?0:1; }
string SideName(const bool buy) { return buy?"BUY STOP":"SELL STOP"; }

string SyncText(const int st)
  {
   switch(st)
     {
      case YS_SYNCED:   return "SYNCED";
      case YS_PLACED:   return "PLACED";
      case YS_UPDATING: return "MODIFYING...";
      case YS_CREATING: return "PLACING...";
      case YS_REMOVING: return "REMOVING...";
      case YS_REMOVED:  return "REMOVED";
      case YS_FILLED:   return "FILLED";
      case YS_MISSING:  return "MISSING";
      case YS_EXTERNAL: return "EXTERNAL CHANGE";
      case YS_FAILED:   return "FAILED";
      case YS_WAITING:  return "NOT PLACED";
     }
   return "IDLE";
  }

color SyncColor(const int st)
  {
   switch(st)
     {
      case YS_SYNCED:   return clrLime;
      case YS_PLACED:   return clrSpringGreen;
      case YS_UPDATING: return clrDeepSkyBlue;
      case YS_CREATING: return clrDeepSkyBlue;
      case YS_REMOVING: return clrOrange;
      case YS_REMOVED:  return clrOrange;
      case YS_FILLED:   return clrAqua;
      case YS_MISSING:  return clrTomato;
      case YS_EXTERNAL: return clrGold;
      case YS_FAILED:   return clrTomato;
      case YS_WAITING:  return clrGold;
     }
   return clrSilver;
  }

void SetSync(const bool buy,const int st,const string msg="")
  {
   int s=SideIdx(buy);
   g_sync[s]=st;
   g_syncMsg[s]=msg;
  }

void PanelMsg(const string txt,const color c=clrSilver)
  {
   g_uiMsg=txt;
   g_uiMsgCol=c;
  }

//--- is a pending order wanted on this side right now, and at which level?
bool SideDesired(const bool buy,double &level)
  {
   level=buy?g_buyLevel:g_sellLevel;
   if(g_state!=YT_ARMED && g_state!=YT_WAITING_REENTRY) return false;
   if(g_mode==YM_NONE) return false;
   bool need=buy?(g_mode==YM_BOTH || g_mode==YM_BUY):(g_mode==YM_BOTH || g_mode==YM_SELL);
   return (need && level>0.0);
  }

//--- the real pending order of this side on the server (first match)
//--- THE canonical ticket of a side (single source of truth for panel AND reconcile):
//--- 1) the tracked ticket, 2) an order at the desired price, 3) the lowest ticket (deterministic)
ulong CanonicalTicket(const bool buy,const double level)
  {
   int s=SideIdx(buy);
   long want=buy?(long)ORDER_TYPE_BUY_STOP:(long)ORDER_TYPE_SELL_STOP;
   ulong tk=g_stopTicket[s];
   if(tk!=0 && OrderSelect(tk) && OrderGetInteger(ORDER_TYPE)==want &&
      OrderGetString(ORDER_SYMBOL)==g_sym && (long)OrderGetInteger(ORDER_MAGIC)==g_magic) return tk;
   ulong od[];
   int n=OwnOrders(od);
   ulong best=0; bool bestExact=false;
   for(int i=0;i<n;i++)
     {
      if(!OrderSelect(od[i])) continue;
      if(OrderGetInteger(ORDER_TYPE)!=want) continue;
      bool ex=(level>0.0 && PriceEq(OrderGetDouble(ORDER_PRICE_OPEN),level));
      if(best==0 || (ex && !bestExact) || (ex==bestExact && od[i]<best)) { best=od[i]; bestExact=ex; }
     }
   return best;
  }

bool SideActual(const bool buy,ulong &ticket,double &price)
  {
   ticket=0; price=0.0;
   ulong t=CanonicalTicket(buy,buy?g_buyLevel:g_sellLevel);
   if(t==0 || !OrderSelect(t)) return false;
   ticket=t;
   price=OrderGetDouble(ORDER_PRICE_OPEN);
   return true;
  }

//--- status for the panel: SYNCED is only shown when the server really holds the desired order
int SideStatusShown(const bool buy)
  {
   int s=SideIdx(buy);
   double lvl;
   ulong tk; double ap;
   bool have=SideActual(buy,tk,ap);
   if(!SideDesired(buy,lvl))
     {
      if(!have)
        {
         int ls=g_sync[s];
         return (ls==YS_FILLED || ls==YS_REMOVED)?ls:YS_IDLE;
        }
      return (g_sync[s]==YS_FAILED)?YS_FAILED:YS_REMOVING;
     }
   int st=g_sync[s];
   if(st==YS_IDLE) return YS_WAITING;
   if(st==YS_SYNCED || st==YS_PLACED)
     {
      if(!have) return YS_CREATING;
      if(!PriceEq(ap,lvl)) return YS_UPDATING;
     }
   return st;
  }

string SyncSummary()
  {
   string s="";
   for(int k=0;k<2;k++)
     {
      bool b=(k==0);
      double l;
      if(!SideDesired(b,l)) continue;
      if(s!="") s+=" | ";
      int st=SideStatusShown(b);
      ulong stk; double sap;
      s+=(b?"BUY ":"SELL ")+PX(l)+" "+SyncText(st);
      if(SideActual(b,stk,sap)) s+=" #"+UL(stk);
      if((st==YS_FAILED || st==YS_WAITING || st==YS_MISSING || st==YS_EXTERNAL) && StringLen(g_syncMsg[k])>0) s+=" ("+g_syncMsg[k]+")";
     }
   if(s=="") s="no pending order desired";
   return s;
  }

//--- a user action (APPLY / START) always gets a fresh attempt
void ResetSyncBackoff()
  {
   for(int k=0;k<2;k++)
     {
      g_retryMs[k]=0; g_failCnt[k]=0; g_failLvl[k]=0.0; g_unconf[k]=false;
      g_hold[k]=false; g_missMs[k]=0; g_guardMs[k]=0;      // a user action releases every hold
     }
   g_nextDelMs=0;
  }

bool TradingAllowedNow(string &why)
  {
   why="";
   if(!g_connected) why="No connection to the trade server";
   else if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) why="AutoTrading is disabled";
   else if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) why="Trading not allowed on this account";
   return (why=="");
  }

//--- can a stop order of this side sit at this price right now? (symbol rules + broker minimum distance)
bool PlacementOk(const bool buy,const double price,string &why)
  {
   why="";
   if(!MathIsValidNumber(price) || price<=0.0) { why="Invalid price"; return false; }
   double tkSz=(g_tick>0.0)?g_tick:g_point;
   if(MathAbs(price-RoundTick(price))>tkSz*1e-3) { why="Price is not a multiple of the tick size"; return false; }
   long tm=SymbolInfoInteger(g_sym,SYMBOL_TRADE_MODE);
   if(tm==SYMBOL_TRADE_MODE_DISABLED || tm==SYMBOL_TRADE_MODE_CLOSEONLY) { why="Trading is disabled for this symbol"; return false; }
   if(tm==SYMBOL_TRADE_MODE_LONGONLY && !buy)  { why="Only long trades are allowed on this symbol"; return false; }
   if(tm==SYMBOL_TRADE_MODE_SHORTONLY && buy)  { why="Only short trades are allowed on this symbol"; return false; }
   if((SymbolInfoInteger(g_sym,SYMBOL_ORDER_MODE) & SYMBOL_ORDER_STOP)==0) { why="Stop orders are not allowed on this symbol"; return false; }
   MqlTick t;
   if(!SymbolInfoTick(g_sym,t) || t.ask<=0.0 || t.bid<=0.0) { why="No market prices"; return false; }
   double stopsLvl=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_STOPS_LEVEL)*g_point;
   if(buy)
     {
      if(price<=t.ask) { why="Buy Stop must be above the Ask ("+PX(t.ask)+")"; return false; }
      if(price-t.ask<stopsLvl-1e-9) { why="too close to market (Stops Level "+PX(stopsLvl)+")"; return false; }
     }
   else
     {
      if(price>=t.bid) { why="Sell Stop must be below the Bid ("+PX(t.bid)+")"; return false; }
      if(t.bid-price<stopsLvl-1e-9) { why="too close to market (Stops Level "+PX(stopsLvl)+")"; return false; }
     }
   return true;
  }

//--- a pending order that is within the Freeze Level of the market can be neither modified nor deleted
bool FrozenNow(const bool buy,const double orderPrice)
  {
   double fz=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_FREEZE_LEVEL)*g_point;
   if(fz<=0.0) return false;
   MqlTick t;
   if(!SymbolInfoTick(g_sym,t)) return false;
   return buy?(orderPrice-t.ask<=fz+1e-9):(t.bid-orderPrice<=fz+1e-9);
  }

//--- APPLY pre-check: when a live order has to be MODIFIED, the new price must be acceptable right now
string CheckModifiable(const double buy,const double sell)
  {
   for(int k=0;k<2;k++)
     {
      bool b=(k==0);
      double nl=b?buy:sell;
      ulong tk; double ap;
      if(!SideActual(b,tk,ap)) continue;        // no live order on this side: it is simply created
      if(PriceEq(ap,nl)) continue;              // price unchanged
      string why;
      if(!PlacementOk(b,nl,why)) return SideName(b)+" "+PX(nl)+" cannot be applied now: "+why;
      if(FrozenNow(b,ap)) return SideName(b)+" cannot be modified now: the order is inside the Freeze Level.";
     }
   return "";
  }

//--- APPLY pre-check = broker rules BEFORE anything is sent: a request that cannot become a real order is rejected with the reason
string CheckApplicableCore(const double buy,const double sell,const double risk)
  {
   string why;
   if(!TradingAllowedNow(why)) return "Trading is not possible now: "+why;
   double rk=(g_accLoss<=1e-9)?(risk>0.0?risk:g_initRisk):g_curRisk;
   for(int k=0;k<2;k++)
     {
      bool b=(k==0);
      double nl=b?buy:sell;
      bool seq1=((g_state==YT_ARMED || g_state==YT_WAITING_REENTRY) && (g_mode==YM_BUY || g_mode==YM_SELL));
      if(seq1 && ((b && g_mode==YM_SELL) || (!b && g_mode==YM_BUY))) continue;   // that side has no order in this sequence
      ulong tk; double ap;
      if(SideActual(b,tk,ap))
        {
         if(!PriceEq(ap,nl))
           {
            if(!PlacementOk(b,nl,why)) return SideName(b)+" "+PX(nl)+" cannot be applied now: "+why;
            if(FrozenNow(b,ap)) return SideName(b)+" cannot be modified now: the order is inside the Freeze Level.";
           }
        }
      else if(g_state!=YT_WAITING_REENTRY && !PlacementOk(b,nl,why)) return SideName(b)+" "+PX(nl)+" cannot be placed now: "+why;
      double lot,est; string le;
      if(!CalcLot(rk,b,nl,lot,est,le)) return SideName(b)+": "+le;
     }
   return "";
  }

//--- the SL of each order is the OTHER level, so the lot/SL check must use the candidate levels, not the active ones
string CheckApplicable(const double buy,const double sell,const double risk)
  {
   const double ob=g_buyLevel, os=g_sellLevel;
   g_buyLevel=buy; g_sellLevel=sell;
   string r=CheckApplicableCore(buy,sell,risk);
   g_buyLevel=ob; g_sellLevel=os;
   return r;
  }

void ModifyFailed(const bool buy,const ulong ticket,const long otype,const double vol,const double actualPx,const double level,const uint rc,const string descIn)
  {
   int s=SideIdx(buy);
   string desc=descIn;
   if(StringLen(desc)==0) desc="request rejected";
   MqlTick t;
   double cur=0.0;
   if(SymbolInfoTick(g_sym,t)) cur=buy?t.ask:t.bid;
   g_failCnt[s]++;
   g_failLvl[s]=level;
   ulong delay=(ulong)MathMin(30000.0,1500.0*MathPow(2.0,(double)MathMin(g_failCnt[s]-1,5)));
   if(rc==TRADE_RETCODE_MARKET_CLOSED) delay=30000;
   else if(rc==TRADE_RETCODE_TOO_MANY_REQUESTS && delay<10000) delay=10000;
   g_retryMs[s]=GetTickCount64()+delay;
   string rcs=(rc>0)?" [retcode "+IntegerToString((int)rc)+"]":"";
   string msg="MODIFY FAILED: "+desc+rcs;
   SetSync(buy,YS_FAILED,msg);
   PanelMsg(SideName(buy)+" "+msg,clrTomato);
   LogOrder("MODIFY_FAILED",otype,level,vol,ticket,rc,desc+" | Actual "+PX(actualPx)+" | Market "+PX(cur));
   YLog("MODIFY FAILED | "+SideName(buy)+" | Ticket "+UL(ticket)+" | Retcode "+IntegerToString((int)rc)+" ("+desc+") | Requested "+PX(level)+" | Actual "+PX(actualPx)+" | Market "+PX(cur));
   bool first=(g_failCnt[s]==1);
   RaiseAlert("MODFAIL"+IntegerToString(s),"MODIFY FAILED ("+SideName(buy)+"): "+desc+rcs+" | Ticket "+UL(ticket)+" | Requested "+PX(level)+" | Current "+PX(cur)+" | Actual "+PX(actualPx),first,first);
  }

//+------------------------------------------------------------------+
//| MODIFY the existing pending order in place: the Ticket, Magic,   |
//| Comment, Volume and expiration are kept; only price / SL / TP    |
//| are sent. One request per order at a time; the result is read    |
//| from the server before the status becomes SYNCED.                |
//+------------------------------------------------------------------+
bool ModifySide(const bool buy,const ulong ticket,const double level,const double dSL,const double dTP)
  {
   int s=SideIdx(buy);
   if(g_reqBusy[s]) return false;                    // never two requests for the same order at once
   if(!OrderSelect(ticket)) return false;
   long   otype=OrderGetInteger(ORDER_TYPE);
   double aP=OrderGetDouble(ORDER_PRICE_OPEN);
   double aV=OrderGetDouble(ORDER_VOLUME_CURRENT);
   double hs=((g_tick>0.0)?g_tick:g_point)/2.0;
   ulong  nowMs=GetTickCount64();

   if(!PriceEq(g_failLvl[s],level)) { g_failCnt[s]=0; g_retryMs[s]=0; g_unconf[s]=false; }   // a NEW desired level always gets a fresh attempt
   if(nowMs<g_retryMs[s]) return false;              // back-off after a failure / waiting for the server to show the change
   if(g_unconf[s])
     {
      g_unconf[s]=false;
      ModifyFailed(buy,ticket,otype,aV,aP,level,0,"server accepted the request but the order still shows the old values");
      return false;
     }

   //--- pre-flight validation: a request that is known to be invalid is never sent
   string why;
   if(!TradingAllowedNow(why))                           { SetSync(buy,YS_WAITING,why); return false; }
   if(!PriceEq(aP,level) && !PlacementOk(buy,level,why)) { SetSync(buy,YS_WAITING,"Cannot modify now: "+why); return false; }
   if(FrozenNow(buy,aP))                                 { SetSync(buy,YS_WAITING,"Order is inside the Freeze Level"); return false; }

   //--- send ONE modify request
   g_reqBusy[s]=true;
   SetSync(buy,YS_UPDATING,"Modify "+PX(aP)+" -> "+PX(level));
   UpdatePanel();                                    // the panel shows UPDATING while the server works
   g_trade.SetDeviationInPoints(g_maxDev);
   bool r=g_trade.OrderModify(ticket,level,dSL,dTP,ORDER_TIME_GTC,0);
   uint rc=g_trade.ResultRetcode();
   string desc=g_trade.ResultRetcodeDescription();
   g_reqBusy[s]=false;
   bool ok=((r && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED)) || rc==TRADE_RETCODE_NO_CHANGES);
   if(!ok)
     {
      ModifyFailed(buy,ticket,otype,aV,aP,level,rc,desc);   // old state is kept, nothing is reported as modified
      return false;
     }

   //--- verify with the server: the order must now carry the requested values
   if(!OrderSelect(ticket))
     {
      SetSync(buy,YS_UPDATING,"Order no longer pending (triggered?)");
      g_dirty=true;
      return false;
     }
   bool conf=(PriceEq(OrderGetDouble(ORDER_PRICE_OPEN),level) &&
              MathAbs(OrderGetDouble(ORDER_SL)-dSL)<=hs && MathAbs(OrderGetDouble(ORDER_TP)-dTP)<=hs);
   if(!conf)
     {
      g_unconf[s]=true;
      g_failLvl[s]=level;
      g_retryMs[s]=GetTickCount64()+2000;
      SetSync(buy,YS_UPDATING,"Awaiting server confirmation");
      g_dirty=true;
      return false;
     }

   g_failCnt[s]=0; g_failLvl[s]=0.0; g_retryMs[s]=0; g_unconf[s]=false;
   TrkTake(buy,ticket);                              // baseline = the values the server confirmed
   SetSync(buy,YS_SYNCED,"");
   ClearAlert("MODFAIL"+IntegerToString(s));
   string note="Ticket "+UL(ticket)+" kept | "+PX(aP)+" -> "+PX(level)+" | SL "+PX(dSL)+" TP "+PX(dTP);
   LogOrder("MODIFIED",otype,level,aV,ticket,rc,note);
   YLog(SideName(buy)+" MODIFIED | "+note);
   PanelMsg(SideName(buy)+" modified "+PX(aP)+" -> "+PX(level),clrLime);
   TgQueue("✏️ "+SideName(buy)+" MODIFIED\nTicket: "+UL(ticket)+" (kept)\nOld: "+PX(aP)+"\nNew: "+PX(level)+"\nSL: "+PX(dSL)+"\nTP: "+PX(dTP));
   return true;
  }

//+------------------------------------------------------------------+
//| Verification of a freshly placed order on the server             |
//+------------------------------------------------------------------+
bool VerifyPlaced(const ulong ticket,const bool buy,const double level,const double lot,const double sl,const double tp,string &why)
  {
   why="";
   if(ticket==0) { why="the server returned no ticket"; return false; }
   double hs=((g_tick>0.0)?g_tick:g_point)/2.0;
   double step=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP);
   if(step<=0.0) step=0.01;
   for(int i=0;i<6;i++)
     {
      if(OrderSelect(ticket))
        {
         long want=buy?(long)ORDER_TYPE_BUY_STOP:(long)ORDER_TYPE_SELL_STOP;
         if(OrderGetInteger(ORDER_TYPE)!=want) { why="wrong order type on the server"; return false; }
         double aP=OrderGetDouble(ORDER_PRICE_OPEN), aV=OrderGetDouble(ORDER_VOLUME_CURRENT);
         double aS=OrderGetDouble(ORDER_SL), aT=OrderGetDouble(ORDER_TP);
         if(PriceEq(aP,level) && MathAbs(aV-lot)<=step/2.0 && MathAbs(aS-sl)<=hs && MathAbs(aT-tp)<=hs) return true;
         why="MT5 holds price "+PX(aP)+" lot "+LotS(aV)+" SL "+PX(aS)+" TP "+PX(aT);
         return false;
        }
      Sleep(50);
     }
   why="order #"+UL(ticket)+" not found on the server";
   return false;
  }

//--- when MT5 is authoritative the panel edit box follows the real order (unless the user is typing something else)
void PanelSetLevelText(const bool buy,const double oldLevel,const double newLevel)
  {
   if(!InpShowPanel || g_page!=0) return;
   string n=UI+(buy?"ED_BUY":"ED_SELL");
   if(ObjectFind(0,n)<0) return;
   double cur=ParseNum(ObjectGetString(0,n,OBJPROP_TEXT));
   if(cur<=0.0 || PriceEq(cur,oldLevel)) ObjectSetString(0,n,OBJPROP_TEXT,PX(newLevel));
  }

//+------------------------------------------------------------------+
//| External changes: the user moved / deleted the order in MT5      |
//| Returns true when this side must NOT be reconciled in this pass  |
//+------------------------------------------------------------------+
bool ExternalCheck(const bool buy,const bool need,const double level)
  {
   int s=SideIdx(buy);
   double hs=((g_tick>0.0)?g_tick:g_point)/2.0;
   long wantType=buy?(long)ORDER_TYPE_BUY_STOP:(long)ORDER_TYPE_SELL_STOP;

   //--- explicit HOLD: nothing changes automatically until the real order matches the panel again or the user presses APPLY / START
   if(g_hold[s])
     {
      ulong hT; double hP;
      if(!need || !SideActual(buy,hT,hP) || !PriceEq(hP,level)) return true;
      g_hold[s]=false;
      TrkTake(buy,hT);
      YLog(SideName(buy)+" is back in line with the panel - hold released");
      return false;
     }

   ulong tk=g_stopTicket[s];
   if(tk==0) return false;                            // not tracked yet (it is adopted by ReconcileSide)
   if(g_reqBusy[s] || g_unconf[s]) return false;      // our own request is still being confirmed

   //--- 1) the ticket exists: did somebody change it outside the EA?
   if(OrderSelect(tk))
     {
      g_missMs[s]=0;
      if(OrderGetInteger(ORDER_TYPE)!=wantType) return false;
      double p=OrderGetDouble(ORDER_PRICE_OPEN), sl=OrderGetDouble(ORDER_SL), tp=OrderGetDouble(ORDER_TP), v=OrderGetDouble(ORDER_VOLUME_CURRENT);
      bool pxChg=!PriceEq(p,g_snapPx[s]);
      bool stChg=(MathAbs(sl-g_snapSL[s])>hs || MathAbs(tp-g_snapTP[s])>hs);
      if(!pxChg && !stChg) return false;

      string what=pxChg?("price "+PX(g_snapPx[s])+" -> "+PX(p)):("SL "+PX(g_snapSL[s])+" -> "+PX(sl)+" / TP "+PX(g_snapTP[s])+" -> "+PX(tp));
      string msg=SideName(buy)+" EXTERNAL CHANGE DETECTED | Ticket #"+UL(tk)+" | "+what;
      LogOrder("EXTERNAL_CHANGE",wantType,p,v,tk,0,what);
      YLog(msg);
      RaiseAlert("EXT"+IntegerToString(s),msg,true,true);
      TrkTake(buy,tk);                                // the new MT5 state is the baseline: it is reported only once
      if(!need) return false;

      bool holdIt=(InpExtPolicy==YT_EXT_HOLD);
      string note="";
      if(!holdIt && pxChg && InpExtPolicy==YT_EXT_ADOPT)
        {
         string e=ValidateLevels(buy?p:g_buyLevel,buy?g_sellLevel:p);
         if(e=="")
           {
            //--- MT5 is authoritative: the panel level becomes the real order price (SL / TP are re-derived by the reconcile)
            if(buy) g_buyLevel=p; else g_sellLevel=p;
            SaveState();
            PanelSetLevelText(buy,level,p);
            SetSync(buy,YS_EXTERNAL,"MT5 price adopted: "+PX(level)+" -> "+PX(p));
            PanelMsg(SideName(buy)+" EXTERNAL CHANGE: panel level now "+PX(p),clrGold);
            TgQueue("⚠️ EXTERNAL CHANGE DETECTED\n"+SideName(buy)+" Ticket #"+UL(tk)+"\nMT5 price: "+PX(p)+" (panel was "+PX(level)+")\nPolicy: MT5 adopted.");
            g_dirty=true;
            return false;
           }
         holdIt=true;                                 // adopting would break the level rules: explicit hold instead
         note=" (cannot adopt: "+e+")";
        }
      if(holdIt)
        {
         g_hold[s]=true;
         SetSync(buy,YS_EXTERNAL,"Panel "+PX(level)+" vs MT5 "+PX(p)+" - press APPLY to enforce the panel"+note);
         PanelMsg(SideName(buy)+" EXTERNAL CHANGE: hold, press APPLY",clrGold);
         TgQueue("⚠️ EXTERNAL CHANGE DETECTED\n"+SideName(buy)+" Ticket #"+UL(tk)+"\nMT5 price: "+PX(p)+"\nPanel: "+PX(level)+"\nNo automatic action. Press APPLY to enforce the panel."+note);
         return true;
        }
      //--- RESTORE (or an SL / TP-only change under ADOPT): the reconcile that follows puts the same ticket back
      SetSync(buy,YS_EXTERNAL,"Restoring panel values on ticket #"+UL(tk));
      PanelMsg(SideName(buy)+" EXTERNAL CHANGE: restoring panel values",clrGold);
      TgQueue("⚠️ EXTERNAL CHANGE DETECTED\n"+SideName(buy)+" Ticket #"+UL(tk)+"\nPolicy: panel values are restored on the same ticket.");
      return false;
     }

   //--- 2) the ticket is gone from the server
   ulong pp[];
   if(OwnPositions(pp)>0) { TrkDrop(s); return true; }                 // triggered meanwhile: the position logic takes over
   bool inHist=HistoryOrderSelect(tk);
   long hst=inHist?HistoryOrderGetInteger(tk,ORDER_STATE):-1;
   if(inHist && (hst==ORDER_STATE_FILLED || hst==ORDER_STATE_PARTIAL))
     {
      //--- triggered and possibly already closed (fast market): book the position immediately, never wait for the 30 s history scan
      ulong fpid=(ulong)HistoryOrderGetInteger(tk,ORDER_POSITION_ID);
      TrkDrop(s);
      if(fpid!=0)
        {
         YLog(SideName(buy)+" #"+UL(tk)+" was FILLED - registering position "+UL(fpid)+" now");
         RegisterPosition(fpid);
         CheckClosures();
        }
      g_restartPass=true;
      g_dirty=true;
      return true;
     }
   if(!inHist)
     {
      if(g_missMs[s]==0) g_missMs[s]=GetTickCount64();
      if(GetTickCount64()-g_missMs[s]<3000) return true;              // history may lag behind the trade server
     }
   g_missMs[s]=0;
   TrkDrop(s);
   if(!need) return false;

   string how=inHist?((hst==ORDER_STATE_EXPIRED)?"expired":"deleted / cancelled"):"no longer on the server";
   string mm=SideName(buy)+" MISSING | Ticket #"+UL(tk)+" "+how+" outside the EA";
   LogOrder("MISSING",wantType,level,0.0,tk,0,how);
   YLog(mm);
   RaiseAlert("MISS"+IntegerToString(s),mm,true,true);
   if(InpMissPolicy==YT_MISS_RECREATE)
     {
      SetSync(buy,YS_MISSING,"Ticket #"+UL(tk)+" missing - placing it again");
      PanelMsg(SideName(buy)+" MISSING: placing again",clrGold);
      TgQueue("⚠️ "+SideName(buy)+" MISSING\nTicket #"+UL(tk)+" "+how+".\nPolicy: placing it again.");
      return false;
     }
   g_hold[s]=true;
   SetSync(buy,YS_MISSING,"Ticket #"+UL(tk)+" "+how+" - press APPLY / START to place it again");
   PanelMsg(SideName(buy)+" MISSING: manual intervention",clrTomato);
   TgQueue("⚠️ "+SideName(buy)+" MISSING\nTicket #"+UL(tk)+" "+how+".\nManual intervention required: press APPLY / START to place it again.");
   return true;
  }

//+------------------------------------------------------------------+
//| One side of Reconcile: KEEP / MODIFY / REPLACE (lot only) / CREATE|
//+------------------------------------------------------------------+
void ReconcileSide(const bool buy,const double level,const double expLot,const bool lotOk,const ulong ticket)
  {
   int s=SideIdx(buy);
   if(ticket==0 || !OrderSelect(ticket))
     {
      //--- no order on the server: CREATE (the only case where a brand-new pending order is sent)
      if(GetTickCount64()<g_guardMs[s])
        {
         //--- the server answered DONE a moment ago but the order is not visible yet: never send a second one
         SetSync(buy,YS_CREATING,"Awaiting server confirmation of #"+UL(g_guardTk[s]));
         return;
        }
      g_unconf[s]=false;
      if(g_sync[s]!=YS_FAILED && g_sync[s]!=YS_WAITING) SetSync(buy,YS_CREATING,"");
      TryPlace(buy,level);                           // sets WAITING / FAILED / SYNCED itself
      return;
     }
   double hs=((g_tick>0.0)?g_tick:g_point)/2.0;
   double step=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP);
   if(step<=0.0) step=0.01;
   if(g_stopTicket[s]!=ticket) TrkTake(buy,ticket);   // adopt the real ticket (restart / first run); the order stays selected
   g_guardMs[s]=0;
   double aP=OrderGetDouble(ORDER_PRICE_OPEN);
   double aSL=OrderGetDouble(ORDER_SL);
   double aTP=OrderGetDouble(ORDER_TP);
   double aV=OrderGetDouble(ORDER_VOLUME_CURRENT);
   long   aT=OrderGetInteger(ORDER_TYPE);
   double dSL=SLPrice(buy,level), dTP=TPPrice(buy,level);
   if(dSL<=0.0 || dTP<=0.0)
     {
      //--- never send an order/modification without a computed SL/TP (no invented distance any more)
      SetSync(buy,YS_WAITING,"Levels invalid: SL/TP cannot be computed");
      return;
     }
   bool volDiff=(lotOk && MathAbs(aV-expLot)>step/2.0);
   bool diff=(!PriceEq(aP,level) || MathAbs(aSL-dSL)>hs || MathAbs(aTP-dTP)>hs);

   if(volDiff)
     {
      //--- MT5 cannot change the volume of a pending order: the ONLY case that needs delete + create
      if(GetTickCount64()<g_nextDelMs) return;
      string why="Lot changed (risk update): volume cannot be modified, order is replaced";
      if(FrozenNow(buy,aP)) { SetSync(buy,YS_WAITING,"Order is inside the Freeze Level"); return; }
      SetSync(buy,YS_UPDATING,why);
      UpdatePanel();
      if(DeleteOrder(ticket,why))
        {
         g_unconf[s]=false;
         SetSync(buy,YS_CREATING,"");
         TryPlace(buy,level);
        }
      else
        {
         g_nextDelMs=GetTickCount64()+2000;
         SetSync(buy,YS_FAILED,"REPLACE FAILED: could not delete the old order");
        }
      return;
     }

   if(!diff)
     {
      //--- KEEP: the server already holds exactly the desired order, nothing is sent
      if(g_unconf[s])
        {
         LogOrder("MODIFIED",aT,aP,aV,ticket,0,"Confirmed by server | "+PX(aP)+" SL "+PX(aSL)+" TP "+PX(aTP));
         YLog(SideName(buy)+" MODIFIED (confirmed) | Ticket "+UL(ticket)+" | "+PX(aP));
         PanelMsg(SideName(buy)+" modified -> "+PX(aP),clrLime);
        }
      g_failCnt[s]=0; g_failLvl[s]=0.0; g_retryMs[s]=0; g_unconf[s]=false;
      if(g_sync[s]==YS_FAILED) ClearAlert("MODFAIL"+IntegerToString(s));
      TrkTake(buy,ticket);                           // input == EA state == MT5 state: this is the verified baseline
      if(g_sync[s]==YS_PLACED && GetTickCount64()-g_placedMs[s]<5000) return;   // keep PLACED visible briefly
      SetSync(buy,YS_SYNCED,"");
      return;
     }

   //--- MODIFY the existing order (same ticket / magic / comment / volume)
   ModifySide(buy,ticket,level,dSL,dTP);
  }

//+------------------------------------------------------------------+
//| Netting protection                                               |
//| In a Netting account every deal on the symbol merges into ONE    |
//| position, so the bot cannot separate its trade from a foreign    |
//| one. Rule: never place orders while a foreign position exists,   |
//| never close volume that is not ours.                             |
//+------------------------------------------------------------------+
bool IsNettingAccount()
  {
   return ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

//--- volume of positions on this symbol that were NOT opened by this bot (other magic / manual)
double ExternalPositionVolume()
  {
   double v=0.0;
   int n=PositionsTotal();
   for(int i=0;i<n;i++)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)==g_magic) continue;
      v+=PositionGetDouble(POSITION_VOLUME);
     }
   return v;
  }

//--- true => the bot must stay frozen (Netting + foreign position). Resumes by itself when it is gone.
bool NettingBlocked()
  {
   if(!g_netting) return false;
   double ev=ExternalPositionVolume();
   if(ev<=0.0)
     {
      if(g_extBlock)
        {
         g_extBlock=false;
         g_blockReason="";
         ClearAlert("NETEXT");
         YLog("Netting: external position closed - bot resumed.");
        }
      return false;
     }
   if(!g_extBlock)
     {
      g_extBlock=true;
      YLog("Netting: external "+g_sym+" position detected ("+LotS(ev)+" lots) - bot frozen, its own pending orders are removed.");
     }
   g_blockReason="Netting account: external "+g_sym+" position ("+LotS(ev)+" lots) - bot frozen";
   ulong od[];
   int no=OwnOrders(od);
   for(int i=0;i<no;i++) DeleteOrder(od[i],"Netting: external position present");
   RaiseAlert("NETEXT","Netting account: an external "+g_sym+" position exists. Yetimmm places no orders and does not touch it. It resumes automatically once that position is closed.",true,true);
   return true;
  }

//--- Netting: own position volume must equal the lot the bot registered; otherwise foreign volume merged into it
void NettingDriftCheck(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   double reg=PGV(pid,"LOT",0.0);
   if(reg<=0.0) return;
   double vol=PositionGetDouble(POSITION_VOLUME);
   double step=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP);
   if(step<=0.0) step=0.01;
   bool bad=(MathAbs(vol-reg)>step/2.0);
   if(bad)
     {
      //--- persisted PER POSITION: survives a restart, and the result of this position never feeds the risk sequence
      if(PGV(pid,"TAINT",0.0)<0.5) { PSet(pid,"TAINT",1.0); GlobalVariablesFlush(); }
      if(!g_netTaint)
        {
         g_netTaint=true;
         YLog("Netting: position volume "+LotS(vol)+" differs from registered lot "+LotS(reg)+" - foreign volume merged. Automatic closing is DISABLED and the risk sequence will NOT be updated from this position.");
         RaiseAlert("NETDRIFT","Netting account: an external trade changed the Yetimmm position volume ("+LotS(vol)+" vs "+LotS(reg)+"). Yetimmm will NOT close it, and the risk sequence will NOT be updated from its result - handle it manually.",true,true);
        }
     }
   else if(g_netTaint)
     {
      g_netTaint=false;                     // closing is allowed again; the position stays flagged (its P/L is not purely ours)
      ClearAlert("NETDRIFT");
      YLog("Netting: position volume matches the registered lot again.");
     }
  }

//--- every AUTOMATIC close goes through this guard: never close volume that is not ours
bool NetTaintRefusesClose(const string what)
  {
   if(!(g_netting && g_netTaint)) return false;
   RaiseAlert("NETCLOSE","Netting account: the Yetimmm position contains external volume, so "+what+" was NOT executed automatically. Handle it manually.",true,true);
   return true;
  }

//+------------------------------------------------------------------+
//| Telegram                                                         |
//+------------------------------------------------------------------+
bool TgActive()
  {
   if(!g_tgEn) return false;
   if(MQLInfoInteger(MQL_TESTER)) return false;
   if(StringLen(g_tgTok)==0) return false;
   if(ArraySize(g_tgIds)==0) return false;
   return true;
  }

void ParseIds()
  {
   ArrayResize(g_tgIds,0);
   string s=g_tgAuth;
   StringReplace(s,";",",");
   StringReplace(s," ",",");
   string p[];
   int n=StringSplit(s,',',p);
   for(int i=0;i<n;i++)
     {
      if(StringLen(p[i])==0) continue;
      long v=StringToInteger(p[i]);
      if(v==0) continue;
      int k=ArraySize(g_tgIds);
      ArrayResize(g_tgIds,k+1);
      g_tgIds[k]=v;
     }
  }

bool TgAuthorized(const long from)
  {
   for(int i=0;i<ArraySize(g_tgIds);i++) if(g_tgIds[i]==from) return true;
   return false;
  }

string UrlEnc(const string s)
  {
   char b[];
   int n=StringToCharArray(s,b,0,WHOLE_ARRAY,CP_UTF8);
   string out="";
   for(int i=0;i<n-1;i++)
     {
      int c=((int)b[i])&0xFF;
      if((c>='0'&&c<='9')||(c>='a'&&c<='z')||(c>='A'&&c<='Z')||c=='-'||c=='_'||c=='.'||c=='~')
         out+=ShortToString((ushort)c);
      else
         out+=StringFormat("%%%02X",c);
     }
   return out;
  }

void TgPush(const long chat,const string text,const string markup)
  {
   int n=ArraySize(g_qText);
   if(n>=60)
     {
      for(int i=1;i<n;i++) { g_qText[i-1]=g_qText[i]; g_qChat[i-1]=g_qChat[i]; g_qMarkup[i-1]=g_qMarkup[i]; g_qTry[i-1]=g_qTry[i]; }
      n--;
     }
   ArrayResize(g_qText,n+1);
   ArrayResize(g_qChat,n+1);
   ArrayResize(g_qMarkup,n+1);
   ArrayResize(g_qTry,n+1);
   g_qText[n]=text; g_qChat[n]=chat; g_qMarkup[n]=markup; g_qTry[n]=0;
  }

void TgPop()
  {
   int n=ArraySize(g_qText);
   if(n<=0) return;
   for(int i=1;i<n;i++) { g_qText[i-1]=g_qText[i]; g_qChat[i-1]=g_qChat[i]; g_qMarkup[i-1]=g_qMarkup[i]; g_qTry[i-1]=g_qTry[i]; }
   ArrayResize(g_qText,n-1);
   ArrayResize(g_qChat,n-1);
   ArrayResize(g_qMarkup,n-1);
   ArrayResize(g_qTry,n-1);
  }

//--- chat==0 -> broadcast to every authorized id (requires Notifications enabled)
void TgQueue(const string text,const long chat=0,const string markup="")
  {
   if(!g_tgEn) return;
   if(chat==0)
     {
      if(!g_tgNot) return;
      for(int i=0;i<ArraySize(g_tgIds);i++) TgPush(g_tgIds[i],text,markup);
     }
   else TgPush(chat,text,markup);
  }

//--- low-level Telegram request (token is never logged)
bool TgCall(const string method,const string body,string &resp)
  {
   resp="";
   string url="https://api.telegram.org/bot"+g_tgTok+"/"+method;
   char data[],res[];
   string rh;
   int n=StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8);
   if(n>0) ArrayResize(data,n-1);
   ResetLastError();
   int code=WebRequest("POST",url,"Content-Type: application/x-www-form-urlencoded\r\n",3000,data,res,rh);
   if(code==-1)
     {
      int e=GetLastError();
      g_tgOk=false;
      if(TimeLocal()-g_tgLastErrLog>=60)
        {
         g_tgLastErrLog=TimeLocal();
         if(e==4014) YLog("Telegram Connection Error: add https://api.telegram.org to Tools > Options > Expert Advisors > Allowed URLs (error 4014).");
         else YLog("Telegram Connection Error: WebRequest failed, error "+IntegerToString(e));
        }
      return false;
     }
   resp=CharArrayToString(res,0,WHOLE_ARRAY,CP_UTF8);
   if(code!=200 || StringFind(resp,"\"ok\":true")<0)
     {
      g_tgOk=false;
      if(TimeLocal()-g_tgLastErrLog>=60)
        {
         g_tgLastErrLog=TimeLocal();
         YLog("Telegram Connection Error: HTTP "+IntegerToString(code)+" (check Bot Token / Chat ID)");
        }
      return false;
     }
   g_tgOk=true;
   g_tgLastOk=TimeLocal();
   return true;
  }

bool TgSend(const long chat,const string text,const string markup)
  {
   string t=text;
   if(StringLen(t)>3900) t=StringSubstr(t,0,3900)+"\n...";
   string body="chat_id="+IntegerToString(chat)+"&text="+UrlEnc(t)+"&disable_web_page_preview=true";
   if(StringLen(markup)>0) body+="&reply_markup="+UrlEnc(markup);
   string resp;
   return TgCall("sendMessage",body,resp);
  }

void TgFlush()
  {
   if(!TgActive()) { if(ArraySize(g_qText)>60) TgPop(); return; }
   if(!g_connected) return;
   int sent=0;
   while(ArraySize(g_qText)>0 && sent<5)
     {
      if(TgSend(g_qChat[0],g_qText[0],g_qMarkup[0]))
        {
         YLog("Telegram Notification Sent");
         TgPop();
         sent++;
        }
      else
        {
         g_qTry[0]++;
         if(g_qTry[0]>=5) TgPop(); // drop a message that keeps failing
         break;
        }
     }
  }

string MenuMarkup()
  {
   return "{\"inline_keyboard\":[[{\"text\":\"▶️ START\",\"callback_data\":\"CMD:start\"},{\"text\":\"⏹ STOP\",\"callback_data\":\"CMD:stop\"}],"
          "[{\"text\":\"❌ CANCEL\",\"callback_data\":\"CMD:cancel\"},{\"text\":\"📊 STATUS\",\"callback_data\":\"CMD:status\"}],"
          "[{\"text\":\"📜 HISTORY\",\"callback_data\":\"CMD:history\"},{\"text\":\"📈 STATS\",\"callback_data\":\"CMD:stats\"}],"
          "[{\"text\":\"⚙️ SETTINGS\",\"callback_data\":\"CMD:settings\"},{\"text\":\"❓ HELP\",\"callback_data\":\"CMD:help\"}]]}";
  }

string ConfirmMarkup(const string nonce,const string yes,const string no)
  {
   return "{\"inline_keyboard\":[[{\"text\":\""+yes+"\",\"callback_data\":\"C1:"+nonce+"\"},{\"text\":\""+no+"\",\"callback_data\":\"C0:"+nonce+"\"}]]}";
  }

//--- minimal JSON helpers
int HexDigit(const ushort c)
  {
   if(c>='0' && c<='9') return c-'0';
   if(c>='a' && c<='f') return c-'a'+10;
   if(c>='A' && c<='F') return c-'A'+10;
   return 0;
  }

string JStr(const string seg,const string marker)
  {
   int a=StringFind(seg,marker);
   if(a<0) return "";
   int i=a+StringLen(marker);
   int L=StringLen(seg);
   string out="";
   while(i<L)
     {
      ushort c=StringGetCharacter(seg,i);
      if(c==92 && i+1<L)
        {
         ushort d=StringGetCharacter(seg,i+1);
         if(d=='n') { out+="\n"; i+=2; continue; }
         if(d=='t') { out+=" "; i+=2; continue; }
         if(d=='r') { i+=2; continue; }
         if(d=='u' && i+5<L)
           {
            int code=0;
            for(int k=0;k<4;k++) code=code*16+HexDigit(StringGetCharacter(seg,i+2+k));
            out+=ShortToString((ushort)code);
            i+=6;
            continue;
           }
         out+=ShortToString(d);
         i+=2;
         continue;
        }
      if(c==34) break;
      out+=ShortToString(c);
      i++;
     }
   return out;
  }

long JNum(const string seg,const string marker,bool &found)
  {
   found=false;
   int a=StringFind(seg,marker);
   if(a<0) return 0;
   int i=a+StringLen(marker);
   int L=StringLen(seg);
   string s="";
   while(i<L)
     {
      ushort c=StringGetCharacter(seg,i);
      if((c>='0' && c<='9') || (c=='-' && s==""))
        { s+=ShortToString(c); i++; }
      else break;
     }
   if(s=="" || s=="-") return 0;
   found=true;
   return StringToInteger(s);
  }

//+------------------------------------------------------------------+
//| Status texts                                                     |
//+------------------------------------------------------------------+
bool OwnPosInfo(ulong &ticket,ulong &pid,bool &buy,double &vol,double &entry,double &sl,double &tp,double &profit)
  {
   ulong tk[];
   if(OwnPositions(tk)<1) return false;
   ticket=tk[ArraySize(tk)-1];
   if(!PositionSelectByTicket(ticket)) return false;
   pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   vol=PositionGetDouble(POSITION_VOLUME);
   entry=PositionGetDouble(POSITION_PRICE_OPEN);
   sl=PositionGetDouble(POSITION_SL);
   tp=PositionGetDouble(POSITION_TP);
   profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   return true;
  }

//--- current / planned lot and estimated loss at SL
bool CurrentLotInfo(double &lot,double &est,string &err)
  {
   lot=0; est=0; err="";
   ulong tk,pid; bool buy; double vol,entry,sl,tp,pr;
   if(OwnPosInfo(tk,pid,buy,vol,entry,sl,tp,pr))
     {
      lot=vol;
      double lvl=buy?g_buyLevel:g_sellLevel;
      if(lvl<=0.0) lvl=entry;
      est=vol*PerLotLoss(buy,lvl);
      return true;
     }
   bool useBuy=(g_mode!=YM_SELL);
   double level=useBuy?g_buyLevel:g_sellLevel;
   if(level<=0.0) { err="No valid levels"; return false; }
   return CalcLot(g_curRisk,useBuy,level,lot,est,err);
  }

string OrdersText()
  {
   ulong od[];
   int n=OwnOrders(od);
   if(n==0) return "No Pending Orders";
   string s="Pending Orders\n";
   for(int i=0;i<n;i++)
     {
      if(!OrderSelect(od[i])) continue;
      long t=OrderGetInteger(ORDER_TYPE);
      s+=(t==ORDER_TYPE_BUY_STOP?"Buy Stop: ":"Sell Stop: ")+PX(OrderGetDouble(ORDER_PRICE_OPEN))+"  Lot: "+LotS(OrderGetDouble(ORDER_VOLUME_CURRENT))+"  SL: "+PX(OrderGetDouble(ORDER_SL))+"  TP: "+PX(OrderGetDouble(ORDER_TP))+"  Ticket: #"+UL(od[i])+"\n";
     }
   return s;
  }

string OpenText()
  {
   ulong tk,pid; bool buy; double vol,entry,sl,tp,pr;
   if(!OwnPosInfo(tk,pid,buy,vol,entry,sl,tp,pr)) return "No Open Position";
   double cur=buy?SymbolInfoDouble(g_sym,SYMBOL_BID):SymbolInfoDouble(g_sym,SYMBOL_ASK);
   return "Open Position\nTrade #: "+TNo((long)PGV(pid,"N",0))+"\n"+(buy?"BUY":"SELL")+"\nEntry: "+PX(entry)+"\nSL: "+PX(sl)+"\nTP: "+PX(tp)+
          "\nLot: "+LotS(vol)+"\nRisk: $"+D2(PGV(pid,"R",g_curRisk))+"\nCurrent Price: "+PX(cur)+"\nFloating P/L: "+Money(pr);
  }

string TgStateText()
  {
   return g_tgOk?"CONNECTED":(TgActive()?"ERROR":(g_tgEn?"NOT CONFIGURED":"DISABLED"));
  }

string StatusText()
  {
   string s="🤖 Yetimmm Status\nStatus: "+RunStatus()+"\nState: "+StateText()+"\nSymbol: "+g_sym+"\nBuy Stop: "+PX(g_buyLevel)+"\nSell Stop: "+PX(g_sellLevel)+"\n";
   ulong tk,pid; bool buy; double vol,entry,sl,tp,pr;
   if(OwnPosInfo(tk,pid,buy,vol,entry,sl,tp,pr))
      s+="Position: "+(buy?"BUY":"SELL")+"\nTrade #: "+TNo((long)PGV(pid,"N",0))+"\nEntry: "+PX(entry)+"\nSL: "+PX(sl)+"\nTP: "+PX(tp)+"\nLot: "+LotS(vol)+"\n";
   else s+="Position: NONE\n";
   s+="Sync: "+SyncSummary()+"\n";
   if(g_fresh && g_pendBuy>0.0 && g_pendSell>0.0) s+="Pending levels (start after TP): Buy "+PX(g_pendBuy)+" / Sell "+PX(g_pendSell)+"\n";
   s+="Initial Risk: $"+D2(g_initRisk)+"\nCurrent Risk: $"+D2(g_curRisk)+"\nAccumulated Loss: $"+D2(g_accLoss)+"\nTrade Sequence: "+IntegerToString(g_seq)+
      "\nConnection: "+(g_connected?"ONLINE":"OFFLINE")+"\nSpread: "+IntegerToString((int)SymbolInfoInteger(g_sym,SYMBOL_SPREAD))+" pts\nTelegram: "+TgStateText();
   if(StringLen(g_waitReason)>0) s+="\nNote: "+g_waitReason;
   if(StringLen(g_blockReason)>0) s+="\nBlocked: "+g_blockReason;
   return s;
  }

string StatsText()
  {
   return "📈 Yetimmm Statistics\nTotal Trades: "+IntegerToString(g_st.total)+"\nWinning Trades: "+IntegerToString(g_st.wins)+"\nLosing Trades: "+IntegerToString(g_st.losses)+
          "\nBuy Trades: "+IntegerToString(g_st.buys)+" (W "+IntegerToString(g_st.winBuy)+" / L "+IntegerToString(g_st.loseBuy)+")"+
          "\nSell Trades: "+IntegerToString(g_st.sells)+" (W "+IntegerToString(g_st.winSell)+" / L "+IntegerToString(g_st.loseSell)+")"+
          "\nTotal Profit: "+Money(g_st.totProfit)+"\nTotal Loss: "+Money(-g_st.totLoss)+"\nNet P/L: "+Money(g_st.net)+"\nWin Rate: "+D2(g_st.winRate)+"%"+
          "\nAverage Profit: "+Money(g_st.avgProfit)+"\nAverage Loss: "+Money(-g_st.avgLoss)+
          "\nLargest Loss: "+Money(-g_st.maxLoss)+"\nLargest Profit: "+Money(g_st.maxProfit)+
          "\nCurrent Streak: "+IntegerToString(g_st.streak)+"\nConsecutive SL: "+IntegerToString(g_st.consSL)+"\nConsecutive TP: "+IntegerToString(g_st.consTP)+
          "\nTotal Commission: "+Money(g_st.commission)+"\nTotal Swap: "+Money(g_st.swap)+"\nTotal Volume: "+LotS(g_st.volume)+
          "\nHighest Risk Used: $"+D2(g_st.highRisk)+"\nHighest Lot Used: "+LotS(g_st.highLot)+
          "\nCurrent Risk: $"+D2(g_curRisk)+"\nAccumulated Loss: $"+D2(g_accLoss)+"\nCurrent Trade: #"+TNo(g_tradeNo);
  }

string RiskText()
  {
   double lot,est; string err;
   bool ok=CurrentLotInfo(lot,est,err);
   double nxt=NextRiskFor(g_accLoss+(ok?est:g_curRisk));
   return "Risk Info\nInitial Risk: $"+D2(g_initRisk)+"\nCurrent Risk: $"+D2(g_curRisk)+"\nNext Risk (if SL): $"+D2(nxt)+"\nAccumulated Loss: $"+D2(g_accLoss)+
          "\nTrade Sequence: "+IntegerToString(g_seq)+"\nCurrent Lot: "+(ok?LotS(lot):"n/a ("+err+")")+"\nEstimated Loss at SL: "+(ok?"$"+D2(est):"n/a")+
          "\nTheoretical TP Profit: "+(ok?"$"+D2(est*g_rr):"n/a");
  }

string SettingsText()
  {
   return "Yetimmm Settings\nSymbol: "+g_sym+"\nSL (Upper-Lower): $"+D2(SLDist())+"\nRisk/Reward: 1:"+DoubleToString(g_rr,0)+"\nRecovery Target (sizes next risk): $"+D2(g_target)+
          "\nSpread Alert (alert only): "+IntegerToString(g_warn)+" pts\nMax Slippage Check (post-fill): "+IntegerToString(g_maxDev)+" pts\nMagic Number: "+IntegerToString(g_magic)+
          "\nContract Size: "+DoubleToString(g_contract,2)+"\nAccount Mode: "+(g_netting?"NETTING (external-position guard ON)":"HEDGING")+
          "\nDeviation Action: "+(InpDevAction==YT_DEV_REJECT?"REJECT (close)":"ALERT ONLY")+
          "\nTelegram: "+(g_tgEn?"ENABLED":"DISABLED")+"\nNotifications: "+(g_tgNot?"ON":"OFF")+"\nTelegram Control: "+(g_tgCtl?"ON":"OFF")+
          "\nAuthorized IDs: "+IntegerToString(ArraySize(g_tgIds))+"\nBot Token: HIDDEN";
  }

string HistoryText(int count,int skip)
  {
   string lines[];
   int n=ReadTradeLines(lines);
   if(n==0) return "📊 Yetimmm Trade History\nNo trades recorded yet.";
   if(count<1) count=10;
   if(count>20) count=20;
   if(skip<0) skip=0;
   string s="📊 Yetimmm Trade History\n";
   int end=n-skip;
   int start=MathMax(0,end-count);
   if(end<=0) return s+"No older trades.";
   for(int i=end-1;i>=start;i--)
     {
      string f[];
      if(StringSplit(lines[i],';',f)<30) continue;
      string blk="\n#"+TNo(StringToInteger(f[0]))+" "+f[5]+"\nEntry: "+f[7]+"\nExit: "+f[8]+"\nLot: "+f[11]+"\nRisk: $"+D2(StringToDouble(f[12]))+
                 "\nResult: "+f[23]+"\nP/L: "+Money(StringToDouble(f[18]))+"\n";
      if(StringLen(s)+StringLen(blk)>3700) { s+="\n... (use /history N SKIP for more)"; break; }
      s+=blk;
     }
   return s;
  }

string LastText()
  {
   string lines[];
   int n=ReadTradeLines(lines);
   if(n==0) return "No trades recorded yet.";
   string f[];
   if(StringSplit(lines[n-1],';',f)<30) return "No trades recorded yet.";
   return "Last Trade\nTrade #: "+TNo(StringToInteger(f[0]))+"\nType: "+f[5]+"\nEntry: "+f[7]+"\nExit: "+f[8]+"\nLot: "+f[11]+"\nRisk: $"+D2(StringToDouble(f[12]))+
          "\nResult: "+f[23]+"\nGross Profit: "+Money(StringToDouble(f[15]))+"\nCommission: "+Money(StringToDouble(f[16]))+"\nSwap: "+Money(StringToDouble(f[17]))+
          "\nNet P/L: "+Money(StringToDouble(f[18]));
  }

string HelpText()
  {
   return "Yetimmm Commands\n/start - تشغيل البوت\n/stop - إيقاف البوت\n/set BUY SELL [RISK] - إدخال المستويات والمخاطرة\n/cancel - إلغاء الأوامر / إدارة الإغلاق\n"
          "/status - حالة البوت\n/open - الصفقات المفتوحة\n/orders - الأوامر المعلقة\n/history [N] [SKIP] - سجل الصفقات\n/last - آخر صفقة\n"
          "/stats - الإحصائيات\n/risk - معلومات المخاطرة\n/settings - الإعدادات\n/menu - لوحة الأزرار\n/help - المساعدة";
  }

//+------------------------------------------------------------------+
//| Max Slippage Check enforcement                                    |
//| MT5 ignores "deviation" for pending orders (the server triggers  |
//| them), so the limit is enforced immediately after the fill: the  |
//| position is closed, the risk sequence is NOT changed, and the    |
//| same orders are re-armed once after a cooldown.                  |
//+------------------------------------------------------------------+
bool CloseRejected(const ulong pid)
  {
   ulong t=0;
   if(!FindLive(pid,t)) return true;
   if(NetTaintRefusesClose("the slippage-reject close")) return false;
   long ot=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?(long)ORDER_TYPE_BUY:(long)ORDER_TYPE_SELL;
   double px=PositionGetDouble(POSITION_PRICE_OPEN);
   double lt=PositionGetDouble(POSITION_VOLUME);
   ulong exitDev=(ulong)MathMax(500,g_maxDev*10);   // get out even in a fast market
   bool ok=g_trade.PositionClose(t,exitDev);
   uint rc=g_trade.ResultRetcode();
   LogOrder(ok?"DEV_REJECT_CLOSE":"DEV_REJECT_CLOSE_FAILED",ot,px,lt,t,rc,"Max Slippage Check exceeded");
   YLog(ok?"Deviation reject: position closed #"+UL(t):"Deviation reject: close FAILED #"+UL(t)+" retcode "+IntegerToString((int)rc)+" (retrying)");
   return ok;
  }

void RejectExecution(const ulong pid,const double dev)
  {
   PSet(pid,"CRC",4.0);
   GlobalVariablesFlush();
   YLog("Max Slippage Check exceeded ("+DoubleToString(dev,0)+" > "+IntegerToString(g_maxDev)+" pts): execution REJECTED - closing position "+UL(pid));
   TgQueue("🚫 EXECUTION REJECTED (Maximum Deviation)\nSlippage: "+DoubleToString(dev,0)+" pts > max "+IntegerToString(g_maxDev)+" pts\nThe position is being closed; the risk sequence is unchanged.");
   CloseRejected(pid);
  }

//+------------------------------------------------------------------+
//| CRITICAL protection guard                                        |
//| A Yetimmm position WITHOUT SL/TP is not a normal state: its risk |
//| is unbounded. Detect -> freeze the sequence -> retry every       |
//| second -> critical alert -> emergency close after a timeout.     |
//+------------------------------------------------------------------+
void ProtectionRestored()
  {
   if(!g_unprot) return;
   g_unprot=false; g_unprotPid=0; g_unprotSinceMs=0; g_protTries=0; g_protNextMs=0;
   ClearAlert("PROTFAIL");
   if(StringFind(g_blockReason,"CRITICAL PROTECTION")==0) g_blockReason="";
   YLog("Protection restored: the position carries SL and TP again.");
   TgQueue("🟢 PROTECTION RESTORED\nThe Yetimmm position carries SL and TP again. Sequence resumed.");
   g_dirty=true;
  }

bool EmergencyClose(const ulong pid,const string why)
  {
   ulong t=0;
   if(!FindLive(pid,t)) return true;
   if(NetTaintRefusesClose("the emergency close")) return false;
   long ot=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?(long)ORDER_TYPE_BUY:(long)ORDER_TYPE_SELL;
   double px=PositionGetDouble(POSITION_PRICE_OPEN);
   double lt=PositionGetDouble(POSITION_VOLUME);
   PSet(pid,"CRC",6.0);
   GlobalVariablesFlush();
   ulong exitDev=(ulong)MathMax(500,g_maxDev*10);   // get out even in a fast market
   bool ok=g_trade.PositionClose(t,exitDev);
   uint rc=g_trade.ResultRetcode();
   LogOrder(ok?"PROTECTION_CLOSE":"PROTECTION_CLOSE_FAILED",ot,px,lt,t,rc,why);
   YLog((ok?"Emergency close done #":"Emergency close FAILED #")+UL(t)+" retcode "+IntegerToString((int)rc)+" | "+why);
   if(ok) TgQueue("🔴 EMERGENCY CLOSE (no SL/TP protection)\nTicket: #"+UL(t)+"\nReason: "+why+"\nThe risk sequence is unchanged. Enter levels to continue.");
   return ok;
  }

//--- returns true when the position carries SL and TP (restoring them first when needed)
bool ProtectPosition(const ulong pid)
  {
   ulong t=0;
   if(!FindLive(pid,t))
     {
      if(g_unprot && g_unprotPid==pid) { g_unprot=false; g_unprotPid=0; ClearAlert("PROTFAIL"); }
      return true;
     }
   bool buy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   double sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
   double ent=PositionGetDouble(POSITION_PRICE_OPEN);
   if(sl>0.0 && tp>0.0)
     {
      if(g_unprot && g_unprotPid==pid) ProtectionRestored();
      return true;
     }
   ulong nowMs=GetTickCount64();
   string miss=(sl<=0.0 && tp<=0.0)?"SL and TP":(sl<=0.0?"SL":"TP");
   if(!g_unprot || g_unprotPid!=pid)
     {
      g_unprot=true; g_unprotPid=pid; g_unprotSinceMs=nowMs; g_protTries=0; g_protNextMs=0;
      g_blockReason="CRITICAL PROTECTION FAILURE: position without "+miss+" - sequence frozen";
      YLog(g_blockReason);
      RaiseAlert("PROTFAIL","🔴 CRITICAL PROTECTION FAILURE: Yetimmm position #"+UL(pid)+" has no "+miss+". Retrying every second; the sequence is frozen"+
                 (InpProtectCloseSec>0?" and the position is closed after "+IntegerToString(InpProtectCloseSec)+" s if protection cannot be set.":"."),true,true);
     }
   if(nowMs<g_protNextMs) return false;
   g_protNextMs=nowMs+1000;
   g_protTries++;

   //--- what the protection must be: the existing value, else the one stored at registration, else derived from the levels
   double eSL=(sl>0.0)?sl:PGV(pid,"SLP",0.0);
   double eTP=(tp>0.0)?tp:PGV(pid,"TPP",0.0);
   double lvl=PGV(pid,"ENT",ent);
   if(lvl<=0.0) lvl=ent;
   if(eSL<=0.0) eSL=SLPrice(buy,lvl);
   if(eTP<=0.0) eTP=TPPrice(buy,lvl);
   if(eSL<=0.0 || eTP<=0.0)
     {
      EmergencyClose(pid,"SL/TP cannot be computed (levels missing)");
      return false;
     }
   //--- a protection that the market has already passed cannot be set: leave the position
   double bid=SymbolInfoDouble(g_sym,SYMBOL_BID), ask=SymbolInfoDouble(g_sym,SYMBOL_ASK);
   if(sl<=0.0 && (buy?(bid<=eSL):(ask>=eSL)))
     {
      EmergencyClose(pid,"SL level "+PX(eSL)+" already crossed while the position had no SL");
      return false;
     }
   if(tp<=0.0 && (buy?(bid>=eTP):(ask<=eTP)))
     {
      EmergencyClose(pid,"TP level "+PX(eTP)+" already reached while the position had no TP");
      return false;
     }
   bool r=g_trade.PositionModify(t,eSL,eTP);
   uint rc=g_trade.ResultRetcode();
   bool ok=(r && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED));
   if(ok)
     {
      //--- the retcode is not proof: the position must really carry both values now
      ok=false;
      for(int w=0;w<6 && !ok;w++)
        {
         ulong t2=0;
         if(FindLive(pid,t2) && PositionGetDouble(POSITION_SL)>0.0 && PositionGetDouble(POSITION_TP)>0.0) ok=true;
         else Sleep(60);
        }
     }
   if(ok)
     {
      PSet(pid,"SLP",eSL); PSet(pid,"TPP",eTP);
      long ot=buy?(long)ORDER_TYPE_BUY:(long)ORDER_TYPE_SELL;
      LogOrder("PROTECTION_RESTORED",ot,ent,0.0,t,rc,"SL "+PX(eSL)+" TP "+PX(eTP)+" after "+IntegerToString(g_protTries)+" attempt(s)");
      YLog("SL/TP restored on position "+UL(pid)+" | SL "+PX(eSL)+" TP "+PX(eTP));
      ProtectionRestored();
      return true;
     }
   long ot2=buy?(long)ORDER_TYPE_BUY:(long)ORDER_TYPE_SELL;
   LogOrder("PROTECTION_FAILED",ot2,ent,0.0,t,rc,"attempt "+IntegerToString(g_protTries)+": "+g_trade.ResultComment());
   YLog("Protection attempt "+IntegerToString(g_protTries)+" FAILED on #"+UL(pid)+" retcode "+IntegerToString((int)rc)+" "+g_trade.ResultComment());
   if(InpProtectCloseSec>0 && (nowMs-g_unprotSinceMs)>=(ulong)InpProtectCloseSec*1000)
      EmergencyClose(pid,"protection could not be set for "+IntegerToString(InpProtectCloseSec)+" s");
   return false;
  }

//+------------------------------------------------------------------+
//| Trade registration (Trade Number assignment)                     |
//+------------------------------------------------------------------+
long RegisterPosition(const ulong pid)
  {
   if(PHas(pid,"N")) return (long)PGV(pid,"N",0);
   if(IsLoggedPos(pid)) return 0;
   double entry=0.0,vol=0.0,orderPrice=0.0,sl=0.0,tp=0.0;
   long ptype=-1,otype=-1;
   datetime topen=0;
   ulong order=0,dealIn=0;
   if(HistorySelectByPosition(pid))
     {
      int n=HistoryDealsTotal();
      for(int i=0;i<n;i++)
        {
         ulong d=HistoryDealGetTicket(i);
         if(d==0) continue;
         if(HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;
         long dt=HistoryDealGetInteger(d,DEAL_TYPE);
         if(dt!=DEAL_TYPE_BUY && dt!=DEAL_TYPE_SELL) continue;
         //--- Netting merges foreign deals into the same position id: the registered lot counts ONLY this bot's deals,
         //--- so a foreign volume that arrived before registration is still detected by NettingDriftCheck
         if(g_netting && (long)HistoryDealGetInteger(d,DEAL_MAGIC)!=g_magic) continue;
         vol+=HistoryDealGetDouble(d,DEAL_VOLUME);
         if(order==0)
           {
            entry=HistoryDealGetDouble(d,DEAL_PRICE);
            topen=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
            order=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
            ptype=(dt==DEAL_TYPE_BUY)?(long)POSITION_TYPE_BUY:(long)POSITION_TYPE_SELL;
            dealIn=d;
           }
        }
     }
   if(ptype<0) return 0; // history not ready yet, retried on the next sync
   if(order!=0 && HistoryOrderSelect(order))
     {
      orderPrice=HistoryOrderGetDouble(order,ORDER_PRICE_OPEN);
      sl=HistoryOrderGetDouble(order,ORDER_SL);
      tp=HistoryOrderGetDouble(order,ORDER_TP);
      otype=HistoryOrderGetInteger(order,ORDER_TYPE);
     }
   bool buy=(ptype==(long)POSITION_TYPE_BUY);
   ulong live=0;
   if(FindLive(pid,live))
     {
      sl=PositionGetDouble(POSITION_SL);
      tp=PositionGetDouble(POSITION_TP);
     }
   double level=buy?g_buyLevel:g_sellLevel;
   if(orderPrice<=0.0) orderPrice=(level>0.0)?level:entry;
   double dev=MathAbs(entry-orderPrice)/g_point;
   bool marketFill=(otype==(long)ORDER_TYPE_BUY || otype==(long)ORDER_TYPE_SELL);
   if(marketFill)
     {
      //--- v2.11: REAL post-fill slippage of a market reversal = |actual fill - the price the lot and TP were sized from|
      double expPx=GV("RVEXP",0.0);
      dev=(expPx>0.0)?MathAbs(entry-expPx)/g_point:0.0;
      GS("RVEXP",0.0);                          // consumed
      //--- the SL/TP the reversal REQUESTED (computed from the real execution price) is the expected protection of this position
      if(sl<=0.0) sl=GV("RVSL",0.0);
      if(tp<=0.0) tp=GV("RVTP",0.0);
      GS("RVSL",0.0); GS("RVTP",0.0);          // consumed (stored below as this position's expected protection)
     }
   double spread=(double)SymbolInfoInteger(g_sym,SYMBOL_SPREAD);

   int priorMode=g_mode;                 // mode before this fill (needed to re-arm after a deviation reject)
   g_tradeNo++;
   SaveState();
   PSet(pid,"N",(double)g_tradeNo);
   PSet(pid,"R",g_curRisk);
   PSet(pid,"AL",g_accLoss);
   PSet(pid,"BB",AccountInfoDouble(ACCOUNT_BALANCE));
   PSet(pid,"SP",spread);
   PSet(pid,"DV",dev);
   PSet(pid,"SLP",sl);
   PSet(pid,"TPP",tp);
   PSet(pid,"LOT",vol);
   PSet(pid,"LB",g_buyLevel);
   PSet(pid,"LS",g_sellLevel);
   PSet(pid,"TY",(double)ptype);
   PSet(pid,"ET",(double)otype);
   PSet(pid,"ENT",orderPrice);
   PSet(pid,"ORD",(double)order);
   PSet(pid,"PM",(double)priorMode);
   GlobalVariablesFlush();

   //--- make sure the position is protected by SL/TP (a position without them is a CRITICAL failure: see ProtectPosition)
   if(live!=0)
     {
      ProtectPosition(pid);
      if(FindLive(pid,live)) { sl=PositionGetDouble(POSITION_SL); tp=PositionGetDouble(POSITION_TP); }
     }

   if(g_state!=YT_STOPPED)
     {
      g_state=buy?YT_BUY_ACTIVE:YT_SELL_ACTIVE;
      g_mode=YM_NONE;
     }
   g_activeNoPosSince=0;
   SaveState();
   g_dirty=true;

   YLog((buy?"Buy Activated":"Sell Activated")+" | Trade Number Assigned #"+TNo(g_tradeNo)+" | Entry "+PX(entry));
   LogOrder("TRIGGERED",otype,orderPrice,vol,order,0,"Trade #"+TNo(g_tradeNo)+" fill "+PX(entry));
   TgQueue((buy?"🟢 BUY ACTIVATED":"🔴 SELL ACTIVATED")+"\nTrade #: "+TNo(g_tradeNo)+"\nEntry: "+PX(entry)+"\nSL: "+PX(sl)+"\nTP: "+PX(tp)+"\nLot: "+LotS(vol)+
           "\nRisk: $"+D2(g_curRisk)+"\nBuy Level: "+PX(g_buyLevel)+"\nSell Level: "+PX(g_sellLevel)+"\nTime: "+TimeToString(topen,TIME_DATE|TIME_SECONDS));
   if(dev>(double)g_maxDev)
     {
      RaiseAlert("DEV","Deviation exceeded: fill slippage "+DoubleToString(dev,0)+" pts > max "+IntegerToString(g_maxDev)+" pts (Trade #"+TNo(g_tradeNo)+").",true,true);
      if(InpDevAction==YT_DEV_REJECT && live!=0 && g_state!=YT_STOPPED) RejectExecution(pid,dev);
     }
   return g_tradeNo;
  }

void RegisterLivePositions()
  {
   ulong tk[];
   int n=OwnPositions(tk);
   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tk[i])) continue;
      ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(!PHas(pid,"N") && !IsLoggedPos(pid)) RegisterPosition(pid);
     }
  }

//+------------------------------------------------------------------+
//| Closed position processing (SL / TP / other)                     |
//+------------------------------------------------------------------+
bool ProcessClosedPosition(const ulong pid)
  {
   if(IsLoggedPos(pid)) { ClearPosGV(pid); return true; }
   if(!HistorySelectByPosition(pid)) return false;
   int n=HistoryDealsTotal();
   double inVol=0,outVol=0,gross=0,comm=0,swap=0,exitPrice=0,entryPrice=0;
   datetime tOpen=0,tClose=0;
   ulong dealIn=0,dealOut=0,orderIn=0;
   long ptype=-1,reason=-1;
   bool foreignIn=false;                                   // Netting: a foreign ENTRY deal merged into this position id
   for(int i=0;i<n;i++)
     {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;
      long dtype=HistoryDealGetInteger(d,DEAL_TYPE);
      if(dtype!=DEAL_TYPE_BUY && dtype!=DEAL_TYPE_SELL) continue;
      long entry=HistoryDealGetInteger(d,DEAL_ENTRY);
      if(g_netting && entry==DEAL_ENTRY_IN && (long)HistoryDealGetInteger(d,DEAL_MAGIC)!=g_magic) foreignIn=true;
      double vol=HistoryDealGetDouble(d,DEAL_VOLUME);
      double pr=HistoryDealGetDouble(d,DEAL_PRICE);
      datetime tm=(datetime)HistoryDealGetInteger(d,DEAL_TIME);
      comm+=HistoryDealGetDouble(d,DEAL_COMMISSION)+HistoryDealGetDouble(d,DEAL_FEE);
      swap+=HistoryDealGetDouble(d,DEAL_SWAP);
      if(entry==DEAL_ENTRY_IN)
        {
         inVol+=vol;
         if(dealIn==0)
           {
            dealIn=d; tOpen=tm; entryPrice=pr;
            orderIn=(ulong)HistoryDealGetInteger(d,DEAL_ORDER);
            ptype=(dtype==DEAL_TYPE_BUY)?(long)POSITION_TYPE_BUY:(long)POSITION_TYPE_SELL;
           }
        }
      else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
        {
         outVol+=vol;
         gross+=HistoryDealGetDouble(d,DEAL_PROFIT);
         dealOut=d; tClose=tm; exitPrice=pr;
         reason=HistoryDealGetInteger(d,DEAL_REASON);
        }
     }
   if(inVol<=0.0 || dealOut==0) return false;             // history not ready yet
   if(outVol<inVol-1e-8) return false;                     // not fully closed yet
   if(IsLoggedDeal(dealOut)) { ClearPosGV(pid); return true; }

   double net=gross+comm+swap;
   bool buy=(ptype==(long)POSITION_TYPE_BUY);
   long tno=(long)PGV(pid,"N",0);
   double reqRisk=PGV(pid,"R",g_curRisk);
   double accBefore=PGV(pid,"AL",g_accLoss);
   double balBefore=PGV(pid,"BB",0);
   double spread=PGV(pid,"SP",0);
   double dev=PGV(pid,"DV",0);
   double slp=PGV(pid,"SLP",0), tpp=PGV(pid,"TPP",0);
   double lbuy=PGV(pid,"LB",g_buyLevel), lsell=PGV(pid,"LS",g_sellLevel);
   long otype=(long)PGV(pid,"ET",-1);
   long cmd=(long)PGV(pid,"CRC",0);

   string rs;
   if(reason==DEAL_REASON_SL) rs="SL";
   else if(reason==DEAL_REASON_TP) rs="TP";
   else if(cmd==1) rs="Manual Stop";
   else if(cmd==2) rs="Telegram Stop";
   else if(cmd==3) rs="Telegram Cancel";
   else if(cmd==4) rs="Deviation Reject";
   else if(cmd==5) rs="Extra Position Closed";
   else if(cmd==6) rs="Protection Close";
   else
     {
      double tol=MathMax(g_point*5.0,g_tick*3.0);
      //--- v2.11: the price fallback applies ONLY when the reason is unknown; a manual / mobile / web / stop-out / EA close is never re-labelled SL or TP
      bool reasonUnknown=(reason!=DEAL_REASON_CLIENT && reason!=DEAL_REASON_MOBILE && reason!=DEAL_REASON_WEB &&
                          reason!=DEAL_REASON_SO && reason!=DEAL_REASON_EXPERT);
      if(InpPriceFallback && reasonUnknown && slp>0.0 && MathAbs(exitPrice-slp)<=tol) rs="SL";
      else if(InpPriceFallback && reasonUnknown && tpp>0.0 && MathAbs(exitPrice-tpp)<=tol) rs="TP";
      else if(reason==DEAL_REASON_SO) rs="Stop Out";
      else if(reason==DEAL_REASON_CLIENT || reason==DEAL_REASON_MOBILE || reason==DEAL_REASON_WEB) rs="Manual (External)";
      else rs="Other";
     }

   double entryLevel=buy?lbuy:lsell;
   if(entryLevel<=0.0) entryLevel=entryPrice;
   //--- theoretical loss at SL from the levels this position was opened with (not from today's levels)
   double theoSL=buy?lsell:lbuy;
   double theoLoss=inVol*PerLotLossSL(buy,entryLevel,(theoSL>0.0 && theoSL!=entryLevel)?theoSL:SLPrice(buy,entryLevel));
   double theoProfit=theoLoss*g_rr;

   //--- Netting: a position that absorbed foreign volume has a P/L that is NOT purely this bot's.
   //--- It is logged, but it never feeds the risk sequence (no accumulated loss, no risk step, no TP reset).
   bool tainted=(g_netting && (foreignIn || PGV(pid,"TAINT",0.0)>0.5));
   if(g_netting && foreignIn && PGV(pid,"TAINT",0.0)<=0.5)
      YLog("Netting: position "+UL(pid)+" absorbed foreign volume (found in its history) - logged, but NOT counted in the risk sequence / statistics.");

   //--- apply the risk logic exactly once for this position
   bool bookkeeping=(g_state==YT_STOPPED || g_stopCleanup);
   bool isSL=(rs=="SL" && !tainted), isTP=(rs=="TP" && !tainted), isDev=(rs=="Deviation Reject" && !tainted);
   ulong rest[];
   int others=OwnPositions(rest);
   string nextInfo="";
   double nextLot=0,nextEst=0; string lerr="";
   if(!bookkeeping)
     {
      if(tainted)
        {
         if(others==0) { g_mode=YM_NONE; g_state=YT_IDLE; g_lastSLSide=0; }
         g_failCount=0;
        }
      else if(isSL)
        {
         if(net<0.0) g_accLoss+=-net;
         g_seq++;
         g_curRisk=NextRiskFor(g_accLoss);
         //--- v2.00: a VERIFIED Stop Loss closed the position -> BOTH stop orders are prepared again (Upper = Buy Stop, Lower = Sell Stop)
         g_mode=YM_BOTH;
         g_state=YT_WAITING_REENTRY;
         g_lastSLSide=buy?1:2;
         g_nextPlaceMs=0;
         g_failCount=0;
         //--- the ORIGINAL levels of the position that just stopped out are restored (its SL was the opposite level)
         if(lbuy>0.0 && lsell>0.0 && (!PriceEq(g_buyLevel,lbuy) || !PriceEq(g_sellLevel,lsell)))
           {
            YLog("Original levels restored for re-arm: Buy "+PX(g_buyLevel)+" -> "+PX(lbuy)+" | Sell "+PX(g_sellLevel)+" -> "+PX(lsell));
            g_buyLevel=lbuy; g_sellLevel=lsell;
           }
         double lvl=buy?g_sellLevel:g_buyLevel;   // the opposite direction is the next one (same SL distance on both sides)
         if(!CalcLot(g_curRisk,!buy,lvl,nextLot,nextEst,lerr)) nextLot=0;
        }
      else if(isTP)
        {
         ResetRisk();
         g_lastSLSide=0;
         g_mode=YM_NONE;
         if(g_fresh) { PromotePending(); g_state=YT_ARMED; g_mode=YM_BOTH; g_fresh=false; }
         else g_state=YT_TP_RESET;
        }
      else if(isDev)
        {
         int pm=(int)PGV(pid,"PM",(double)YM_BOTH);
         if(pm!=YM_BOTH && pm!=YM_BUY && pm!=YM_SELL) pm=YM_BOTH;
         g_failCount=0;
         g_nextPlaceMs=GetTickCount64()+30000;   // cooldown: no immediate re-fill / no repeated orders
         if((otype==(long)ORDER_TYPE_BUY || otype==(long)ORDER_TYPE_SELL) && (g_lastSLSide==1 || g_lastSLSide==2))
           {
            //--- v2.11: a rejected MARKET reversal keeps its direction: back to WAITING_REENTRY (the reversal / pending pair is retried after the cooldown)
            g_mode=YM_BOTH;
            g_state=YT_WAITING_REENTRY;
            g_nextRevMs=GetTickCount64()+30000;
           }
         else
           {
            g_mode=pm;
            g_state=YT_ARMED;
           }
        }
      else if(others==0)
        {
         if(g_fresh) PromotePending();
         g_mode=YM_NONE;
         g_state=YT_IDLE;
        }
     }
   double accAfter=g_accLoss;
   double nextRisk=g_curRisk;
   if(!bookkeeping && !isSL && !isTP) nextRisk=g_curRisk;

   //--- persistent trade log (once per position)
   string line=IntegerToString(tno)+";"+UL(orderIn)+";"+UL(dealIn)+";"+UL(dealOut)+";"+UL(pid)+";"+(buy?"BUY":"SELL")+";"+OTypeStr(otype)+";"+
               PX(entryPrice)+";"+PX(exitPrice)+";"+PX(slp)+";"+PX(tpp)+";"+LotS(inVol)+";"+D2(reqRisk)+";"+D2(theoLoss)+";"+D2(theoProfit)+";"+
               D2(gross)+";"+D2(comm)+";"+D2(swap)+";"+D2(net)+";"+DoubleToString(spread,0)+";"+DoubleToString(dev,0)+";"+
               TimeToString(tOpen,TIME_DATE|TIME_SECONDS)+";"+TimeToString(tClose,TIME_DATE|TIME_SECONDS)+";"+rs+";"+
               D2(balBefore)+";"+D2(AccountInfoDouble(ACCOUNT_BALANCE))+";"+D2(accBefore)+";"+D2(accAfter)+";"+D2(reqRisk)+";"+D2(nextRisk)+";"+
               PX(lbuy)+";"+PX(lsell)+";"+IntegerToString(g_magic)+";"+g_sym+";"+(tainted?"CLOSED_NET_TAINTED":"CLOSED")+";"+
               Clean(tainted?"Netting: external volume merged - risk sequence NOT updated":(bookkeeping?"bookkeeping only":""));
   AppendLine(TradeFile(),TRADE_HEADER,line);
   MarkLogged(pid,dealOut);
   if(!tainted) StatsAdd(net,comm,swap,buy?"BUY":"SELL",inVol,reqRisk,rs);
   g_lastDeal=dealOut;
   GS("LDT",(double)tClose);                 // time of the last processed closing deal (history-recovery fallback anchor)
   SaveState();
   ClearPosGV(pid);
   g_dirty=true;
   YLog("Trade History Updated: #"+TNo(tno)+" "+rs+" net "+D2(net));
   YLog("Statistics Updated");

   //--- notifications
   if(isSL)
     {
      YLog("Stop Loss | New Risk Calculated "+D2(g_curRisk)+" | New Lot Calculated "+(nextLot>0?LotS(nextLot):"n/a"));
      TgQueue("🔴 STOP LOSS\nTrade #: "+TNo(tno)+"\nType: "+(buy?"BUY":"SELL")+"\nEntry: "+PX(entryPrice)+"\nExit: "+PX(exitPrice)+"\nLot: "+LotS(inVol)+
              "\nLoss: "+Money(net)+"\nAccumulated Loss: $"+D2(g_accLoss)+"\nNext Risk: $"+D2(g_curRisk)+"\nNext Lot: "+(nextLot>0?LotS(nextLot):"n/a ("+lerr+")")+
              "\nRe-armed (both sides):\nBuy Stop: "+PX(g_buyLevel)+"\nSell Stop: "+PX(g_sellLevel));
     }
   else if(isTP)
     {
      YLog("Take Profit | Risk Reset");
      TgQueue("🟢 TAKE PROFIT\nTrade #: "+TNo(tno)+"\nType: "+(buy?"BUY":"SELL")+"\nEntry: "+PX(entryPrice)+"\nExit: "+PX(exitPrice)+"\nProfit: "+Money(net)+
              "\nRisk Sequence Reset ✅\nAccumulated Loss: $0\nNext Risk: $"+D2(g_initRisk)+"\nStatus:\n"+(g_state==YT_ARMED?"ARMED (new levels)":"WAITING FOR LEVELS"));
     }
   else if(isDev)
     {
      YLog("Execution rejected (Max Deviation) Trade #"+TNo(tno)+" net "+D2(net)+" | risk sequence unchanged, orders re-armed at the original levels");
      TgQueue("🚫 EXECUTION REJECTED (Max Deviation)\nTrade #: "+TNo(tno)+"\nType: "+(buy?"BUY":"SELL")+"\nEntry: "+PX(entryPrice)+"\nExit: "+PX(exitPrice)+"\nNet P/L: "+Money(net)+
              (bookkeeping?"":"\nRisk sequence unchanged. Orders re-armed at the original levels after a short cooldown."));
     }
   else
     {
      YLog("Position closed ("+rs+") Trade #"+TNo(tno)+" net "+D2(net)+(tainted?" | NETTING-TAINTED: not counted in the risk sequence / statistics":""));
      TgQueue("⚪ POSITION CLOSED ("+rs+")\nTrade #: "+TNo(tno)+"\nType: "+(buy?"BUY":"SELL")+"\nEntry: "+PX(entryPrice)+"\nExit: "+PX(exitPrice)+"\nNet P/L: "+Money(net)+
              (tainted?"\n⚠️ Netting: external volume was merged into this position. Its result is NOT counted in the risk sequence or statistics.":"")+
              (bookkeeping?"":"\nRisk sequence unchanged. Waiting for levels (/set BUY SELL)."));
      if(!bookkeeping && others==0)
        {
         if(tainted) RaiseAlert("NETTAINT","Netting-contaminated position closed ("+rs+"). Its result was NOT added to the risk sequence. Check the account, then enter new levels to continue.",true,true);
         else        RaiseAlert("EXTCLOSE","Position closed outside SL/TP ("+rs+"). Enter new levels to continue.",true,false);
        }
     }
   return true;
  }

void CheckClosures()
  {
   string prefix=GN("P");
   int pl=StringLen(prefix);
   ulong ids[];
   int total=GlobalVariablesTotal();
   for(int i=0;i<total;i++)
     {
      string nm=GlobalVariableName(i);
      if(StringFind(nm,prefix)!=0) continue;
      int L=StringLen(nm);
      if(L<pl+3) continue;
      if(StringSubstr(nm,L-2)!="_N") continue;
      string mid=StringSubstr(nm,pl,L-pl-2);
      bool digits=true;
      for(int k=0;k<StringLen(mid);k++)
        { ushort c=StringGetCharacter(mid,k); if(c<'0' || c>'9') { digits=false; break; } }
      if(!digits || StringLen(mid)==0) continue;
      ulong pid=(ulong)StringToInteger(mid);
      int c2=ArraySize(ids);
      ArrayResize(ids,c2+1);
      ids[c2]=pid;
     }
   for(int i=0;i<ArraySize(ids);i++)
     {
      ulong tk;
      if(FindLive(ids[i],tk)) continue;
      ProcessClosedPosition(ids[i]);
     }
  }

//--- find trades opened (and maybe closed) while the EA/terminal was offline
//--- v2.11: anchored on the last time the history was FULLY processed (LSCAN, fallback: last processed closing deal time LDT),
//--- with a 6 h safety overlap. The marker advances only when every position found in the range has been registered, and positions are
//--- registered AND processed one by one in chronological order (so several offline trades rebuild the risk sequence in the right order).
void RecoverHistory()
  {
   datetime now=TimeCurrent();
   datetime anchor=(datetime)GV("LSCAN",0);
   if(anchor==0) anchor=(datetime)GV("LDT",0);
   if(anchor==0) { GS("LSCAN",(double)now); return; }
   datetime from=0;
   if(anchor>(datetime)YT_SCAN_BUFFER_SEC) from=anchor-(datetime)YT_SCAN_BUFFER_SEC;
   if(!HistorySelect(from,now+60)) return;
   int n=HistoryDealsTotal();
   ulong cand[];
   for(int i=0;i<n;i++)
     {
      ulong d=HistoryDealGetTicket(i);
      if(d==0) continue;
      if(HistoryDealGetString(d,DEAL_SYMBOL)!=g_sym) continue;
      if((long)HistoryDealGetInteger(d,DEAL_MAGIC)!=g_magic) continue;
      if(HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;
      ulong pid=(ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID);
      if(PHas(pid,"N") || IsLoggedPos(pid)) continue;
      bool dup=false;
      for(int k=0;k<ArraySize(cand);k++) if(cand[k]==pid) { dup=true; break; }
      if(dup) continue;
      int c=ArraySize(cand);
      ArrayResize(cand,c+1);
      cand[c]=pid;
     }
   bool complete=true;
   for(int i=0;i<ArraySize(cand);i++)
     {
      //--- history order == chronological order of the entry deals
      if(RegisterPosition(cand[i])==0 && !PHas(cand[i],"N") && !IsLoggedPos(cand[i]))
        {
         complete=false;                       // history of this position is not ready yet: the marker must not pass it
         continue;
        }
      ulong lt=0;
      if(!FindLive(cand[i],lt)) ProcessClosedPosition(cand[i]);   // already closed (offline): apply it NOW, before the next one is registered
     }
   CheckClosures();
   if(complete)
     {
      GS("LSCAN",(double)now);
      GS("LSCANFAIL",0.0);
     }
   else
     {
      datetime f0=(datetime)GV("LSCANFAIL",0);
      if(f0==0)
        {
         GS("LSCANFAIL",(double)now);
         YLog("History recovery: a position could not be registered yet - the scan marker is NOT advanced (retried every 30 s).");
        }
      else if((long)(now-f0)>YT_SCAN_BUFFER_SEC)
        {
         GS("LSCAN",(double)now);
         GS("LSCANFAIL",0.0);
         RaiseAlert("RECOVERFAIL","History recovery could not register some position(s) for 6 hours - the scan marker was advanced. Check the Trades / Orders logs.",true,true);
        }
     }
  }

//+------------------------------------------------------------------+
//| Order placement                                                  |
//+------------------------------------------------------------------+
void HandleLotError(const string err)
  {
   g_blockReason=err;
   g_nextPlaceMs=GetTickCount64()+30000;
   YLog("Execution blocked: "+err);
   string key="LOT";
   if(StringFind(err,"margin")>=0) { key="MARGIN"; YLog("Insufficient Margin"); }
   RaiseAlert(key+err,err,true,true);
  }

//--- true when every pending order wanted by the current mode really exists on the server
bool AllNeededPlaced()
  {
   bool nb=(g_mode==YM_BOTH || g_mode==YM_BUY), ns=(g_mode==YM_BOTH || g_mode==YM_SELL);
   bool hb=false, hs=false;
   ulong t[];
   int n=OwnOrders(t);
   for(int i=0;i<n;i++)
     {
      if(!OrderSelect(t[i])) continue;
      long ty=OrderGetInteger(ORDER_TYPE);
      if(ty==ORDER_TYPE_BUY_STOP)  hb=true;
      if(ty==ORDER_TYPE_SELL_STOP) hs=true;
     }
   return ((!nb || hb) && (!ns || hs));
  }

bool TryPlace(const bool buy,const double level)
  {
   int s=SideIdx(buy);
   ulong nowMs=GetTickCount64();
   if(nowMs<g_nextPlaceMs)
     {
      if(g_sync[s]==YS_CREATING) SetSync(buy,YS_WAITING,"Retry cooldown");
      return false;
     }
   MqlTick tk;
   if(!SymbolInfoTick(g_sym,tk) || tk.ask<=0.0 || tk.bid<=0.0)
     {
      SetSync(buy,YS_WAITING,"No market prices");
      return false;
     }
   //--- broker / market rules: a request that the server would reject is never sent; the reason is shown (NOT PLACED)
   string pwhy="";
   if(!PlacementOk(buy,level,pwhy))
     {
      g_waitReason=(g_state==YT_WAITING_REENTRY?"Re-entry: ":"")+pwhy;
      SetSync(buy,YS_WAITING,g_waitReason);
      return false;
     }
   g_waitReason="";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      g_nextPlaceMs=nowMs+15000;
      g_blockReason="AutoTrading / account trading disabled";
      SetSync(buy,YS_WAITING,g_blockReason);
      RaiseAlert("AUTOTR","Trading is not allowed (AutoTrading disabled or account restriction).",true,true);
      return false;
     }
   double lot=0,est=0; string err="";
   if(!CalcLot(g_curRisk,buy,level,lot,est,err)) { HandleLotError(err); SetSync(buy,YS_FAILED,err); return false; }
   g_blockReason="";
   ClearAlert("MARGIN"+err);

   double slp=SLPrice(buy,level), tpp=TPPrice(buy,level);
   SetSync(buy,YS_CREATING,"Placing "+PX(level));
   UpdatePanel();                                    // the panel shows PLACING while the server works
   g_trade.SetDeviationInPoints(g_maxDev);
   bool r=buy?g_trade.BuyStop(lot,level,g_sym,slp,tpp,ORDER_TIME_GTC,0,"Yetimmm")
             :g_trade.SellStop(lot,level,g_sym,slp,tpp,ORDER_TIME_GTC,0,"Yetimmm");
   uint rc=g_trade.ResultRetcode();
   bool ok=(r && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED || rc==TRADE_RETCODE_DONE_PARTIAL));
   long otype=buy?(long)ORDER_TYPE_BUY_STOP:(long)ORDER_TYPE_SELL_STOP;
   if(ok)
     {
      ulong ticket=g_trade.ResultOrder();
      g_failCount=0;
      //--- the retcode alone is not proof: the order must exist on the server with the requested values
      string vwhy="";
      bool verified=VerifyPlaced(ticket,buy,level,lot,slp,tpp,vwhy);
      if(!verified)
        {
         g_guardTk[s]=ticket;
         g_guardMs[s]=GetTickCount64()+4000;
         LogOrder("PLACED_UNVERIFIED",otype,level,lot,ticket,rc,vwhy);
         YLog(SideName(buy)+" accepted by the server but NOT verified: "+vwhy);
         SetSync(buy,YS_CREATING,"Awaiting server confirmation: "+vwhy);
         g_dirty=true;
         return false;
        }
      TrkTake(buy,ticket);
      g_placedMs[s]=GetTickCount64();
      LogOrder("PLACED",otype,level,lot,ticket,rc,"Risk $"+D2(g_curRisk)+" SL "+PX(slp)+" TP "+PX(tpp));
      SetSync(buy,YS_PLACED,"Ticket #"+UL(ticket));
      PanelMsg(SideName(buy)+" PLACED #"+UL(ticket)+" @ "+PX(level),clrLime);
      bool reentry=(g_state==YT_WAITING_REENTRY);
      YLog(reentry?(buy?"Re-entry Order Placed: Buy Stop ":"Re-entry Order Placed: Sell Stop ")+PX(level)+" #"+UL(ticket):(buy?"Buy Stop Placed ":"Sell Stop Placed ")+PX(level)+" #"+UL(ticket));
      if(reentry && AllNeededPlaced()) { g_state=YT_ARMED; SaveState(); }   // WAITING_REENTRY lasts until BOTH orders are on the server
      TgQueue((reentry?"🔁 RE-ENTRY ORDER PLACED":(buy?"📌 BUY STOP PLACED":"📌 SELL STOP PLACED"))+"\nTicket: #"+UL(ticket)+"\n"+(buy?"Buy Stop: ":"Sell Stop: ")+PX(level)+
              "\nLot: "+LotS(lot)+"\nRisk: $"+D2(g_curRisk)+"\nEstimated Loss at SL: $"+D2(est)+"\nSL: "+PX(slp)+"\nTP: "+PX(tpp));
      return true;
     }

   //--- rejected
   string cm=g_trade.ResultComment();
   LogOrder("REJECTED",otype,level,lot,0,rc,cm);
   SetSync(buy,YS_FAILED,"NOT PLACED: "+cm+" [retcode "+IntegerToString((int)rc)+"]");
   PanelMsg(SideName(buy)+" NOT PLACED: "+cm,clrTomato);
   YLog("Execution Rejected: retcode "+IntegerToString((int)rc)+" "+cm);
   ulong delay=2000;
   bool transient=false;
   switch((int)rc)
     {
      case TRADE_RETCODE_NO_MONEY:         g_blockReason="Insufficient margin for required risk."; delay=30000; transient=true; break;
      case TRADE_RETCODE_MARKET_CLOSED:    g_blockReason="Market closed"; delay=30000; transient=true; break;
      case TRADE_RETCODE_TRADE_DISABLED:
      case TRADE_RETCODE_CLIENT_DISABLES_AT:
      case TRADE_RETCODE_SERVER_DISABLES_AT: g_blockReason="Trading disabled"; delay=15000; transient=true; break;
      case TRADE_RETCODE_CONNECTION:       delay=5000; transient=true; break;
      case TRADE_RETCODE_TOO_MANY_REQUESTS:delay=10000; transient=true; break;
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_INVALID_PRICE:    delay=1500; transient=true; break;
      default:
         g_failCount++;
         delay=(ulong)MathMin(60000.0,2000.0*MathPow(2.0,MathMin(g_failCount,5)));
         break;
     }
   g_nextPlaceMs=nowMs+delay;
   RaiseAlert("REJ"+IntegerToString((int)rc),"Order rejected (NOT PLACED) ("+(buy?"Buy Stop":"Sell Stop")+" "+PX(level)+"): "+cm+" [retcode "+IntegerToString((int)rc)+"]",true,true);
   if(!transient && g_failCount>=8)
     {
      g_state=YT_ERROR;
      GS("REVERR",0.0);                          // a placement error is not a reversal error: /start re-arms normally
      SaveState();
      RaiseAlert("ERRSTATE","Bot moved to ERROR state after repeated order failures. Fix the issue, then use /start or enter levels.",true,true);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| v2.00: ONE position at most. If more than one exists (e.g. both  |
//| stop orders were triggered inside one price gap) the oldest is   |
//| kept and the others are closed.                                  |
//+------------------------------------------------------------------+
void EnforceSinglePosition(const ulong &pos[],const int np)
  {
   ulong nowMs=GetTickCount64();
   if(nowMs<g_nextExtraMs) return;
   g_nextExtraMs=nowMs+2000;
   ulong keep=0; long kt=0;
   for(int i=0;i<np;i++)
     {
      if(!PositionSelectByTicket(pos[i])) continue;
      long tm=PositionGetInteger(POSITION_TIME_MSC);
      if(keep==0 || tm<kt) { keep=pos[i]; kt=tm; }
     }
   for(int i=0;i<np;i++)
     {
      if(pos[i]==keep) continue;
      if(!PositionSelectByTicket(pos[i])) continue;
      ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      long ot=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?(long)ORDER_TYPE_BUY:(long)ORDER_TYPE_SELL;
      double px=PositionGetDouble(POSITION_PRICE_OPEN), lt=PositionGetDouble(POSITION_VOLUME);
      PSet(pid,"CRC",5.0);
      GlobalVariablesFlush();
      ulong exitDev=(ulong)MathMax(500,g_maxDev*10);
      bool ok=g_trade.PositionClose(pos[i],exitDev);
      uint rc=g_trade.ResultRetcode();
      LogOrder(ok?"EXTRA_POS_CLOSE":"EXTRA_POS_CLOSE_FAILED",ot,px,lt,pos[i],rc,"only one position is allowed");
      YLog(ok?"Extra position closed #"+UL(pos[i])+" (only one position is allowed)":"Extra position close FAILED #"+UL(pos[i])+" retcode "+IntegerToString((int)rc)+" (retrying)");
     }
  }

//+------------------------------------------------------------------+
//| v2.00 (BREACH_MARKET): the Stop-Loss itself already crossed the  |
//| opposite level, so a stop order cannot exist there. The opposite |
//| direction is opened at market (SL/TP from the same two levels).  |
//| returns true while this pass is consumed by the reversal.        |
//+------------------------------------------------------------------+
//--- v2.11: failure classes of a market reversal
//--- transient: can clear by itself (market closed, connection, requote ...) - never counted towards the ERROR threshold
bool RevRetcodeTransient(const uint rc)
  {
   switch((int)rc)
     {
      case TRADE_RETCODE_MARKET_CLOSED:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_TIMEOUT:
         return true;
     }
   return false;
  }

//--- permanent: retrying cannot help, the cause must be fixed by the user
bool RevRetcodePermanent(const uint rc)
  {
   switch((int)rc)
     {
      case TRADE_RETCODE_INVALID_VOLUME:
      case TRADE_RETCODE_LONG_ONLY:
      case TRADE_RETCODE_SHORT_ONLY:
      case TRADE_RETCODE_CLOSE_ONLY:
      case TRADE_RETCODE_LIMIT_VOLUME:
         return true;
     }
   return false;
  }

//--- the reversal cannot be executed: stop retrying, ERROR / MANUAL ACTION (resumed by /start or by new levels)
void RevEnterError(const string why)
  {
   g_state=YT_ERROR;
   g_mode=YM_NONE;
   g_revFails=0; g_revHard=0; g_nextRevMs=0;
   g_waitReason="";
   g_blockReason="MANUAL ACTION: market reversal cannot be executed - "+why;
   GS("REVERR",1.0);                              // remembers that /start or new levels must resume the REVERSAL (not a plain re-arm)
   SaveState();
   YLog("ERROR state: "+g_blockReason);
   RaiseAlert("REVERROR","🛑 ERROR - MANUAL ACTION REQUIRED: the market reversal failed ("+why+"). The opposite trade is NOT open and the bot stopped retrying. Fix the cause, then send /start or enter new levels to resume.",true,true);
   g_dirty=true;
  }

bool TryMarketReverse()
  {
   if(g_lastSLSide!=1 && g_lastSLSide!=2) return false;
   bool revBuy=(g_lastSLSide==2);                 // a Sell was stopped -> Buy next; a Buy was stopped -> Sell next
   double lvl=revBuy?g_buyLevel:g_sellLevel;      // the level that would have been the stop-order entry
   double slLvl=revBuy?g_sellLevel:g_buyLevel;    // SL of the new trade = the opposite level
   if(lvl<=0.0 || slLvl<=0.0 || g_buyLevel<=g_sellLevel) return false;
   MqlTick tk;
   if(!SymbolInfoTick(g_sym,tk) || tk.ask<=0.0 || tk.bid<=0.0) return false;
   bool breached=revBuy?(tk.ask>=lvl):(tk.bid<=lvl);
   if(!breached) { g_revHard=0; return false; }   // level still ahead of the price: a normal pending order is used
   ulong nowMs=GetTickCount64();
   if(nowMs<g_nextRevMs) return true;
   string why;
   if(!TradingAllowedNow(why)) { g_waitReason="Market reversal waiting: "+why; g_nextRevMs=nowMs+3000; return true; }

   //--- 1) REAL execution price, SL = the opposite level, TP from the REAL entry and the REAL SL distance
   //---    (so profit at TP = risk x R/R exactly as the recovery maths assumes, even after a gap)
   double entry=revBuy?tk.ask:tk.bid;
   double slp=RoundTick(slLvl);
   double realDist=MathAbs(entry-slp);
   double tpp=RoundTick(revBuy?entry+realDist*g_rr:entry-realDist*g_rr);

   //--- 2) PRE-FLIGHT against the real market: SL/TP on the correct side and outside the Stops Level
   if(!MarketPreflight(revBuy,slp,tpp,why))
     {
      g_revFails++;
      g_revHard++;
      g_waitReason="Market reversal blocked: "+why;
      g_nextRevMs=nowMs+(ulong)MathMin(15000.0,2000.0*g_revFails);
      LogOrder("MARKET_REVERSAL_BLOCKED",revBuy?(long)ORDER_TYPE_BUY:(long)ORDER_TYPE_SELL,entry,0.0,0,0,why);
      YLog("Market reversal blocked by pre-flight: "+why+" (attempt "+IntegerToString(g_revFails)+")");
      RaiseAlert("REVBLOCK","Market reversal NOT sent (pre-flight): "+why+". Retrying; the opposite trade is not open yet.",true,true);
      if(g_revHard>=YT_REV_MAX_HARD) RevEnterError("pre-flight keeps failing: "+why);
      return true;
     }

   //--- 3) lot from the REAL entry to the SL (a gap makes the SL farther -> a smaller lot; the risk stays = requested risk)
   double lot=0,est=0; string err="";
   if(!CalcLotSL(g_curRisk,revBuy,entry,slp,lot,est,err))
     {
      HandleLotError(err);
      g_nextRevMs=nowMs+5000;
      g_revHard++;
      if(g_revHard>=YT_REV_MAX_HARD) RevEnterError(err);
      return true;
     }

   //--- 4) one-position rule: no pending order may survive next to the market order
   ulong od[];
   int no=OwnOrders(od);
   for(int i=0;i<no;i++)
      if(!DeleteOrder(od[i],"Market reversal: pending orders removed")) { g_nextRevMs=nowMs+2000; return true; }

   //--- 5) send; the expected protection AND the expected price are remembered:
   //---    SL/TP -> repaired by the protection guard if missing; price -> REAL slippage is measured after the fill (RegisterPosition)
   GS("RVSL",slp); GS("RVTP",tpp); GS("RVEXP",entry);
   g_trade.SetDeviationInPoints(g_maxDev);
   //--- the expected price is sent with the request, so Max Slippage Check also works as a PRICE GUARD (a requote / reject instead of a bad fill)
   bool r=revBuy?g_trade.Buy(lot,g_sym,entry,slp,tpp,"Yetimmm"):g_trade.Sell(lot,g_sym,entry,slp,tpp,"Yetimmm");
   uint rc=g_trade.ResultRetcode();
   bool ok=(r && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED || rc==TRADE_RETCODE_DONE_PARTIAL));
   long ot=revBuy?(long)ORDER_TYPE_BUY:(long)ORDER_TYPE_SELL;
   if(ok)
     {
      g_revFails=0;
      g_revHard=0;
      g_waitReason="";
      double gapPts=MathAbs(entry-lvl)/g_point;
      LogOrder("MARKET_REVERSAL",ot,entry,lot,g_trade.ResultOrder(),rc,"level "+PX(lvl)+" already crossed (gap "+DoubleToString(gapPts,0)+" pts) | SL "+PX(slp)+" TP "+PX(tpp)+" | est. loss at SL $"+D2(est));
      YLog(string(revBuy?"Buy":"Sell")+" opened at market @ "+PX(entry)+" (level "+PX(lvl)+" already crossed after the Stop Loss) | lot "+LotS(lot)+" | est. loss at SL $"+D2(est));
      TgQueue("🔁 MARKET REVERSAL\n"+(revBuy?"BUY":"SELL")+" opened at market\nLevel crossed: "+PX(lvl)+" | Expected entry: "+PX(entry)+"\nLot: "+LotS(lot)+" (risk $"+D2(g_curRisk)+", est. loss at SL $"+D2(est)+")\nSL: "+PX(slp)+"\nTP: "+PX(tpp));
      g_dirty=true;
      return true;
     }
   GS("RVSL",0.0); GS("RVTP",0.0); GS("RVEXP",0.0);
   string cm=g_trade.ResultComment();
   g_revFails++;
   if(!RevRetcodeTransient(rc)) g_revHard++;
   LogOrder("MARKET_REVERSAL_FAILED",ot,entry,lot,0,rc,cm);
   YLog("Market reversal rejected: retcode "+IntegerToString((int)rc)+" "+cm+" (attempt "+IntegerToString(g_revFails)+")");
   g_nextRevMs=nowMs+(ulong)MathMin(15000.0,2000.0*g_revFails);
   if(g_revFails>=5) RaiseAlert("REVFAIL","Market reversal keeps failing ("+cm+" [retcode "+IntegerToString((int)rc)+"]). The opposite trade is NOT open - check the account / market.",true,true);
   if(RevRetcodePermanent(rc) || g_revHard>=YT_REV_MAX_HARD)
      RevEnterError(cm+" [retcode "+IntegerToString((int)rc)+"]");
   return true;
  }

//+------------------------------------------------------------------+
//| Reconcile: keep real account state == bot state (idempotent)     |
//+------------------------------------------------------------------+
void Reconcile()
  {
   if(!g_connected) return;
   ulong pos[];
   int np=OwnPositions(pos);
   if(np>0)
     {
      g_activeNoPosSince=0;
      if(g_state!=YT_STOPPED)
        {
         ulong newest=pos[np-1];
         if(PositionSelectByTicket(newest))
           {
            ENUM_YT_STATE want=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?YT_BUY_ACTIVE:YT_SELL_ACTIVE;
            if(g_state!=want) { g_state=want; g_mode=YM_NONE; SaveState(); }
           }
        }
      //--- the pending order that MT5 triggered is now a REAL position (FILLED); the opposite pending order must really disappear
      bool fillBuy=true, haveFill=false;
      if(PositionSelectByTicket(pos[np-1])) { fillBuy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY); haveFill=true; }
      int fIdx=SideIdx(fillBuy), oIdx=SideIdx(!fillBuy);
      bool hadFill=(g_stopTicket[fIdx]!=0), hadOpp=(g_stopTicket[oIdx]!=0);
      if(hadFill)
        {
         TrkDrop(fIdx);
         if(haveFill) SetSync(fillBuy,YS_FILLED,"Pending order triggered by MT5 - real position");
        }
      ulong od[];
      int no=OwnOrders(od);
      for(int i=0;i<no;i++)
        {
         if(DeleteOrder(od[i],"Opposite Order Deleted"))
            TgQueue("🗑 OPPOSITE ORDER DELETED\nTicket: "+UL(od[i]));
        }
      if(haveFill && (hadOpp || no>0))
        {
         ulong rest[];
         if(OwnOrders(rest)==0) SetSync(!fillBuy,YS_REMOVED,"Opposite pending order deleted (verified on the server)");
         else SetSync(!fillBuy,YS_FAILED,"Opposite pending order is still on the server");
        }
      if(np>1)
        {
         if(np!=g_lastPosCount)
           {
            YLog("Unexpected Multiple Positions: "+IntegerToString(np));
            RaiseAlert("MULTIPOS","Unexpected Multiple Positions ("+IntegerToString(np)+") on "+g_sym+" with this Magic Number. Only ONE position is allowed: the oldest is kept, the others are closed.",true,true);
           }
         EnforceSinglePosition(pos,np);
        }
      if(g_netting) NettingDriftCheck(pos[np-1]);
      //--- CRITICAL: every own position must carry SL and TP (retry / alert / emergency close inside ProtectPosition)
      for(int pq=0;pq<np;pq++)
        {
         if(!PositionSelectByTicket(pos[pq])) continue;
         ProtectPosition((ulong)PositionGetInteger(POSITION_IDENTIFIER));
        }
      //--- a fill that exceeded Max Slippage Check is closed; keep retrying until it is really closed
      for(int q=0;q<np;q++)
        {
         if(!PositionSelectByTicket(pos[q])) continue;
         ulong qpid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
         if((long)PGV(qpid,"CRC",0)==4 && GetTickCount64()>=g_nextDevCloseMs)
           {
            g_nextDevCloseMs=GetTickCount64()+2000;
            CloseRejected(qpid);
           }
        }
      g_lastPosCount=np;
      return;
     }
   g_lastPosCount=0;
   if(g_unprot) { g_unprot=false; g_unprotPid=0; ClearAlert("PROTFAIL"); if(StringFind(g_blockReason,"CRITICAL PROTECTION")==0) g_blockReason=""; }
   if(g_netTaint) { g_netTaint=false; ClearAlert("NETDRIFT"); }          // no own position left: nothing is contaminated any more
   if(NettingBlocked()) return;

   if(g_state==YT_BUY_ACTIVE || g_state==YT_SELL_ACTIVE)
     {
      //--- the closing deal has not been processed yet; never create orders before it is
      if(g_activeNoPosSince==0) g_activeNoPosSince=TimeCurrent();
      else if(TimeCurrent()-g_activeNoPosSince>20)
        {
         g_state=YT_IDLE; g_mode=YM_NONE; g_activeNoPosSince=0;
         SaveState();
         RaiseAlert("INCONS","Position vanished without a processed closing deal. Bot is waiting for levels.",true,true);
        }
      return;
     }
   if(g_state!=YT_ARMED && g_state!=YT_WAITING_REENTRY)
     {
      //--- no pending order is wanted in IDLE / TP_RESET / STOPPED: a leftover (e.g. the opposite order of a fast fill+TP) is removed
      if(g_state==YT_IDLE || g_state==YT_TP_RESET || g_state==YT_STOPPED)
        {
         ulong lo[];
         int ln=OwnOrders(lo);
         if(ln>0 && GetTickCount64()>=g_nextDelMs)
            for(int q=0;q<ln;q++)
               if(!DeleteOrder(lo[q],"No pending order is wanted in this state")) g_nextDelMs=GetTickCount64()+2000;
        }
      TrkPrune(); SetSync(true,YS_IDLE); SetSync(false,YS_IDLE); return;
     }
   if(g_mode==YM_NONE) { TrkPrune(); SetSync(true,YS_IDLE); SetSync(false,YS_IDLE); return; }

   bool needBuy=(g_mode==YM_BOTH || g_mode==YM_BUY);
   bool needSell=(g_mode==YM_BOTH || g_mode==YM_SELL);
   if(!needBuy)  SetSync(true,YS_IDLE);
   if(!needSell) SetSync(false,YS_IDLE);
   if((needBuy && g_buyLevel<=0.0) || (needSell && g_sellLevel<=0.0)) return;

   //--- v2.00: optional market reversal when the stop-out already crossed the opposite level
   if(g_state==YT_WAITING_REENTRY && InpBreachPolicy==BREACH_MARKET && TryMarketReverse()) return;

   //--- 0) manual changes in MT5 are DETECTED first (moved / deleted / SL-TP edited), then handled by the explicit policy
   bool held[2]={false,false};
   held[0]=ExternalCheck(true, needBuy, g_buyLevel);
   held[1]=ExternalCheck(false,needSell,g_sellLevel);
   if(g_restartPass) { g_restartPass=false; g_dirty=true; return; }   // state changed by a fill: re-evaluate from scratch

   double expBuy=0,expSell=0,e1,e2; string er;
   bool okB=needBuy && CalcLot(g_curRisk,true,g_buyLevel,expBuy,e1,er);
   bool okS=needSell && CalcLot(g_curRisk,false,g_sellLevel,expSell,e2,er);

   //--- 1) identity = Symbol + Magic + Order Type: pick ONE order per side to keep
   //---    (CanonicalTicket: tracked ticket, then exact desired price, then lowest ticket); everything else is a duplicate / not wanted
   ulong od[];
   int no=OwnOrders(od);
   ulong keepT[2]={0,0};
   if(needBuy)  keepT[0]=CanonicalTicket(true, g_buyLevel);     // same function the panel uses
   if(needSell) keepT[1]=CanonicalTicket(false,g_sellLevel);

   //--- 2) REMOVE: duplicates and orders that are no longer desired
   if(GetTickCount64()>=g_nextDelMs)
     {
      for(int i=0;i<no;i++)
        {
         if(od[i]==keepT[0] || od[i]==keepT[1]) continue;
         if(!OrderSelect(od[i])) continue;
         long type=OrderGetInteger(ORDER_TYPE);
         bool isB=(type==ORDER_TYPE_BUY_STOP), isS=(type==ORDER_TYPE_SELL_STOP);
         bool dup=((isB && needBuy) || (isS && needSell));
         bool notWanted=(!dup && (isB || isS));
         string why=dup?"Duplicate Order Prevented":"Unexpected pending order / not required";
         if(notWanted) SetSync(isB,YS_REMOVING,why);
         if(dup) YLog("Duplicate Order Prevented");
         if(DeleteOrder(od[i],why))
           {
            if(notWanted) SetSync(isB,YS_IDLE);
           }
         else
           {
            g_nextDelMs=GetTickCount64()+2000;
            if(notWanted) SetSync(isB,YS_FAILED,"REMOVE FAILED: "+why);
           }
        }
     }

   //--- 3) per side: KEEP / MODIFY / REPLACE (lot change only) / CREATE
   //--- v2.11: COMBINED margin. Both stop orders are required; the orders that are still MISSING are sent only when the margin of ALL of them
   //--- is available, so the bot never ends with "one side placed, the other rejected for NO MONEY". Existing orders are still verified / modified.
   bool cmHold=false;
   if(InpCombinedMargin && needBuy && needSell && okB && okS && (keepT[0]==0 || keepT[1]==0))
     {
      double mB=0.0,mS=0.0,mNeed=0.0;
      if(keepT[0]==0 && OrderCalcMargin(ORDER_TYPE_BUY, g_sym,expBuy, g_buyLevel, mB)) mNeed+=mB;
      if(keepT[1]==0 && OrderCalcMargin(ORDER_TYPE_SELL,g_sym,expSell,g_sellLevel,mS)) mNeed+=mS;
      double mFree=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(mNeed>mFree+1e-9)
        {
         cmHold=true;
         string cmMsg="Insufficient COMBINED margin: the missing pending order(s) need $"+D2(mNeed)+", free margin is $"+D2(mFree);
         g_waitReason=cmMsg;
         if(keepT[0]==0) SetSync(true, YS_WAITING,cmMsg);
         if(keepT[1]==0) SetSync(false,YS_WAITING,cmMsg);
         if(!g_cmWarned)
           {
            g_cmWarned=true;
            YLog(cmMsg+" - the missing order(s) are NOT sent until the margin allows both.");
            RaiseAlert("COMBMARGIN","⚠️ "+cmMsg+". Both stop orders are required; the missing one(s) will be sent as soon as the margin allows.",true,true);
           }
        }
     }
   if(!cmHold && g_cmWarned)
     {
      g_cmWarned=false;
      ClearAlert("COMBMARGIN");
      if(StringFind(g_waitReason,"COMBINED margin")>=0) g_waitReason="";
     }
   if(needBuy  && !held[0] && !(cmHold && keepT[0]==0)) ReconcileSide(true, g_buyLevel, expBuy, okB,keepT[0]);
   if(needSell && !held[1] && !(cmHold && keepT[1]==0)) ReconcileSide(false,g_sellLevel,expSell,okS,keepT[1]);
  }

void SyncAll()
  {
   if(g_busy) return;
   g_busy=true;
   RegisterLivePositions();
   CheckClosures();
   Reconcile();
   g_busy=false;
   g_lastSyncMs=GetTickCount64();
  }

//+------------------------------------------------------------------+
//| Levels / Start / Stop / Cancel                                   |
//+------------------------------------------------------------------+
//--- true while a risk sequence is running: its ORIGINAL levels are frozen
bool SequenceLocked()
  {
   ulong tk[];
   if(OwnPositions(tk)>0) return true;                                  // a real position is open: there is no pending order to move
   if(g_state==YT_BUY_ACTIVE || g_state==YT_SELL_ACTIVE) return true;
   if(InpSeqPolicy==YT_SEQ_APPLY_NOW) return false;                     // pending orders of a running sequence follow APPLY immediately
   if(g_state==YT_WAITING_REENTRY) return true;
   if((g_state==YT_ARMED || g_state==YT_ERROR) && (g_mode==YM_BUY || g_mode==YM_SELL)) return true;
   return false;
  }

//--- levels entered during a sequence become active only after the sequence ends
void PromotePending()
  {
   if(g_pendBuy>0.0 && g_pendSell>0.0)
     {
      g_buyLevel=g_pendBuy;
      g_sellLevel=g_pendSell;
      YLog("Pending levels now active: Buy "+PX(g_buyLevel)+" Sell "+PX(g_sellLevel));
     }
   g_pendBuy=0.0;
   g_pendSell=0.0;
   g_fresh=false;
  }

bool ApplyLevels(const double buy,const double sell,const double risk,const string src,string &err)
  {
   err=ValidateLevels(buy,sell);
   if(err=="" && risk>0.0) err=ValidateRisk(risk);
   if(err!="")
     {
      YLog("Invalid Configuration ("+src+"): "+err);
      if(src!="Telegram") RaiseAlert("INVALID","Invalid Price Configuration: "+err,true,true);
      return false;
     }
   g_applyNote="";
   const bool locked=SequenceLocked();
   bool riskSame=(risk<=0.0 || MathAbs(risk-g_initRisk)<1e-9);

   //--- a live order that has to be MODIFIED must accept its new price right now (stops level / freeze level)
   if(!locked)
     {
      string pre=CheckApplicable(buy,sell,risk);
      if(pre!="")
        {
         err=pre;
         YLog("Invalid Configuration ("+src+"): "+err);
         if(src!="Telegram") RaiseAlert("INVALID","Cannot apply levels: "+err,true,true);
         return false;
        }
     }

   //--- APPLY with an identical desired state: nothing to send, the real orders are just verified
   bool same=locked?(g_fresh && PriceEq(g_pendBuy,buy) && PriceEq(g_pendSell,sell) && riskSame)
                   :((g_state==YT_ARMED || g_state==YT_WAITING_REENTRY) && g_mode!=YM_NONE && PriceEq(g_buyLevel,buy) && PriceEq(g_sellLevel,sell) && riskSame);
   ResetSyncBackoff();
   if(same)
     {
      YLog("APPLY ("+src+"): desired levels are already active - nothing to change");
      g_dirty=true;
      SyncAll();
      bool allOk=true;
      if(!locked)
         for(int k=0;k<2;k++)
           {
            bool sb=(k==0);
            double dl;
            if(SideDesired(sb,dl) && SideStatusShown(sb)!=YS_SYNCED && SideStatusShown(sb)!=YS_PLACED) allOk=false;
           }
      g_applyNote=allOk?"NOTHING TO DO":"";
      return true;
     }

   if(risk>0.0) g_initRisk=risk;
   g_failCount=0; g_nextPlaceMs=0; g_blockReason="";

   //--- a sequence is running: it keeps its ORIGINAL levels, the new ones wait for the next TP
   if(locked)
     {
      g_pendBuy=buy;
      g_pendSell=sell;
      g_fresh=true;
      YLog("New levels ("+src+") stored as PENDING: Buy "+PX(buy)+" Sell "+PX(sell)+" | running sequence keeps ORIGINAL levels Buy "+PX(g_buyLevel)+" Sell "+PX(g_sellLevel));
      if(g_state==YT_ERROR && (g_mode==YM_BUY || g_mode==YM_SELL)) g_state=YT_WAITING_REENTRY;
      if(g_accLoss<=1e-9) g_curRisk=g_initRisk;
      SaveState();
      g_dirty=true;
      SyncAll();
      g_applyNote="QUEUED";
      return true;
     }

   g_pendBuy=0.0; g_pendSell=0.0; g_fresh=false;
   g_buyLevel=buy;
   g_sellLevel=sell;
   YLog("New Buy/Sell Levels ("+src+"): Buy "+PX(buy)+" Sell "+PX(sell)+" Risk "+D2(g_initRisk));
   switch(g_state)
     {
      case YT_STOPPED:
         if(InpResetRiskOnStart) ResetRisk();
         g_state=YT_ARMED; g_mode=YM_BOTH; g_stopCleanup=false;
         break;
      case YT_ERROR:
         if(GV("REVERR",0.0)>0.5 && (g_lastSLSide==1 || g_lastSLSide==2))
           {
            //--- v2.11: a failed market reversal resumes as a REVERSAL at the new levels (direction kept)
            g_state=YT_WAITING_REENTRY; g_mode=YM_BOTH;
            g_revFails=0; g_revHard=0; g_nextRevMs=0;
           }
         else
           {
            g_state=YT_ARMED; if(g_mode==YM_NONE) g_mode=YM_BOTH;
           }
         GS("REVERR",0.0);
         break;
      case YT_WAITING_REENTRY:
         if(g_mode==YM_NONE) g_mode=YM_BOTH;           // a running sequence keeps its state / side; only the levels move
         break;
      default:
         g_state=YT_ARMED;
         if(g_mode!=YM_BUY && g_mode!=YM_SELL) g_mode=YM_BOTH;   // ARMED single-side (sequence) keeps its side
         break;
     }
   if(g_accLoss<=1e-9) g_curRisk=g_initRisk;
   SaveState();
   g_dirty=true;
   SyncAll();
   return true;
  }

string LevelsAcceptedText()
  {
   string t;
   if(g_fresh && g_pendBuy>0.0 && g_pendSell>0.0)
      t="✅ LEVELS ACCEPTED (PENDING)\nA sequence is running and keeps its ORIGINAL levels:\nBuy Stop: "+PX(g_buyLevel)+"\nSell Stop: "+PX(g_sellLevel)+
        "\nNew levels start after the next TP:\nBuy Stop: "+PX(g_pendBuy)+"\nSell Stop: "+PX(g_pendSell)+"\nInitial Risk: $"+D2(g_initRisk)+"\nStatus: "+StateText();
   else
      t="✅ LEVELS ACCEPTED\nBuy Stop: "+PX(g_buyLevel)+"\nSell Stop: "+PX(g_sellLevel)+"\nInitial Risk: $"+D2(g_initRisk)+"\nStatus: "+StateText();
   return t;
  }

string DoStart(const string src)
  {
   if(StringFind(g_sym,"XAUUSD")<0) return "❌ START FAILED\nReason: Symbol is not XAUUSD.";
   if(!g_connected) return "❌ START FAILED\nReason: No connection to the trade server.";
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return "❌ START FAILED\nReason: AutoTrading is disabled.";
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return "❌ START FAILED\nReason: Trading not allowed on this account.";
   if(g_netting && ExternalPositionVolume()>0.0)
      return "❌ START FAILED\nReason: Netting account and an external "+g_sym+" position exists. Yetimmm will not run until it is closed.";
   if(g_state==YT_BUY_ACTIVE || g_state==YT_SELL_ACTIVE || g_state==YT_ARMED || g_state==YT_WAITING_REENTRY)
     {
      SyncAll();
      return "✅ Yetimmm is already RUNNING\nState: "+StateText()+"\nBuy Stop: "+PX(g_buyLevel)+"\nSell Stop: "+PX(g_sellLevel);
     }
   if(g_state==YT_TP_RESET)
      return "ℹ️ Yetimmm is RUNNING\nStatus: WAITING FOR LEVELS\nSend /set BUY SELL [RISK] to continue.";
   if(g_fresh) PromotePending();
   string err=ValidateLevels(g_buyLevel,g_sellLevel);
   if(err!="") return "❌ START FAILED\nReason:\nInvalid Buy/Sell levels. "+err;
   if(g_state==YT_STOPPED && InpResetRiskOnStart) ResetRisk();
   //--- v2.11: after a market-reversal ERROR the REVERSAL is resumed (WAITING_REENTRY keeps the direction); every other start re-arms normally
   bool resumeRev=(g_state==YT_ERROR && GV("REVERR",0.0)>0.5 && (g_lastSLSide==1 || g_lastSLSide==2));
   GS("REVERR",0.0);
   g_revFails=0; g_revHard=0; g_nextRevMs=0;
   if(resumeRev) { g_state=YT_WAITING_REENTRY; g_mode=YM_BOTH; }
   else { g_state=YT_ARMED; if(g_mode==YM_NONE) g_mode=YM_BOTH; }
   g_stopCleanup=false; g_failCount=0; g_nextPlaceMs=0; g_blockReason="";
   ResetSyncBackoff();
   SaveState();
   YLog("EA Started ("+src+")");
   SyncAll();
   if(g_state==YT_ERROR) return "❌ START FAILED\nReason: Bot entered ERROR state. See Journal.";
   ulong od[]; int no=OwnOrders(od);
   string t="✅ START EXECUTED\nYetimmm is now RUNNING.\nBuy Stop: "+PX(g_buyLevel)+"\nSell Stop: "+PX(g_sellLevel)+"\nRisk: $"+D2(g_curRisk)+"\nPending orders: "+IntegerToString(no)+"\nSync: "+SyncSummary();
   if(StringLen(g_blockReason)>0) t+="\n⚠️ "+g_blockReason;
   if(StringLen(g_waitReason)>0) t+="\n⏳ "+g_waitReason;
   return t;
  }

bool CleanupPositions(const int code)
  {
   if(g_netting && g_netTaint)
     {
      YLog("Netting: close refused - the position contains external volume.");
      RaiseAlert("NETCLOSE","Netting account: the Yetimmm position contains external volume, so it was NOT closed automatically. Close it manually.",true,true);
      return false;
     }
   ulong tk[];
   int n=OwnPositions(tk);
   for(int i=0;i<n;i++)
     {
      if(!PositionSelectByTicket(tk[i])) continue;
      ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      PSet(pid,"CRC",(double)code);
      if(!g_trade.PositionClose(tk[i]))
         YLog("Close position failed #"+UL(tk[i])+" retcode "+IntegerToString((int)g_trade.ResultRetcode()));
     }
   return OwnPositions(tk)==0;
  }

bool CleanupOrders(const string reason)
  {
   ulong od[];
   int n=OwnOrders(od);
   for(int i=0;i<n;i++) DeleteOrder(od[i],reason);
   return OwnOrders(od)==0;
  }

//--- race-free cleanup: pending orders are deleted FIRST (nothing can trigger afterwards), then positions are closed
//--- (including one that filled during the deletion), and BOTH are re-verified before success is reported
bool StopSweep(const int code,const string reason)
  {
   for(int pass=0;pass<4;pass++)
     {
      CleanupOrders(reason);
      CleanupPositions(code);
      ulong a[],b[];
      if(OwnOrders(a)==0 && OwnPositions(b)==0) return true;
      if(g_netting && g_netTaint) break;
      Sleep(150);
     }
   return false;
  }

//--- STOP: no new orders, delete own orders first, then close own trades (verified)
bool ExecStop(const int code,const long chat)
  {
   if(g_fresh) PromotePending();
   g_state=YT_STOPPED;
   g_mode=YM_NONE;
   g_fresh=false;
   SaveState();
   YLog(code==2?"Telegram Stop":"Manual Stop");
   bool done=StopSweep(code,code==2?"Telegram Stop":"Manual Stop");
   if(done)
     {
      g_stopCleanup=false;
      CheckClosures();
      return true;
     }
   g_stopCleanup=true; g_stopTries=0; g_stopCode=code; g_stopChat=chat; g_stopLastTry=TimeLocal();
   return false;
  }

void StopCleanupTick()
  {
   if(!g_stopCleanup) return;
   if(TimeLocal()-g_stopLastTry<2) return;
   g_stopLastTry=TimeLocal();
   g_stopTries++;
   bool done=StopSweep(g_stopCode,"Stop cleanup");
   if(done)
     {
      g_stopCleanup=false;
      CheckClosures();
      YLog("Stop completed after retries");
      TgQueue("✅ STOP EXECUTED\nYetimmm is now STOPPED. All Yetimmm trades closed and orders deleted.",g_stopChat);
     }
   else if(g_stopTries>=30)
     {
      g_stopCleanup=false;
      RaiseAlert("STOPFAIL","STOP FAILED: could not close/delete all Yetimmm trades and orders. Manual action required.",true,true);
     }
  }

string StopResultText(const bool done)
  {
   if(done) return "✅ STOP EXECUTED\nYetimmm is now STOPPED.\nYetimmm trades closed and pending orders deleted. Other trades untouched.";
   return "⏳ STOP IN PROGRESS\nBot is STOPPED; closing remaining Yetimmm trades/orders. A confirmation follows when verified.";
  }

string ExecCancel(const bool closePos)
  {
   g_mode=YM_NONE;
   if(g_state==YT_ARMED || g_state==YT_WAITING_REENTRY) g_state=YT_IDLE;
   ulong ctk[];
   if(g_state==YT_IDLE && g_fresh && OwnPositions(ctk)==0) PromotePending();
   SaveState();
   bool o=CleanupOrders("Cancelled by user");
   string t="";
   if(o) t="✅ Pending orders cancelled.";
   else t="❌ Could not delete all pending orders.";
   ulong tk[];
   if(OwnPositions(tk)>0)
     {
      if(closePos)
        {
         bool p=StopSweep(3,"Cancelled by user");
         t+=p?"\n✅ Open position closed.":"\n❌ Could not close the open position.";
         CheckClosures();
        }
      else t+="\n⚠️ Open position kept.";
     }
   YLog("Telegram Cancel / Cancel executed");
   g_dirty=true;
   return t;
  }

//+------------------------------------------------------------------+
//| Telegram command handling                                        |
//+------------------------------------------------------------------+
double ParseNum(string s)
  {
   StringReplace(s,",",".");
   return StringToDouble(s);
  }

string NewNonce() { return IntegerToString((long)(GetTickCount64()%1000000))+IntegerToString(MathRand()%1000); }

void TgCommand(const string text,const long chat,const long from)
  {
   string t=text;
   StringTrimLeft(t); StringTrimRight(t);
   if(StringLen(t)==0 || StringGetCharacter(t,0)!='/') return;
   string raw[];
   int rn=StringSplit(t,' ',raw);
   string a[];
   for(int i=0;i<rn;i++)
      if(StringLen(raw[i])>0) { int k=ArraySize(a); ArrayResize(a,k+1); a[k]=raw[i]; }
   int argc=ArraySize(a);
   if(argc==0) return;
   string cmd=a[0];
   StringToLower(cmd);
   int at=StringFind(cmd,"@");
   if(at>0) cmd=StringSubstr(cmd,0,at);

   YLog("Telegram Command Received: "+cmd);
   if(!g_tgCtl)
     {
      YLog("Telegram Command Rejected: control disabled");
      TgQueue("⛔ Telegram control is disabled in the EA settings.",chat);
      return;
     }

   //--- duplicate protection for state-changing commands
   bool mutating=(cmd=="/start" || cmd=="/stop" || cmd=="/set" || cmd=="/cancel");
   if(mutating)
     {
      string key=IntegerToString(from)+"|"+t;
      if(key==g_lastCmdKey && TimeLocal()-g_lastCmdTime<=6)
        {
         YLog("Telegram Command Rejected: duplicate");
         TgQueue("⚠️ Command already processed.",chat);
         return;
        }
      g_lastCmdKey=key;
      g_lastCmdTime=TimeLocal();
     }

   if(cmd=="/start")
     {
      TgQueue(DoStart("Telegram"),chat,MenuMarkup());
     }
   else if(cmd=="/stop")
     {
      ulong tk[];
      if(OwnPositions(tk)>0)
        {
         ulong tkt,pid; bool buy; double vol,entry,sl,tp,pr;
         string info="";
         if(OwnPosInfo(tkt,pid,buy,vol,entry,sl,tp,pr)) info="\nTrade #"+TNo((long)PGV(pid,"N",0))+"\n"+(buy?"BUY":"SELL")+"\nP/L: "+Money(pr);
         g_confAction="STOP"; g_confNonce=NewNonce(); g_confExpire=TimeLocal()+60;
         TgQueue("⚠️ يوجد Position مفتوح."+info+"\nهل تريد الإغلاق وإيقاف البوت؟",chat,ConfirmMarkup(g_confNonce,"✅ CONFIRM","✖ CANCEL"));
        }
      else
        {
         bool done=ExecStop(2,chat);
         TgQueue(StopResultText(done),chat);
        }
     }
   else if(cmd=="/cancel")
     {
      ulong tk[];
      bool hasPos=(OwnPositions(tk)>0);
      string res=ExecCancel(false);
      TgQueue("⚠️ سيتم إلغاء أوامر Yetimmm المعلقة.\n"+res,chat);
      if(hasPos)
        {
         g_confAction="CANCELCLOSE"; g_confNonce=NewNonce(); g_confExpire=TimeLocal()+60;
         TgQueue("⚠️ توجد صفقة مفتوحة. هل تريد إغلاقها أيضاً؟",chat,ConfirmMarkup(g_confNonce,"✅ CLOSE POSITION","✖ KEEP"));
        }
     }
   else if(cmd=="/set")
     {
      if(argc<3 || argc>4) { TgQueue("Usage: /set BUY SELL [RISK]\nExample: /set 4138 4137 1",chat); return; }
      double b=ParseNum(a[1]), s=ParseNum(a[2]);
      double r=(argc==4)?ParseNum(a[3]):0.0;
      if(argc==4 && r<=0.0) { TgQueue("❌ Invalid Price Configuration\nRisk must be a positive number.",chat); return; }
      string err;
      if(ApplyLevels(b,s,r,"Telegram",err)) TgQueue(LevelsAcceptedText(),chat);
      else TgQueue("❌ Invalid Price Configuration\n"+err,chat);
     }
   else if(cmd=="/status") TgQueue(StatusText(),chat,MenuMarkup());
   else if(cmd=="/open")   TgQueue(OpenText(),chat);
   else if(cmd=="/orders") TgQueue(OrdersText(),chat);
   else if(cmd=="/history")
     {
      int c=(argc>=2)?(int)StringToInteger(a[1]):10;
      int sk=(argc>=3)?(int)StringToInteger(a[2]):0;
      TgQueue(HistoryText(c,sk),chat);
     }
   else if(cmd=="/last")     TgQueue(LastText(),chat);
   else if(cmd=="/stats")    TgQueue(StatsText(),chat);
   else if(cmd=="/risk")     TgQueue(RiskText(),chat);
   else if(cmd=="/settings") TgQueue(SettingsText(),chat);
   else if(cmd=="/menu")     TgQueue("🤖 Yetimmm\nStatus: "+RunStatus(),chat,MenuMarkup());
   else if(cmd=="/help")     TgQueue(HelpText(),chat,MenuMarkup());
   else TgQueue("Unknown command. Send /help",chat);
  }

void TgCallback(const string cbId,const string data,const long chat,const long from)
  {
   string resp;
   TgCall("answerCallbackQuery","callback_query_id="+UrlEnc(cbId),resp);
   if(StringFind(data,"CMD:")==0)
     {
      TgCommand("/"+StringSubstr(data,4),chat,from);
      return;
     }
   bool yes=(StringFind(data,"C1:")==0);
   bool no=(StringFind(data,"C0:")==0);
   if(!yes && !no) return;
   string nonce=StringSubstr(data,3);
   if(g_confNonce=="" || nonce!=g_confNonce || TimeLocal()>g_confExpire)
     {
      TgQueue("⚠️ Command already processed (or confirmation expired).",chat);
      return;
     }
   string action=g_confAction;
   g_confNonce=""; g_confAction="";
   if(no) { TgQueue("Cancelled. No action taken.",chat); return; }
   if(action=="STOP")
     {
      bool done=ExecStop(2,chat);
      TgQueue(StopResultText(done),chat);
     }
   else if(action=="CANCELCLOSE")
     {
      bool p=CleanupPositions(3);
      CheckClosures();
      TgQueue(p?"✅ Open position closed.":"❌ Could not close the open position.",chat);
     }
  }

string SecFile() { return "Yetimmm_"+IntegerToString(g_magic)+"_Security.csv"; }

void SecurityLog(const long from,const long chat,const string what)
  {
   string w=Clean(what);
   if(StringLen(w)>60) w=StringSubstr(w,0,60);
   AppendLine(SecFile(),"Time;FromID;ChatID;Event;Content",
              TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+";"+IntegerToString(from)+";"+IntegerToString(chat)+";UNAUTHORIZED_REJECTED;"+w);
  }

void TgPoll()
  {
   if(!TgActive() || !g_connected) return;
   if(TimeLocal()-g_tgLastPoll<MathMax(1,InpTgPollSec)) return;
   g_tgLastPoll=TimeLocal();
   bool baseline=!GHas("TGINIT");
   string body;
   if(baseline) body="offset=-1&timeout=0";
   else body="offset="+IntegerToString(g_tgLast+1)+"&timeout=0&allowed_updates="+UrlEnc("[\"message\",\"callback_query\"]");
   string resp;
   if(!TgCall("getUpdates",body,resp)) return;
   string marker="\"update_id\":";
   int mlen=StringLen(marker);
   int p=0;
   while(true)
     {
      int a=StringFind(resp,marker,p);
      if(a<0) break;
      int b=StringFind(resp,marker,a+mlen);
      string seg=(b<0)?StringSubstr(resp,a):StringSubstr(resp,a,b-a);
      bool f;
      long uid=JNum(seg,marker,f);
      if(f && uid>g_tgLast)
        {
         g_tgLast=uid;                       // persist before executing (at-most-once)
         GS("TGLAST",(double)g_tgLast);
         if(!baseline)
           {
            bool isCb=(StringFind(seg,"\"callback_query\":")>=0);
            bool f1,f2;
            long from=JNum(seg,"\"from\":{\"id\":",f1);
            long chat=JNum(seg,"\"chat\":{\"id\":",f2);
            if(!f2) chat=from;
            if(!f1 || !TgAuthorized(from))
              {
               string uText=isCb?JStr(seg,"\"data\":\""):JStr(seg,"\"text\":\"");
               YLog("Telegram User Unauthorized (id "+IntegerToString(from)+") - command rejected, no action taken");
               SecurityLog(from,chat,uText);
               if(AlertThrottle("UNAUTH"+IntegerToString(from),300))
                  TgQueue("🚫 UNAUTHORIZED TELEGRAM ACCESS ATTEMPT\nID: "+IntegerToString(from)+"\nThe command was rejected; no trading action was taken.");
              }
            else if(isCb)
              {
               string cid=JStr(seg,"\"callback_query\":{\"id\":\"");
               string data=JStr(seg,"\"data\":\"");
               TgCallback(cid,data,chat,from);
              }
            else
              {
               string text=JStr(seg,"\"text\":\"");
               TgCommand(text,chat,from);
              }
           }
        }
      if(b<0) break;
      p=b;
     }
   if(baseline) GS("TGINIT",1.0);
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
//| Monitors                                                         |
//+------------------------------------------------------------------+
void MonitorConnection()
  {
   bool c=(bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   if(c && !g_connected)
     {
      g_connected=true;
      YLog("Connection Restored");
      RecoverHistory();
      g_dirty=true;
      SyncAll();
      TgQueue("🔌 CONNECTION RESTORED\nAccount state checked: positions, orders and last deal verified.\nStatus: "+RunStatus());
     }
   else if(!c && g_connected)
     {
      g_connected=false;
      YLog("Connection Lost");
      RaiseAlert("CONN","Connection Lost: no new orders will be sent until it is restored.",true,true);
     }
  }

void MonitorSpread()
  {
   double sp=(double)SymbolInfoInteger(g_sym,SYMBOL_SPREAD);
   if(sp>(double)g_warn)
     {
      if(!g_spreadWarned)
        {
         g_spreadWarned=true;
         YLog("Spread Warning: "+DoubleToString(sp,0)+" pts");
         RaiseAlert("SPREAD","Spread Warning: "+DoubleToString(sp,0)+" pts > "+IntegerToString(g_warn)+" pts (trading NOT blocked).",true,true);
        }
     }
   else if(sp<=(double)g_warn*0.8) g_spreadWarned=false;
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void UI_Rect(const string n,const int x,const int y,const int w,const int h,const color bg,const color bd)
  {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,bd);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

void UI_Label(const string n,const int x,const int y,const string txt,const color c,const int fs)
  {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial");
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

void UI_Edit(const string n,const int x,const int y,const int w,const int h,const string txt)
  {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'40,46,58');
   ObjectSetInteger(0,n,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,C'90,100,120');
   ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,9);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

void UI_Button(const string n,const int x,const int y,const int w,const int h,const string txt,const color bg)
  {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_STATE,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
  }

void UI_ToggleSet(const string n,const bool on)
  {
   color bg=C'150,50,50';
   if(on) bg=C'30,130,60';
   ObjectSetString(0,n,OBJPROP_TEXT,on?"ON":"OFF");
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_STATE,false);
  }

void SettingRow(const string key,const int x,const int ry,const string label,const string val)
  {
   UI_Label(UI+"SL_"+key,x+12,ry+4,label,clrSilver,9);
   UI_Edit(UI+"S_"+key,x+190,ry,140,20,val);
  }

void ToggleRow(const string key,const int x,const int ry,const string label,const bool on)
  {
   UI_Label(UI+"SL_"+key,x+12,ry+4,label,clrSilver,9);
   UI_Button(UI+"BTN_"+key,x+190,ry,140,20,"",C'150,50,50');
   UI_ToggleSet(UI+"BTN_"+key,on);
  }

//--- page 1: every configurable value (the trading levels / risk are on page 0)
void CreateSettingsPage()
  {
   int x=10,y=25,w=350,rowH=26;
   int h=48+11*rowH+70;
   UI_Rect(UI+"BG",x,y,w,h,C'22,26,34',C'212,175,55');
   UI_Label(UI+"TITLE",x+12,y+6,"Yetimmm",clrGold,15);
   UI_Label(UI+"SUB",x+110,y+13,"Settings",C'150,160,175',8);
   int ry=y+40;
   SettingRow("TARGET",x,ry,"Recovery Target ($, next risk)",D2(g_target)); ry+=rowH;
   SettingRow("RR",x,ry,"Risk/Reward (1:x)",DoubleToString(g_rr,2)); ry+=rowH;
   SettingRow("SLD",x,ry,"SL = Upper-Lower ($, auto)",DoubleToString(SLDist(),g_digits));
   ObjectSetInteger(0,UI+"S_SLD",OBJPROP_READONLY,true);
   ObjectSetInteger(0,UI+"S_SLD",OBJPROP_BGCOLOR,C'30,34,44');
   ry+=rowH;
   SettingRow("MAXDEV",x,ry,"Max Slippage Check (pts, post-fill)",IntegerToString(g_maxDev)); ry+=rowH;
   SettingRow("WARN",x,ry,"Spread Alert (pts, alert only)",IntegerToString(g_warn)); ry+=rowH;
   SettingRow("MAGIC",x,ry,"Magic Number (locked)",IntegerToString(g_magic));
   ObjectSetInteger(0,UI+"S_MAGIC",OBJPROP_READONLY,true);
   ObjectSetInteger(0,UI+"S_MAGIC",OBJPROP_BGCOLOR,C'30,34,44');
   ry+=rowH;
   ToggleRow("TGEN",x,ry,"Telegram Enable",g_uiTgEn); ry+=rowH;
   SettingRow("TOKEN",x,ry,"Bot Token",StringLen(g_tgTok)>0?"(hidden)":""); ry+=rowH;
   SettingRow("AUTH",x,ry,"Authorized ID",g_tgAuth); ry+=rowH;
   ToggleRow("TGNOT",x,ry,"Notifications",g_uiTgNot); ry+=rowH;
   ToggleRow("TGCTL",x,ry,"Telegram Control",g_uiTgCtl); ry+=rowH+6;
   UI_Button(UI+"BTN_SAVE",x+10,ry,160,24,"SAVE SETTINGS",C'30,130,60');
   UI_Button(UI+"BTN_BACK",x+180,ry,160,24,"< BACK",C'60,70,95');
   ry+=30;
   UI_Label(UI+"INFO",x+12,ry,"Contract Size: "+DoubleToString(g_contract,2)+"  |  "+(g_netting?"NETTING":"HEDGING"),C'150,160,175',8);
  }

void CreatePanel()
  {
   if(!InpShowPanel || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   ObjectsDeleteAll(0,UI);
   if(g_page==1)
     {
      CreateSettingsPage();
      ChartRedraw(0);
      return;
     }
   int x=10,y=25,w=400;
   int rows=ArraySize(g_rowKeys);
   ArrayResize(g_uiTxt,rows);                        // value cache: UpdatePanel writes only the rows that changed
   ArrayResize(g_uiCol,rows);
   for(int c=0;c<rows;c++) { g_uiTxt[c]="~~~"; g_uiCol[c]=clrNONE; }
   int h=48+3*24+34+30+rows*15+12;
   UI_Rect(UI+"BG",x,y,w,h,C'22,26,34',C'212,175,55');
   UI_Label(UI+"TITLE",x+12,y+6,"Yetimmm",clrGold,15);
   UI_Label(UI+"SUB",x+110,y+13,"XAUUSD | Risk Sequence EA",C'150,160,175',8);
   int ry=y+40;
   UI_Label(UI+"L_BUY",x+12,ry+4,"Buy Stop Price",clrSilver,9);
   UI_Edit(UI+"ED_BUY",x+190,ry,140,20,g_edHave?g_edBuy:(g_buyLevel>0?PX(g_buyLevel):""));
   ry+=24;
   UI_Label(UI+"L_SELL",x+12,ry+4,"Sell Stop Price",clrSilver,9);
   UI_Edit(UI+"ED_SELL",x+190,ry,140,20,g_edHave?g_edSell:(g_sellLevel>0?PX(g_sellLevel):""));
   ry+=24;
   UI_Label(UI+"L_RISK",x+12,ry+4,"Initial Risk ($)",clrSilver,9);
   UI_Edit(UI+"ED_RISK",x+190,ry,140,20,g_edHave?g_edRisk:D2(g_initRisk));
   ry+=28;
   UI_Button(UI+"BTN_APPLY",x+10,ry,80,24,"APPLY",C'30,90,160');
   UI_Button(UI+"BTN_START",x+95,ry,80,24,"START",C'30,130,60');
   UI_Button(UI+"BTN_STOP",x+180,ry,80,24,"STOP",C'170,40,40');
   UI_Button(UI+"BTN_CANCEL",x+265,ry,75,24,"CANCEL",C'160,110,20');
   ry+=30;
   UI_Button(UI+"BTN_SET",x+10,ry,330,22,"SETTINGS  >",C'60,70,95');
   ry+=34;
   for(int i=0;i<rows;i++)
     {
      UI_Label(UI+"K"+IntegerToString(i),x+12,ry+i*15,g_rowKeys[i],C'150,160,175',8);
      UI_Label(UI+"V"+IntegerToString(i),x+170,ry+i*15,"-",clrWhite,8);
     }
  }

void UI_Val(const int i,const string txt,const color c=clrWhite)
  {
   if(i<0 || i>=ArraySize(g_uiTxt)) return;
   if(g_uiTxt[i]==txt && g_uiCol[i]==c) return;      // unchanged: no object call at all
   string n=UI+"V"+IntegerToString(i);
   if(ObjectFind(0,n)<0) return;
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   g_uiTxt[i]=txt;
   g_uiCol[i]=c;
   g_uiChanged=true;
  }

//--- incremental refresh: only rows whose text/colour changed are written, and the chart is redrawn only then
void UpdatePanel()
  {
   if(!InpShowPanel || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(ObjectFind(0,UI+"BG")<0) CreatePanel();
   if(g_page!=0) return;            // settings page has no live values
   g_uiChanged=false;
   color sc=clrLime;
   if(g_state==YT_STOPPED || g_state==YT_ERROR) sc=clrTomato;
   else if(g_state==YT_IDLE || g_state==YT_TP_RESET) sc=clrGold;
   UI_Val(0,RunStatus()+" ["+StateText()+"]",sc);
   UI_Val(1,g_sym);

   //--- BUY STOP / SELL STOP: Desired (what the bot wants) vs Actual (what the server holds) vs Status
   for(int k=0;k<2;k++)
     {
      bool b=(k==0);
      int base=b?2:5;
      double dl;
      bool want=SideDesired(b,dl);
      double pend=b?g_pendBuy:g_pendSell;
      string nxt=(g_fresh && pend>0.0)?"  (next: "+PX(pend)+")":"";
      UI_Val(base,(want?PX(dl):"-")+nxt);
      ulong oTk; double ap;
      bool have=SideActual(b,oTk,ap);
      string det="-";
      if(have && OrderSelect(oTk))
         det="SL "+PX(OrderGetDouble(ORDER_SL))+"  TP "+PX(OrderGetDouble(ORDER_TP))+"  Lot "+LotS(OrderGetDouble(ORDER_VOLUME_CURRENT));
      UI_Val(b?29:30,det);
      UI_Val(base+1,have?PX(ap)+"  #"+UL(oTk):"-",(have && want && PriceEq(ap,dl))?clrLime:clrWhite);
      int st=SideStatusShown(b);
      UI_Val(base+2,SyncText(st),SyncColor(st));
     }

   ulong tk,pid; bool buy; double vol,entry,sl,tp,pr;
   if(OwnPosInfo(tk,pid,buy,vol,entry,sl,tp,pr))
     {
      UI_Val(8,(buy?"BUY ":"SELL ")+LotS(vol)+" @ "+PX(entry)+"  P/L "+Money(pr),buy?clrLime:clrTomato);
      UI_Val(31,"SL "+PX(sl)+"  TP "+PX(tp)+"  #"+UL(tk));
     }
   else { UI_Val(8,"None",clrSilver); UI_Val(31,"-"); }
   ulong od[]; int no=OwnOrders(od);
   string os="";
   for(int i=0;i<no;i++)
      if(OrderSelect(od[i])) os+=(OrderGetInteger(ORDER_TYPE)==ORDER_TYPE_BUY_STOP?"BuyStop ":"SellStop ")+PX(OrderGetDouble(ORDER_PRICE_OPEN))+"  ";
   if(os=="") os=(StringLen(g_waitReason)>0)?g_waitReason:((StringLen(g_blockReason)>0)?g_blockReason:"None");
   UI_Val(9,os);
   string lm=g_uiMsg;
   if(StringLen(lm)>56) lm=StringSubstr(lm,0,56)+"..";
   UI_Val(10,(lm=="")?"-":lm,g_uiMsgCol);
   UI_Val(11,IntegerToString(g_seq));
   UI_Val(12,"$"+D2(g_curRisk));
   double lot,est; string err;
   bool ok=CurrentLotInfo(lot,est,err);
   string lotTxt=ok?LotS(lot)+"  (est. loss $"+D2(est)+")":"n/a: "+err;
   color lotCol=ok?clrWhite:clrTomato;
   if(ok)
     {
      //--- the panel lot must equal the volume of the REAL pending order
      ulong lotTk; double lotPx;
      if(SideActual(g_mode!=YM_SELL,lotTk,lotPx) && OrderSelect(lotTk))
        {
         double mv=OrderGetDouble(ORDER_VOLUME_CURRENT);
         double vst=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP);
         if(vst<=0.0) vst=0.01;
         lotTxt+="  MT5 "+LotS(mv);
         if(MathAbs(mv-lot)>vst/2.0) lotCol=clrTomato;
        }
     }
   UI_Val(13,lotTxt,lotCol);
   UI_Val(14,"$"+D2(g_accLoss));
   UI_Val(15,"$"+D2(NextRiskFor(g_accLoss+(ok?est:g_curRisk))));
   UI_Val(16,ok?"$"+D2(est*g_rr):"n/a");
   UI_Val(17,"1:"+DoubleToString(g_rr,0));
   UI_Val(18,g_connected?"ONLINE":"OFFLINE",g_connected?clrLime:clrTomato);
   double sp=(double)SymbolInfoInteger(g_sym,SYMBOL_SPREAD);
   UI_Val(19,DoubleToString(sp,0)+" pts",sp>(double)g_warn?clrTomato:clrWhite);
   UI_Val(20,g_tradeNo>0?"#"+TNo(g_tradeNo):"-");
   UI_Val(21,IntegerToString(g_st.total));
   UI_Val(22,IntegerToString(g_st.wins));
   UI_Val(23,IntegerToString(g_st.losses));
   UI_Val(24,Money(g_st.totProfit));
   UI_Val(25,Money(-g_st.totLoss));
   UI_Val(26,Money(g_st.net),g_st.net>=0?clrLime:clrTomato);
   UI_Val(27,D2(g_st.winRate)+"%");
   UI_Val(28,TgStateText(),g_tgOk?clrLime:clrSilver);
   if(g_uiChanged) ChartRedraw(0);
  }

//--- smart APPLY: Validate -> Compare Desired vs Actual -> NOTHING TO DO / MODIFY / CREATE / REMOVE -> verify
void PanelApply()
  {
   double b=ParseNum(ObjectGetString(0,UI+"ED_BUY",OBJPROP_TEXT));
   double s=ParseNum(ObjectGetString(0,UI+"ED_SELL",OBJPROP_TEXT));
   double r=ParseNum(ObjectGetString(0,UI+"ED_RISK",OBJPROP_TEXT));
   string err;
   if(ApplyLevels(b,s,r,"Panel",err))
     {
      g_edHave=false;
      if(g_applyNote=="NOTHING TO DO")
         PanelMsg("APPLY: NOTHING TO DO (already synced)",clrSilver);
      else if(g_applyNote=="QUEUED")
        {
         PanelMsg("APPLY: saved for NEXT sequence (active trade untouched)",clrGold);
         TgQueue(LevelsAcceptedText());
        }
      else
        {
         bool allGood=true;
         for(int k=0;k<2;k++)
           {
            bool sb=(k==0);
            double dl;
            if(!SideDesired(sb,dl)) continue;
            int sst=SideStatusShown(sb);
            if(sst==YS_FAILED || sst==YS_WAITING || sst==YS_MISSING || sst==YS_EXTERNAL) allGood=false;
           }
         PanelMsg("APPLY: "+SyncSummary(),allGood?clrWhite:clrTomato);
         TgQueue(LevelsAcceptedText()+"\nSync: "+SyncSummary());
        }
      YLog("Levels accepted from panel ("+(g_applyNote==""?"applied":g_applyNote)+") | "+SyncSummary());
     }
   else PanelMsg("APPLY REJECTED: "+err,clrTomato);
  }

//--- every id must be a non-zero integer (negative ids = groups/channels)
bool ValidIdList(const string src)
  {
   string s=src;
   StringReplace(s,";",",");
   StringReplace(s," ",",");
   string p[];
   int n=StringSplit(s,',',p);
   for(int i=0;i<n;i++)
     {
      string d=p[i];
      if(StringLen(d)==0) continue;
      int st=(StringGetCharacter(d,0)=='-')?1:0;
      if(StringLen(d)<=st) return false;
      for(int k=st;k<StringLen(d);k++)
        {
         ushort c=StringGetCharacter(d,k);
         if(c<'0' || c>'9') return false;
        }
      if(StringToInteger(d)==0) return false;
     }
   return true;
  }

//--- validate EVERYTHING first; apply all-or-nothing
void PanelSaveSettings()
  {
   double nt =ParseNum(ObjectGetString(0,UI+"S_TARGET",OBJPROP_TEXT));
   double rr =ParseNum(ObjectGetString(0,UI+"S_RR",OBJPROP_TEXT));
   double mdv=ParseNum(ObjectGetString(0,UI+"S_MAXDEV",OBJPROP_TEXT));
   double wnv=ParseNum(ObjectGetString(0,UI+"S_WARN",OBJPROP_TEXT));
   string tokTxt=ObjectGetString(0,UI+"S_TOKEN",OBJPROP_TEXT);
   string authTxt=ObjectGetString(0,UI+"S_AUTH",OBJPROP_TEXT);
   StringTrimLeft(tokTxt);  StringTrimRight(tokTxt);
   StringTrimLeft(authTxt); StringTrimRight(authTxt);

   string err="";
   double stopsLvl=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_STOPS_LEVEL)*g_point;
   if(!MathIsValidNumber(nt) || nt<0.0)                          err="Recovery Target must be zero or positive.";
   else if(!MathIsValidNumber(rr) || rr<=0.0)                    err="Risk/Reward must be greater than zero.";
   else if(!MathIsValidNumber(mdv) || mdv<0.0 || mdv>100000.0)   err="Max Slippage Check must be between 0 and 100000 points.";
   else if(!MathIsValidNumber(wnv) || wnv<0.0 || wnv>100000.0)   err="Spread Alert must be between 0 and 100000 points.";
   else if(!ValidIdList(authTxt))                                err="Authorized ID must be numeric (comma separated).";
   else if(g_uiTgEn && ((tokTxt=="" ) || StringLen(authTxt)==0)) err="Telegram Enable requires a Bot Token and an Authorized ID.";

   bool tradeChanged=(MathAbs(nt-g_target)>1e-9 || MathAbs(rr-g_rr)>1e-9);
   if(err=="" && tradeChanged)
     {
      ulong tk[];
      if(OwnPositions(tk)>0) err="Recovery Target / Risk-Reward cannot change while a Yetimmm position is open.";
     }
   if(err!="")
     {
      YLog("Settings NOT saved: "+err);
      Alert("Yetimmm: settings NOT saved - ",err);
      return;
     }

   string newTok=(tokTxt=="(hidden)")?g_tgTok:tokTxt;
   string oldTok=g_tgTok;
   bool wasActive=TgActive();

   g_target=nt; g_rr=rr;
   g_maxDev=(int)MathRound(mdv);
   g_warn=(int)MathRound(wnv);
   g_tgEn=g_uiTgEn; g_tgNot=g_uiTgNot; g_tgCtl=g_uiTgCtl;
   g_tgTok=newTok;
   g_tgAuth=authTxt;
   ParseIds();
   g_trade.SetDeviationInPoints(g_maxDev);

   if(tradeChanged)
     {
      g_curRisk=(g_accLoss>1e-9)?NextRiskFor(g_accLoss):g_initRisk;
      g_nextPlaceMs=0;
      ResetSyncBackoff();
     }
   //--- never execute commands that piled up while Telegram was off or the bot changed
   if((!wasActive && TgActive()) || oldTok!=g_tgTok)
     {
      GlobalVariableDel(GN("TGINIT"));
      g_tgOk=false;
     }
   CfgPutAll();
   CfgSaveFile();
   SaveState();
   g_dirty=true;
   YLog("Settings saved from panel | Target "+D2(g_target)+" | R:R 1:"+DoubleToString(g_rr,2)+" | SL (Upper-Lower) "+D2(SLDist())+" | MaxSlippage "+IntegerToString(g_maxDev)+" | SpreadAlert "+IntegerToString(g_warn)+
        " | Telegram "+(g_tgEn?"ON":"OFF")+" | Notify "+(g_tgNot?"ON":"OFF")+" | Control "+(g_tgCtl?"ON":"OFF"));
   if(tradeChanged)
     {
      SyncAll();                        // SL / RR / target change the REAL orders now, not on the next tick
      UpdatePanel();
      PanelMsg("SETTINGS: "+SyncSummary(),clrWhite);
     }
   Alert("Yetimmm: settings saved."+(tradeChanged?" "+SyncSummary():""));
   TgQueue("⚙️ SETTINGS UPDATED (panel)\n"+SettingsText());
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam,UI)!=0) return;
   if(sparam==UI+"BTN_APPLY")
     {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      PanelApply();
     }
   else if(sparam==UI+"BTN_START")
     {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      string r=DoStart("Panel");
      Alert("Yetimmm: ",r);
      TgQueue(r);
     }
   else if(sparam==UI+"BTN_STOP")
     {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      ulong tk[];
      bool go=true;
      if(OwnPositions(tk)>0 && !MQLInfoInteger(MQL_TESTER))
         go=(MessageBox("An open Yetimmm position exists.\nClose it, delete orders and STOP the bot?","Yetimmm STOP",MB_YESNO|MB_ICONWARNING)==IDYES);
      if(go)
        {
         bool done=ExecStop(1,0);
         string r=StopResultText(done);
         Alert("Yetimmm: ",r);
         TgQueue(r);
        }
     }
   else if(sparam==UI+"BTN_CANCEL")
     {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      ulong tk[];
      bool closeToo=false;
      if(OwnPositions(tk)>0 && !MQLInfoInteger(MQL_TESTER))
         closeToo=(MessageBox("An open Yetimmm position exists.\nYES = cancel orders AND close the position.\nNO = cancel orders only.","Yetimmm CANCEL",MB_YESNO|MB_ICONWARNING)==IDYES);
      string r=ExecCancel(closeToo);
      Alert("Yetimmm: ",r);
      TgQueue(r);
     }
   else if(sparam==UI+"BTN_SET")
     {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      g_edBuy=ObjectGetString(0,UI+"ED_BUY",OBJPROP_TEXT);      // keep unsaved level edits
      g_edSell=ObjectGetString(0,UI+"ED_SELL",OBJPROP_TEXT);
      g_edRisk=ObjectGetString(0,UI+"ED_RISK",OBJPROP_TEXT);
      g_edHave=true;
      g_uiTgEn=g_tgEn; g_uiTgNot=g_tgNot; g_uiTgCtl=g_tgCtl;
      g_page=1;
      CreatePanel();
     }
   else if(sparam==UI+"BTN_BACK")
     {
      g_page=0;
      CreatePanel();
     }
   else if(sparam==UI+"BTN_SAVE")
     {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      PanelSaveSettings();
     }
   else if(sparam==UI+"BTN_TGEN")   { g_uiTgEn=!g_uiTgEn;   UI_ToggleSet(sparam,g_uiTgEn); }
   else if(sparam==UI+"BTN_TGNOT")  { g_uiTgNot=!g_uiTgNot; UI_ToggleSet(sparam,g_uiTgNot); }
   else if(sparam==UI+"BTN_TGCTL")  { g_uiTgCtl=!g_uiTgCtl; UI_ToggleSet(sparam,g_uiTgCtl); }
   g_dirty=true;
   UpdatePanel();
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Expert events                                                    |
//+------------------------------------------------------------------+
//--- log the symbol specification that drives the lot calculation (Contract Size included)
void LogSpecs()
  {
   YLog("Specs | Contract Size "+DoubleToString(g_contract,2)+" | Tick Size "+DoubleToString(g_tick,g_digits)+" | Tick Value "+DoubleToString(SymbolInfoDouble(g_sym,SYMBOL_TRADE_TICK_VALUE),4)+
        " | Volume Min "+DoubleToString(SymbolInfoDouble(g_sym,SYMBOL_VOLUME_MIN),g_lotDigits)+" Max "+DoubleToString(SymbolInfoDouble(g_sym,SYMBOL_VOLUME_MAX),g_lotDigits)+
        " Step "+DoubleToString(SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP),g_lotDigits)+" | Digits "+IntegerToString(g_digits));
   if(g_contract<=0.0)
      RaiseAlert("CSIZE0","Broker reports Contract Size = 0 for "+g_sym+": loss per lot relies on OrderCalcProfit / Tick Value only.",true,false);
   double px=SymbolInfoDouble(g_sym,SYMBOL_BID);
   if(px>0.0) PerLotLossSL(true,px,px-1.0);   // triggers the Contract Size cross-check once at start-up (1.00 test distance)
  }

//+------------------------------------------------------------------+
//| Magic Number guard                                               |
//| Positions/orders are identified by Symbol + Magic. If the Magic  |
//| was changed while Yetimmm orders/positions of the OLD Magic still|
//| exist, the new instance would never manage them: they would stay |
//| alive on the server. Detect -> strong warning -> do not start.   |
//+------------------------------------------------------------------+
string MagicKey() { return "YTX_"+g_sym+"_LASTMAGIC"; }

bool IsYetimmmComment(const string c) { return (StringFind(c,"Yetimmm")>=0); }

//--- counts Yetimmm-tagged pending orders / positions on this symbol that belong to ANOTHER magic
int CountOrphans(string &detail)
  {
   int cnt=0;
   detail="";
   int no=OrdersTotal();
   for(int i=0;i<no;i++)
     {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_sym) continue;
      long mg=(long)OrderGetInteger(ORDER_MAGIC);
      if(mg==g_magic) continue;
      if(!IsYetimmmComment(OrderGetString(ORDER_COMMENT))) continue;
      cnt++;
      if(StringLen(detail)<180) detail+=" order#"+UL(t)+"(magic "+IntegerToString((int)mg)+")";
     }
   int np=PositionsTotal();
   for(int i=0;i<np;i++)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_sym) continue;
      long mg=(long)PositionGetInteger(POSITION_MAGIC);
      if(mg==g_magic) continue;
      if(!IsYetimmmComment(PositionGetString(POSITION_COMMENT))) continue;
      cnt++;
      if(StringLen(detail)<180) detail+=" position#"+UL(t)+"(magic "+IntegerToString((int)mg)+")";
     }
   return cnt;
  }

//--- returns false when the start must be refused
bool MagicGuardOk()
  {
   string key=MagicKey();
   bool changed=(GlobalVariableCheck(key) && (long)GlobalVariableGet(key)!=g_magic);
   string det="";
   int orph=CountOrphans(det);
   if(orph>0 && changed && !InpIgnoreOrphans)
     {
      string m="MAGIC NUMBER CHANGED ("+IntegerToString((int)(long)GlobalVariableGet(key))+" -> "+IntegerToString((int)g_magic)+") while "+IntegerToString(orph)+
               " Yetimmm order(s)/position(s) of another Magic still exist on "+g_sym+":"+det+
               ". They are NOT managed by this instance. Close/delete them or restore the old Magic, then re-attach (or set InpIgnoreOrphans=true).";
      YLog("INIT REFUSED: "+m);
      Alert("Yetimmm refused to start: ",m);
      return false;
     }
   if(orph>0 && !changed)
      YLog("WARNING: "+IntegerToString(orph)+" Yetimmm-tagged order(s)/position(s) of another Magic on "+g_sym+":"+det+" (not managed by this instance).");
   if(orph>0 && InpIgnoreOrphans)
      YLog("Magic guard bypassed by InpIgnoreOrphans.");
   GlobalVariableSet(key,(double)g_magic);
   return true;
  }

//+------------------------------------------------------------------+
//| Mini App bridge (Cloudflare Worker)                              |
//| One WebRequest per cycle: push state + ack done commands +       |
//| receive pending commands. Commands reuse the SAME functions as   |
//| the Telegram commands (DoStart / ExecStop / ApplyLevels ...).    |
//+------------------------------------------------------------------+
datetime g_brLast=0;
datetime g_brErrLog=0;
bool     g_brOk=false;
bool     g_brFirst=true;          // first successful sync: queued commands are discarded, never executed
string   g_brAck[];
string   g_brDone[];
int      g_brHistTotal=-1;
string   g_brHistJson="[]";
string   g_brLastId="";
string   g_brLastText="";
bool     g_brLastOk=true;

string JEsc(const string s)
  {
   string r=s;
   StringReplace(r,"\\","\\\\");
   StringReplace(r,"\"","\\\"");
   StringReplace(r,"\r"," ");
   StringReplace(r,"\n"," | ");
   StringReplace(r,"\t"," ");
   return r;
  }

bool JDbl(const string seg,const string key,double &v)
  {
   v=0.0;
   string mk="\""+key+"\":";
   int a=StringFind(seg,mk);
   if(a<0) return false;
   int i=a+StringLen(mk);
   int L=StringLen(seg);
   string s="";
   while(i<L)
     {
      ushort c=StringGetCharacter(seg,i);
      if((c>='0' && c<='9') || c=='.' || c=='-' || c=='+' || c=='e' || c=='E') { s+=ShortToString(c); i++; }
      else break;
     }
   if(s=="") return false;
   v=StringToDouble(s);
   return true;
  }

bool BrSeen(const string id)
  {
   for(int i=0;i<ArraySize(g_brDone);i++) if(g_brDone[i]==id) return true;
   return false;
  }

void BrRemember(const string id)
  {
   int n=ArraySize(g_brDone);
   if(n>=40)
     {
      for(int i=1;i<n;i++) g_brDone[i-1]=g_brDone[i];
      n--;
     }
   ArrayResize(g_brDone,n+1);
   g_brDone[n]=id;
  }

void BrAckAdd(const string id)
  {
   int n=ArraySize(g_brAck);
   ArrayResize(g_brAck,n+1);
   g_brAck[n]=id;
  }

//--- last closed trades (newest first), rebuilt only when the trade count changes
string BrHistJson()
  {
   if(g_st.total==g_brHistTotal) return g_brHistJson;
   string lines[];
   int n=ReadTradeLines(lines);
   string out="[";
   int cnt=0;
   for(int i=n-1;i>=0 && cnt<20;i--)
     {
      string f[];
      if(StringSplit(lines[i],';',f)<30) continue;
      string tm=f[22];
      int sp=StringFind(tm," ");
      if(sp>=0) tm=StringSubstr(tm,sp+1);
      if(cnt>0) out+=",";
      out+="{\"no\":"+IntegerToString(StringToInteger(f[0]))+",\"side\":\""+JEsc(f[5])+"\",\"entry\":"+DoubleToString(StringToDouble(f[7]),g_digits)+
           ",\"exit\":"+DoubleToString(StringToDouble(f[8]),g_digits)+",\"lot\":"+DoubleToString(StringToDouble(f[11]),2)+
           ",\"pnl\":"+DoubleToString(StringToDouble(f[18]),2)+",\"reason\":\""+JEsc(f[23])+"\",\"t\":\""+JEsc(tm)+"\"}";
      cnt++;
     }
   out+="]";
   g_brHistJson=out;
   g_brHistTotal=g_st.total;
   return out;
  }

string BrStateJson()
  {
   string s="{";
   s+="\"price\":"+DoubleToString(SymbolInfoDouble(g_sym,SYMBOL_BID),g_digits);
   s+=",\"run\":"+(g_state==YT_STOPPED?"false":"true");
   s+=",\"state\":\""+StateText()+"\"";
   string msg=g_blockReason;
   if(StringLen(msg)==0) msg=g_waitReason;
   s+=",\"msg\":\""+JEsc(msg)+"\"";
   s+=",\"buy\":"+DoubleToString(g_buyLevel,g_digits)+",\"sell\":"+DoubleToString(g_sellLevel,g_digits);
   s+=",\"risk\":"+D2(g_initRisk)+",\"cur\":"+D2(g_curRisk)+",\"acc\":"+D2(g_accLoss);
   s+=",\"seq\":"+IntegerToString(g_seq)+",\"no\":"+IntegerToString(g_tradeNo);
   s+=",\"target\":"+D2(g_target)+",\"rr\":"+DoubleToString(g_rr,2);
   s+=",\"maxDev\":"+IntegerToString(g_maxDev)+",\"warn\":"+IntegerToString(g_warn);
   s+=",\"breach\":\""+(InpBreachPolicy==BREACH_MARKET?"MARKET":"WAIT")+"\"";
   s+=",\"spread\":"+IntegerToString((int)SymbolInfoInteger(g_sym,SYMBOL_SPREAD));
   if(g_fresh && g_pendBuy>0.0 && g_pendSell>0.0)
      s+=",\"pend\":{\"buy\":"+DoubleToString(g_pendBuy,g_digits)+",\"sell\":"+DoubleToString(g_pendSell,g_digits)+",\"risk\":"+D2(g_initRisk)+",\"target\":"+D2(g_target)+",\"rr\":"+DoubleToString(g_rr,2)+"}";
   else s+=",\"pend\":null";
   ulong tk,pid; bool buy; double vol,entry,sl,tp,pr;
   if(OwnPosInfo(tk,pid,buy,vol,entry,sl,tp,pr))
      s+=",\"pos\":{\"side\":\""+(buy?"BUY":"SELL")+"\",\"entry\":"+DoubleToString(entry,g_digits)+",\"sl\":"+DoubleToString(sl,g_digits)+",\"tp\":"+DoubleToString(tp,g_digits)+
         ",\"lot\":"+DoubleToString(vol,2)+",\"est\":"+D2(vol*MathAbs(entry-sl)*g_contract)+",\"risk\":"+D2(PGV(pid,"R",g_curRisk))+
         ",\"no\":"+IntegerToString((long)PGV(pid,"N",0))+",\"profit\":"+D2(pr)+"}";
   else s+=",\"pos\":null";
   s+=",\"hist\":"+BrHistJson();
   s+=",\"stats\":{\"total\":"+IntegerToString((int)g_st.total)+",\"wins\":"+IntegerToString((int)g_st.wins)+",\"losses\":"+IntegerToString((int)g_st.losses)+",\"net\":"+D2(g_st.net)+"}";
   if(StringLen(g_brLastId)>0)
      s+=",\"lastCmd\":{\"id\":\""+JEsc(g_brLastId)+"\",\"ok\":"+(g_brLastOk?"true":"false")+",\"text\":\""+JEsc(g_brLastText)+"\"}";
   s+="}";
   return s;
  }

//--- executes ONE command through the existing Telegram-command functions
string BrExec(const string cmd,const string seg)
  {
   ulong tk[];
   if(cmd=="start") return DoStart("MiniApp");
   if(cmd=="stop")
     {
      bool d=ExecStop(2,0);
      return StopResultText(d);
     }
   if(cmd=="close")
     {
      if(OwnPositions(tk)==0) return "ℹ️ No open Yetimmm position.";
      bool p=CleanupPositions(3);
      CheckClosures();
      g_dirty=true;
      return p?"✅ Open position closed.":"❌ Could not close the open position.";
     }
   if(cmd=="reset")
     {
      if(OwnPositions(tk)>0) return "❌ Cannot reset the risk sequence while a position is open.";
      ResetRisk();
      g_nextPlaceMs=0;
      ResetSyncBackoff();
      SaveState();
      SyncAll();
      g_dirty=true;
      return "✅ Risk sequence reset.";
     }
   if(cmd=="apply" || cmd=="settings")
     {
      double b,s,r,tg,rr;
      bool hb=JDbl(seg,"buy",b), hs=JDbl(seg,"sell",s), hr=JDbl(seg,"risk",r), ht=JDbl(seg,"target",tg), hrr=JDbl(seg,"rr",rr);
      if(cmd=="apply" && (!hb || !hs)) return "❌ Invalid command: buy/sell missing.";
      double nt=ht?tg:g_target, nrr=hrr?rr:g_rr;
      if(!MathIsValidNumber(nt) || nt<0.0)   return "❌ Recovery Target must be zero or positive.";
      if(!MathIsValidNumber(nrr) || nrr<=0.0) return "❌ Risk/Reward must be greater than zero.";
      bool tradeChanged=(MathAbs(nt-g_target)>1e-9 || MathAbs(nrr-g_rr)>1e-9);
      if(tradeChanged && OwnPositions(tk)>0) return "❌ Recovery Target / Risk-Reward cannot change while a Yetimmm position is open.";
      double oldT=g_target, oldR=g_rr;
      g_target=nt; g_rr=nrr;
      string err="";
      string res="";
      if(hb && hs)
        {
         if(!ApplyLevels(b,s,(hr?r:0.0),"MiniApp",err))
           {
            g_target=oldT; g_rr=oldR;
            return "❌ Invalid Price Configuration: "+err;
           }
         res=LevelsAcceptedText();
        }
      else res="✅ Settings updated.";
      if(tradeChanged)
        {
         g_curRisk=(g_accLoss>1e-9)?NextRiskFor(g_accLoss):g_initRisk;
         g_nextPlaceMs=0;
         ResetSyncBackoff();
         CfgPutAll();
         CfgSaveFile();
         SaveState();
         SyncAll();
        }
      g_dirty=true;
      return res;
     }
   return "❌ Unknown command: "+cmd;
  }

void BridgeSync()
  {
   if(!InpBrEnable || MQLInfoInteger(MQL_TESTER)) return;
   if(StringLen(InpBrUrl)<12 || StringLen(InpBrKey)<8) return;
   if(TimeLocal()-g_brLast<MathMax(1,InpBrPollSec)) return;
   g_brLast=TimeLocal();

   string body="{\"state\":"+BrStateJson()+",\"ack\":[";
   for(int i=0;i<ArraySize(g_brAck);i++) body+=(i>0?",":"")+"\""+g_brAck[i]+"\"";
   body+="]}";
   string url=InpBrUrl;
   while(StringLen(url)>0 && StringSubstr(url,StringLen(url)-1,1)=="/") url=StringSubstr(url,0,StringLen(url)-1);
   url+="/api/ea/sync";

   char data[],res[];
   string rh;
   int n=StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8);
   if(n>0) ArrayResize(data,n-1);
   ResetLastError();
   int code=WebRequest("POST",url,"Content-Type: application/json\r\nX-Bridge-Key: "+InpBrKey+"\r\n",3000,data,res,rh);
   if(code==-1)
     {
      int e=GetLastError();
      g_brOk=false;
      if(TimeLocal()-g_brErrLog>=60)
        {
         g_brErrLog=TimeLocal();
         if(e==4014) YLog("Mini App bridge: add the Worker URL to Tools > Options > Expert Advisors > Allowed URLs (error 4014).");
         else YLog("Mini App bridge: WebRequest failed, error "+IntegerToString(e));
        }
      return;
     }
   string resp=CharArrayToString(res,0,WHOLE_ARRAY,CP_UTF8);
   if(code!=200 || StringFind(resp,"\"ok\":true")<0)
     {
      g_brOk=false;
      if(TimeLocal()-g_brErrLog>=60)
        {
         g_brErrLog=TimeLocal();
         YLog("Mini App bridge: HTTP "+IntegerToString(code)+" (check Bridge Key / Worker URL)");
        }
      return;
     }
   if(!g_brOk) YLog("Mini App bridge: connected.");
   g_brOk=true;
   ArrayResize(g_brAck,0);              // the acks in this request were delivered

   int cpos=StringFind(resp,"\"commands\":");
   if(cpos<0) { g_brFirst=false; return; }
   string sub=StringSubstr(resp,cpos);
   string marker="\"id\":\"";
   int mlen=StringLen(marker);
   int p=0;
   int discarded=0;
   while(true)
     {
      int a=StringFind(sub,marker,p);
      if(a<0) break;
      int b=StringFind(sub,marker,a+mlen);
      string seg=(b<0)?StringSubstr(sub,a):StringSubstr(sub,a,b-a);
      p=a+mlen;
      string id=JStr(seg,marker);
      string cmd=JStr(seg,"\"cmd\":\"");
      StringToLower(cmd);
      if(StringLen(id)==0) continue;
      if(g_brFirst || BrSeen(id))
        {
         if(g_brFirst) discarded++;
         BrAckAdd(id);                  // never execute twice / never execute what piled up while the EA was off
         continue;
        }
      BrRemember(id);
      YLog("Mini App Command Received: "+cmd);
      string result=BrExec(cmd,seg);
      YLog("Mini App Command Result: "+result);
      g_brLastId=id;
      g_brLastOk=(StringFind(result,"❌")<0);
      string one=result;
      StringReplace(one,"\n"," | ");
      g_brLastText=(StringLen(one)>160)?StringSubstr(one,0,160):one;
      BrAckAdd(id);
      TgQueue("📱 Mini App → "+cmd+"\n"+result);
      g_brLast=0;                       // sync again on the next timer tick: ack + fresh state
     }
   if(g_brFirst && discarded>0) YLog("Mini App bridge: "+IntegerToString(discarded)+" queued command(s) discarded on startup (not executed).");
   g_brFirst=false;
  }

int OnInit()
  {
   g_sym=_Symbol;
   g_magic=InpMagic;
   string up=g_sym;
   StringToUpper(up);
   if(StringFind(up,"XAUUSD")<0)
     {
      Alert("Yetimmm works on XAUUSD only. Current symbol: ",g_sym);
      return INIT_FAILED;
     }
   if(InpRiskReward<=0.0 || InpTargetProfit<0.0 || InpInitialRisk<=0.0 || InpMaxDeviation<0 || InpWarnSpread<0 || InpProtectCloseSec<0)
     {
      Alert("Yetimmm: invalid inputs (Initial Risk and Risk/Reward must be > 0; Target, Deviation and Spread must be >= 0).");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!MagicGuardOk()) return INIT_FAILED;
   SymbolSelect(g_sym,true);
   g_digits=(int)SymbolInfoInteger(g_sym,SYMBOL_DIGITS);
   g_point=SymbolInfoDouble(g_sym,SYMBOL_POINT);
   g_tick=SymbolInfoDouble(g_sym,SYMBOL_TRADE_TICK_SIZE);
   if(g_tick<=0.0) g_tick=g_point;
   double st=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP);
   g_lotDigits=0;
   while(g_lotDigits<8 && MathAbs(st*MathPow(10,g_lotDigits)-MathRound(st*MathPow(10,g_lotDigits)))>1e-9) g_lotDigits++;

   g_contract=SymbolInfoDouble(g_sym,SYMBOL_TRADE_CONTRACT_SIZE);
   CfgInit();                          // runtime configuration: inputs + values saved from the panel
   g_uiTgEn=g_tgEn; g_uiTgNot=g_tgNot; g_uiTgCtl=g_tgCtl;

   g_trade.SetExpertMagicNumber((ulong)g_magic);
   g_trade.SetDeviationInPoints(g_maxDev);
   g_trade.SetTypeFillingBySymbol(g_sym);
   g_trade.SetAsyncMode(false);
   MathSrand((int)GetTickCount());

   YLog("EA Started | "+g_sym+" | magic "+IntegerToString(g_magic));
   g_netting=IsNettingAccount();
   if(g_netting)
     {
      //--- Netting merges every deal on the symbol into one position: refuse to run next to a foreign position
      double ev=ExternalPositionVolume();
      if(ev>0.0)
        {
         Alert("Yetimmm refused to start: Netting account and an external ",g_sym," position exists (",LotS(ev)," lots). Close it first, then re-attach the EA.");
         YLog("INIT REFUSED: Netting account + external "+g_sym+" position ("+LotS(ev)+" lots).");
         return INIT_FAILED;
        }
      YLog("Netting account detected: the bot stays frozen (no orders, no closing) whenever a foreign "+g_sym+" position exists.");
     }

   LoadState();
   TrkLoad();                          // real tickets + last server-verified snapshot survive a restart
   g_tgLast=(long)GV("TGLAST",0);
   LoadTradeLog();
   ParseIds();
   LogSpecs();
   if(g_tgEn)
     {
      if(MQLInfoInteger(MQL_TESTER)) YLog("Telegram disabled in the Strategy Tester.");
      else if(StringLen(g_tgTok)==0 || ArraySize(g_tgIds)==0) YLog("Telegram Connection Error: Bot Token or Authorized ID missing - Telegram inactive.");
     }
   g_connected=(bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   if(g_stateRecovered) YLog("State Recovered: "+StateText()+" | Risk "+D2(g_curRisk)+" | Acc.Loss "+D2(g_accLoss)+" | Seq "+IntegerToString(g_seq)+" | Last Trade #"+TNo(g_tradeNo));

   //--- input levels: applied only when new (or changed) so old inputs never re-arm the bot after TP
   bool haveIn=(InpBuyStop>0.0 && InpSellStop>0.0);
   bool changedLv=(!GHas("INBL") || MathAbs(GV("INBL",0)-InpBuyStop)>1e-9 || MathAbs(GV("INSL",0)-InpSellStop)>1e-9);
   bool changedRk=(!GHas("INRK") || MathAbs(GV("INRK",0)-InpInitialRisk)>1e-9);
   GS("INBL",InpBuyStop); GS("INSL",InpSellStop); GS("INRK",InpInitialRisk);
   if(changedRk && !changedLv)
     {
      g_initRisk=InpInitialRisk;
      if(g_accLoss<=1e-9) g_curRisk=g_initRisk;
     }
   RecoverHistory();
   if(haveIn && changedLv)
     {
      string err;
      ApplyLevels(InpBuyStop,InpSellStop,InpInitialRisk,"Inputs",err);
     }
   else if(!g_stateRecovered)
     {
      g_initRisk=InpInitialRisk; g_curRisk=InpInitialRisk;
     }
   SaveState();
   ChartSetInteger(0,CHART_SHOW_TRADE_LEVELS,true);   // real pending-order / SL / TP levels are drawn by MT5 itself
   CreatePanel();
   EventSetTimer(1);
   SyncAll();
   UpdatePanel();
   TgQueue("✅ Yetimmm Started\nStatus: "+RunStatus()+"\nState: "+StateText()+"\nBuy Stop: "+PX(g_buyLevel)+"\nSell Stop: "+PX(g_sellLevel)+"\nRisk: $"+D2(g_curRisk)+
           (g_stateRecovered?"\n♻️ State Recovered | Last Trade #"+TNo(g_tradeNo):""),0,MenuMarkup());
   g_inited=true;
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_inited)
     {
      SaveState();
      TgFlush();
     }
   ObjectsDeleteAll(0,UI);
   YLog("EA stopped (reason "+IntegerToString(reason)+"). State saved.");
  }

void OnTick()
  {
   ulong now=GetTickCount64();
   if(g_dirty || now-g_lastSyncMs>=300)
     {
      g_dirty=false;
      SyncAll();
     }
  }

void OnTrade()
  {
   g_dirty=true;
   UpdatePanel();          // show the real server state immediately (incremental, cheap)
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol!=g_sym) return;
   if(HistoryDealSelect(trans.deal))
     {
      if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_IN && (long)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)==g_magic)
        {
         ulong pid=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
         RegisterPosition(pid);
        }
     }
   g_dirty=true;
   SyncAll();
  }

int g_timerCount=0;
void OnTimer()
  {
   g_timerCount++;
   MonitorConnection();
   SyncAll();
   StopCleanupTick();
   if(g_timerCount%30==0 && g_connected) RecoverHistory();
   MonitorSpread();
   TgPoll();
   BridgeSync();
   TgFlush();
   UpdatePanel();
  }
//+------------------------------------------------------------------+
