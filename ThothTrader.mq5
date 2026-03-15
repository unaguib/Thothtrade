//+------------------------------------------------------------------+

//|                                         ThothTrader.mq5      |

//|         Liquidation + Breakeven + Risk Guard + Custom Panel      |

//+------------------------------------------------------------------+



//+------------------------------------------------------------------+

//  LICENSE VALIDATION ENGINE  v2  —  Online + Offline dual-layer

//

//  Layer 1 (offline): local key derived from account+broker fingerprint

//  Layer 2 (online) : server validates against live license database

//                     Server-side HMAC secret never touches this binary.

//  The EA caches the server token in a GlobalVariable for 23 hours

//  so trading is unaffected by short network outages.

//+------------------------------------------------------------------+



// ── UPDATE THIS to your deployed server URL ──────────────────────────

#define LIC_SERVER_URL "https://thothtrade-license.thothtrader.workers.dev"  // update after CF deploy



// ═══════════════════════════════════════════════════════════════════════════

//  AUTO-UPDATE ENGINE

//  Checks Cloudflare for a newer version on every startup.

//  If found: downloads .ex5 to MQL5/Files/, writes a self-applying batch,

//  launches the batch, and asks the user to close MT5.

//  The batch waits for MT5 to exit, copies the file, then restarts MT5.

// ═══════════════════════════════════════════════════════════════════════════



#import "shell32.dll"

int ShellExecuteW(int hwnd, string lpOperation, string lpFile,

                  string lpParameters, string lpDirectory, int nShowCmd);

#import



// ── bump this string on every new release ────────────────────────────────

#define TT_VERSION "1.0.1"

#define TT_EA_ID   "ThothTrader"

// ─────────────────────────────────────────────────────────────────────────



void TT_CheckForUpdate()

  {

   char   post[], data[];

   string hdrs = "User-Agent: ThothTrader-EA/1.0\r\n";

   string respHdrs;

   int    timeout = 6000;



   // Step 1: ask server for latest version info

   string verUrl = LIC_SERVER_URL + "/version?ea=" + TT_EA_ID;

   int code = WebRequest("GET", verUrl, hdrs, timeout, post, data, respHdrs);

   if(code != 200) return;



   string body = CharArrayToString(data);



   // Parse {"version":"1.0.1","url":"https://..."}

   string newVer = "", dlUrl = "";



   int vs = StringFind(body, "\"version\":\"");

   if(vs >= 0) { vs += 11; int ve = StringFind(body, "\"", vs); if(ve > vs) newVer = StringSubstr(body, vs, ve - vs); }



   int us = StringFind(body, "\"url\":\"");

   if(us >= 0) { us += 7; int ue = StringFind(body, "\"", us); if(ue > us) dlUrl = StringSubstr(body, us, ue - us); }



   if(StringLen(newVer) == 0 || StringLen(dlUrl) == 0) return;

   if(newVer <= TT_VERSION) return;



   Print("ThothTrader: update available — current=", TT_VERSION, "  new=", newVer);



   // Step 2: download the new .ex5

   char   dlPost[], exData[];

   string dlHdrs = "User-Agent: ThothTrader-EA/1.0\r\n";

   string dlRespHdrs;

   int dlCode = WebRequest("GET", dlUrl, dlHdrs, timeout, dlPost, exData, dlRespHdrs);

   if(dlCode != 200 || ArraySize(exData) < 1000) { Print("ThothTrader: download failed code=", dlCode); return; }



   // Step 3: write new .ex5 to MQL5/Files/

   string exName = TT_EA_ID + ".ex5";

   int fh = FileOpen(exName, FILE_WRITE | FILE_BIN);

   if(fh == INVALID_HANDLE) { Print("ThothTrader: cannot write update file"); return; }

   FileWriteArray(fh, exData, 0, ArraySize(exData));

   FileClose(fh);



   // Step 4: write self-applying batch to MQL5/Files/

   string filesDir   = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\";

   string expertsDir = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Experts\\";

   string termExe    = TerminalInfoString(TERMINAL_PATH)      + "\\terminal64.exe";

   string exPath     = filesDir + exName;

   string batName    = "TT_ApplyUpdate.bat";



   string bat = "@echo off\r\n"

              + ":wait\r\n"

              + "tasklist | find /i \"terminal64.exe\" >nul 2>&1\r\n"

              + "if not errorlevel 1 (timeout /t 2 /nobreak >nul & goto wait)\r\n"

              + "copy /Y \"" + exPath + "\" \"" + expertsDir + exName + "\"\r\n"

              + "if exist \"" + termExe + "\" start \"MT5\" \"" + termExe + "\"\r\n";



   int bh = FileOpen(batName, FILE_WRITE | FILE_ANSI | FILE_TXT);

   if(bh == INVALID_HANDLE) { Print("ThothTrader: cannot write batch"); return; }

   FileWriteString(bh, bat);

   FileClose(bh);



   // Step 5: launch batch — it runs independently and waits for MT5 to close

   ShellExecuteW(0, "open", filesDir + batName, "", filesDir, 0);



   // Step 6: tell the user

   MessageBox("ThothTrader v" + newVer + " is ready!\n\n"

            + "Close MetaTrader 5 now.\n"

            + "The update will apply automatically and MT5 will reopen.",

              "ThothTrader — Update Ready", MB_ICONINFORMATION | MB_OK);

  }

// ═══════════════════════════════════════════════════════════════════════════



// ─────────────────────────────────────────────────────────────────────



#define _LIC_S0       0xDEADC0FEB4BEF00D

#define _LIC_S1       0x1337C0DECAFE1234

#define _LIC_S2       0xABCDEF0123456789

#define _LIC_S3       0xF0E1D2C3B4A59687

#define _LIC_ROUNDS   7

#define LIC_CHARSET   "0123456789ABCDEFGHJKLMNPQRSTUVWX"

// Cache valid for 23 hours (seconds)

#define LIC_CACHE_SEC 82800



ulong _LicMix(ulong a, ulong b)

  {

   a ^= b;

   a  = (a << 17) | (a >> 47);

   a  = a * (ulong)0x6C62272E07BB0142;

   return a;

  }



ulong _BrokerHash(string s)

  {

   ulong h = (ulong)0xCBF29CE484222325;

   int   n = StringLen(s);

   for(int i = 0; i < n; i++)

     {

      h ^= (ulong)(StringGetCharacter(s, i) & 0xFF);

      h *= (ulong)0x100000001B3;

     }

   return h;

  }



ulong _LicFingerprint(long account, string broker)

  {

   string bn = broker; StringToUpper(bn);

   ulong bh  = _BrokerHash(bn);

   ulong b0  = bh;

   ulong b1  = _LicMix(bh, bh >> 13);

   ulong fp  = _LicMix(_LicMix((ulong)account ^ _LIC_S0, b0 ^ _LIC_S1), b1 ^ _LIC_S2);

   fp ^= _LIC_S3;

   for(int i = 0; i < _LIC_ROUNDS; i++)

      fp = _LicMix(fp, (fp >> (i * 7 + 3)) ^ ((ulong)account << (i * 5 + 1)));

   return fp;

  }



string _LicEncode(ulong val)

  {

   string cs = LIC_CHARSET, raw = "";

   for(int i = 0; i < 13; i++)

     {

      raw += ShortToString((ushort)StringGetCharacter(cs, (int)(val & 0x1F)));

      val >>= 5;

     }

   return StringSubstr(raw,0,4)+"-"+StringSubstr(raw,4,4)+"-"+StringSubstr(raw,8,5);

  }



// ── LAYER 1: offline local key check ─────────────────────────────────

bool _LicLocalCheck(string userKey)

  {

   string k = userKey; StringTrimLeft(k); StringTrimRight(k); StringToUpper(k);

   if(StringLen(k) == 0) return false;

   long   acct = AccountInfoInteger(ACCOUNT_LOGIN);

   string svr  = AccountInfoString(ACCOUNT_SERVER);

   return (k == _LicEncode(_LicFingerprint(acct, svr)));

  }



// ── LAYER 2: online server validation ────────────────────────────────

// Returns:  1 = server says VALID

//           0 = server reachable but INVALID/EXPIRED/REVOKED

//          -1 = server unreachable (network error / timeout)

int _LicOnlineCheck(string userKey)

  {

   long   acct   = AccountInfoInteger(ACCOUNT_LOGIN);

   string broker = AccountInfoString(ACCOUNT_SERVER);

   string k      = userKey; StringTrimLeft(k); StringTrimRight(k); StringToUpper(k);



   string url = LIC_SERVER_URL + "/validate"

              + "?account=" + IntegerToString(acct)

              + "&broker="  + broker

              + "&key="     + k;



   char   post[], result[];

   string headers = "";

   int    timeout = 5000; // 5 seconds



   int httpCode = WebRequest("GET", url, headers, timeout, post, result, headers);



   if(httpCode == -1) return -1;  // network error



   string body = CharArrayToString(result);

   if(StringFind(body, "TT_OK:") == 0)

     {

      // Token format: PL_OK:<account>:<date>:<sig>

      // Verify the account embedded in the token matches ours

      string parts[];

      if(StringSplit(body, ':', parts) >= 3)

         if(StringToInteger(parts[1]) == acct)

            return 1;

      return 0;

     }

   return 0; // UNLICENSED / EXPIRED / REVOKED / unexpected response

  }



// ── COMBINED: offline + online with 23h cache ────────────────────────

bool _LicValidate(string userKey)

  {

   long   acct   = AccountInfoInteger(ACCOUNT_LOGIN);

   string broker = AccountInfoString(ACCOUNT_SERVER);



   // Step 1 — local key must pass first (instant, no network)

   if(!_LicLocalCheck(userKey))

      return false;



   // Step 2 — check 23h cache stored in GlobalVariable

   string cacheVar = "TT_LicCache_" + IntegerToString(acct);

   string tsVar    = "TT_LicTime_"  + IntegerToString(acct);



   if(GlobalVariableCheck(cacheVar) && GlobalVariableCheck(tsVar))

     {

      datetime cachedAt = (datetime)GlobalVariableGet(tsVar);

      if((TimeCurrent() - cachedAt) < LIC_CACHE_SEC)

        {

         if(GlobalVariableGet(cacheVar) > 0)

            return true;  // cached VALID — skip server call

         // cached INVALID — still fail (don't retry until cache expires)

         return false;

        }

     }



   // Step 3 — call server

   int result = _LicOnlineCheck(userKey);



   if(result == -1)

     {

      // Server unreachable — if cache exists (even expired) give grace period

      if(GlobalVariableCheck(cacheVar) && GlobalVariableGet(cacheVar) > 0)

        {

         Print("PL License: server unreachable, using cached approval (grace mode)");

         return true;

        }

      // No cache at all — block (first-time use requires internet)

      return false;

     }



   // Cache the result

   GlobalVariableSet(cacheVar, result == 1 ? 1.0 : 0.0);

   GlobalVariableSet(tsVar,    (double)TimeCurrent());



   return (result == 1);

  }

//+------------------------------------------------------------------+

#property copyright   "ThothTrader"

#property version     "1.00"

#property description "Liquidation + Risk Guard + Full Trade Panel — ThothTrader"



sinput string LicenseKey = "";  // Your license key (format XXXX-XXXX-XXXXX)

input int    LineWidth            = 1;

input int    FontSize             = 7;

input bool   ShowLiquidation      = true;

input color  LiqColor             = clrRed;

input double StopOutLevelOverride = 0.0;

input bool   ShowBreakeven        = true;

input color  BEColor              = clrYellow;

input double MinLiqDistanceATR    = 10.0;   // Liquidation must be >= this many ATRs away

input color  WarningColor         = clrOrangeRed;

input double DefaultLotSize       = 0.1;

input color  PanelBgColor         = C'58,66,74';

input color  BuyBtnColor          = C'0,140,0';

input color  SellBtnColor         = C'180,0,0';

input color  DisabledBtnColor     = C'80,80,80';

input double AtrMultiplier        = 2.5;   // ATR multiplier for stop loss

input int    AtrPeriod            = 14;    // ATR period



#define LIQ_LINE    "TT_LiqLine_"

#define RISK_LINE   "TT_RiskLine_"

#define CTX_SET_SL    "TT_CtxSetSL"

#define CTX_SET_TP    "TT_CtxSetTP"

#define CTX_ALERT     "TT_CtxAlert"

#define CTX_ORDER_BUY "TT_CtxOrderBuy"

#define CTX_ORDER_SEL "TT_CtxOrderSel"

#define CTX_ORDER_BSTP "TT_CtxOrderBStp"

#define CTX_ORDER_SSTP "TT_CtxOrderSStp"

#define CTX_TXT_BUY   "TT_CtxTxtBuy"

#define CTX_TXT_SEL   "TT_CtxTxtSel"

#define CTX_LINE      "TT_CtxLine"

#define CTX_BG        "TT_CtxBG"

#define CTX_HEADER    "TT_CtxHeader"

#define CTX_SEP1      "TT_CtxSep1"

#define CTX_SEP2      "TT_CtxSep2"

#define CTX_ALERT_LINE "TT_AlertLine"

#define CTX_ALERT_LBL  "TT_AlertLbl"

#define RISK_LABEL  "TT_RiskLabel_"

#define LIQ_LABEL   "TT_LiqLabel_"

#define BE_LINE     "TT_BELine_"

#define BE_LABEL    "TT_BELabel_"

#define BE_LOCKED   "TT_BELocked_"

#define WARN_PRE    "TT_Warn_"

#define INFO_PRE    "TT_Info_"

#define PNL_LABEL   "TT_PnlLabel_"

#define SL_LABEL    "TT_SlLabel_"

#define TP_LABEL    "TT_TpLabel_"



#define P_BG        "TT_Panel_BG"

#define P_TITLE     "TT_Panel_Title"

#define P_LOTS_LBL  "TT_Panel_LotsLbl"

#define P_LOTS_EDIT "TT_Panel_LotsEdit"

#define P_LOTS_UP   "TT_Panel_LotsUp"

#define P_LOTS_DN   "TT_Panel_LotsDn"

#define P_BUY_BTN   "TT_Panel_BuyBtn"

#define P_SELL_BTN  "TT_Panel_SellBtn"

#define P_RISK_LBL  "TT_Panel_RiskLbl"

#define P_STATUS    "TT_Panel_Status"

#define P_ATR_LBL   "TT_Panel_AtrLbl"

#define P_FLAT_BTN  "TT_Panel_FlatBtn"

#define P_ZBUY_BTN  "TT_Panel_ZoneBuyBtn"

#define P_ZSELL_BTN "TT_Panel_ZoneSellBtn"

#define P_ZONE_LBL  "TT_Panel_ZoneLbl"

#define P_ZONE_UP   "TT_Panel_ZoneUp"

#define P_ZONE_DN      "TT_Panel_ZoneDn"

#define P_HEDGE_LBL "TT_Panel_HedgeLbl"

#define P_HDG_1     "TT_Panel_Hedge1"

#define P_HDG_2     "TT_Panel_Hedge2"

#define P_HDG_3     "TT_Panel_Hedge3"

#define P_HDG_4     "TT_Panel_Hedge4"

#define P_CLOSE_LBL "TT_Panel_CloseLbl"

#define P_CLS_1     "TT_Panel_Close1"

#define P_CLS_2     "TT_Panel_Close2"

#define P_CLS_3     "TT_Panel_Close3"

#define P_CLS_4     "TT_Panel_Close4"

#define P_REC_LBL   "TT_Panel_RecLbl"

#define P_USE_REC   "TT_Panel_UseRec"

#define P_HIST_BTN  "TT_Panel_HistBtn"

#define P_TRAIL_BTN "TT_Panel_TrailBtn"

#define P_CHDG_BTN  "TT_Panel_CloseProfit"

#define P_REV_BTN   "TT_Panel_RevBtn"

#define P_ADD_LBL   "TT_Panel_AddLbl"

#define P_ADD_1     "TT_Panel_Add1"

#define P_ADD_2     "TT_Panel_Add2"

#define P_ADD_3     "TT_Panel_Add3"

#define P_ADD_4     "TT_Panel_Add4"



// Panel geometry — bottom-left

#define PAN_X    20

#define PAN_Y    30

#define PAN_W    230

#define PAN_H    440



double g_LotSize = 0.1;

bool   g_Blocked        = false;

bool   g_FlattenArmed   = false;  // true after first press cancelled orders

bool   g_UseRecLot     = false;  // when true, BUY/SELL use recommended lot size

int    g_PendingShift  = 0;       // deferred shift: +1 up, -1 down, 0 none

double g_HedgeSessionPnL  = 0;   // cumulative realized PnL from closed legs since first hedge

bool   g_HedgeSessionActive = false;  // true once a hedge has been placed this session

bool   g_SLRemovedForFullHedge = false; // true when SLs have been stripped due to full hedge

bool   g_HadPositions = false;          // tracks position state to trigger explicit line cleanup



// ═══════════════════════════════════════════════════════════════════════════

//  CONTEXT & RR VISUALIZATION STATE (v2 - TradingView Style)

// ═══════════════════════════════════════════════════════════════════════════

bool g_CtxMenuOpen  = false;  // true when right-click context menu is visible

double g_CtxPrice   = 0;      // price captured at right-click

int g_CtxMouseX     = 0;      // pixel X at click

int g_CtxMouseY     = 0;      // pixel Y at click

bool g_WasRightDown = false;  



// RR visualization state

bool   g_RRActive      = false;     // true while RR preview is showing

double g_RR_EntryPrice = 0;         // Live interactive Entry line

double g_RR_SLPrice    = 0;         // Live interactive SL line

double g_RR_TPPrice    = 0;         // Live interactive TP line

ENUM_ORDER_TYPE g_RRType = ORDER_TYPE_BUY_LIMIT; 

datetime g_HedgeSessionStart = 0;



double g_AlertSetupPrice = 0;

int    g_AlertSide       = 0;





int    g_AtrHandle    = INVALID_HANDLE;

int    g_M30AtrHandle = INVALID_HANDLE;  // M30 ATR — minimum TF for SL/TP/rec sizing



// ═══════════════════════════════════════════════════════════════════

//  SMART TRAILING STOP

// ═══════════════════════════════════════════════════════════════════

bool   g_TrailActive   = false;

double g_TrailStop     = 0;        // current trail level (0 = not set)

string g_TrailRegime   = "NONE";   // TRENDING / RANGING / VOLATILE

double g_TrailPeak     = 0;        // highest close (long) or lowest close (short) seen



input int    TrailAdxPeriod     = 14;     // ADX period (Daily) — used for regime detection

input double TrailAdxTrend      = 25.0;  // ADX >= this = TRENDING

input double TrailAdxRange      = 20.0;  // ADX <= this = RANGING



int g_AdxHandle   = INVALID_HANDLE;

int g_D1AtrHandle = INVALID_HANDLE;

int g_D1AtrAvgHdl = INVALID_HANDLE;   // used via manual buffer below



//+------------------------------------------------------------------+

void TrailInit()

  {

   g_AdxHandle   = iADX(_Symbol, PERIOD_D1, TrailAdxPeriod);

   g_D1AtrHandle = iATR(_Symbol, PERIOD_D1, 14);

   if(g_AdxHandle == INVALID_HANDLE || g_D1AtrHandle == INVALID_HANDLE)

      Print("SmartTrail: indicator handle creation failed");

  }



void TrailDeinit()

  {

   if(g_AdxHandle   != INVALID_HANDLE) IndicatorRelease(g_AdxHandle);

   if(g_D1AtrHandle != INVALID_HANDLE) IndicatorRelease(g_D1AtrHandle);

   DeleteTrailLine();

  }



//--- Detect D1 regime: TRENDING / RANGING / VOLATILE

string DetectRegime()

  {

   double adxBuf[]; ArraySetAsSeries(adxBuf, true);

   if(CopyBuffer(g_AdxHandle, 0, 1, 3, adxBuf) < 1) return "UNKNOWN";



   double atrD1Buf[]; ArraySetAsSeries(atrD1Buf, true);

   if(CopyBuffer(g_D1AtrHandle, 0, 1, 22, atrD1Buf) < 22) return "UNKNOWN";



   double adx     = adxBuf[0];

   double atrNow  = atrD1Buf[0];

   double atrAvg  = 0;

   for(int i = 1; i <= 20; i++) atrAvg += atrD1Buf[i];

   atrAvg /= 20.0;



   // Volatility expansion check

   if(atrAvg > 0 && (atrNow / atrAvg) > 1.5) return "VOLATILE";

   if(adx >= TrailAdxTrend)                   return "TRENDING";

   if(adx <= TrailAdxRange)                   return "RANGING";

   return "NEUTRAL";   // between 20–25: trail but don't tighten

  }



//--- Chandelier Exit calculation on current timeframe

// Trail = Price ± (ATR × AtrMultiplier)

// Ratchet applied in UpdateTrailStop — this just returns the raw candidate level.

// In VOLATILE regime: widen by 50% to avoid premature stop-out on spikes.

double CalcAtrTrailStop(bool isLong)

  {

   double atr = GetCurrentATR();

   if(atr <= 0) return 0;



   string regime = DetectRegime();

   double mult   = (regime == "VOLATILE") ? AtrMultiplier * 1.5 : AtrMultiplier;



   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);



   double stop = isLong

                 ? NormalizeDouble(bid - atr * mult, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS))

                 : NormalizeDouble(ask + atr * mult, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));



   return stop;

  }



//--- Apply trail stop to all positions on symbol

void UpdateTrailStop()

  {

   if(!g_TrailActive) return;



   string sym    = _Symbol;

   string regime = DetectRegime();

   g_TrailRegime = regime;



   // In ranging regime: freeze (don't move stop, don't apply tighter)

   if(regime == "RANGING")

     {

      UpdateTrailLine(g_TrailStop, regime);

      return;

     }



   double buyVol = 0, sellVol = 0;

   for(int i = 0; i < PositionsTotal(); i++)

     {

      if(PositionGetSymbol(i) != sym) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(pt == POSITION_TYPE_BUY) buyVol  += PositionGetDouble(POSITION_VOLUME);

      else                        sellVol += PositionGetDouble(POSITION_VOLUME);

     }



   if(buyVol < 0.00001 && sellVol < 0.00001)

     {

      g_TrailActive = false;

      g_TrailStop   = 0;

      DeleteTrailLine();

      UpdateTrailButton();

      return;

     }



   bool isLong = (buyVol >= sellVol);

   double newStop = CalcAtrTrailStop(isLong);

   if(newStop <= 0) return;



   // Ratchet: stop only moves in favorable direction

   bool updated = false;

   if(g_TrailStop == 0)

     {

      g_TrailStop = newStop;

      updated = true;

     }

   else if(isLong  && newStop > g_TrailStop) { g_TrailStop = newStop; updated = true; }

   else if(!isLong && newStop < g_TrailStop) { g_TrailStop = newStop; updated = true; }



   if(updated)

     {

      // Apply to all positions

      for(int i = PositionsTotal() - 1; i >= 0; i--)

        {

         if(PositionGetSymbol(i) != sym) continue;

         ulong  ticket = PositionGetInteger(POSITION_TICKET);

         double tp     = PositionGetDouble(POSITION_TP);



         MqlTradeRequest req = {};

         MqlTradeResult  res = {};

         req.action   = TRADE_ACTION_SLTP;

         req.symbol   = sym;

         req.position = ticket;

         req.sl       = g_TrailStop;

         req.tp       = tp;

         if(!OrderSend(req, res)) Print("OrderSend failed: ", res.retcode);

        }

     }



   UpdateTrailLine(g_TrailStop, regime);

   UpdateTrailButton();

  }



//--- Trail line on chart

void DeleteTrailLine()

  {

   ObjectDelete(0, "TT_TrailLine");

   ObjectDelete(0, "TT_TrailLabel");

  }



void UpdateTrailLine(double price, string regime)

  {

   if(price <= 0) { DeleteTrailLine(); return; }

   color clr = (regime == "RANGING")   ? clrGray

             : (regime == "VOLATILE")  ? clrOrange

             :                           clrAqua;



   // ── Line: create once, update in-place ──────────────────────────

   if(ObjectFind(0, "TT_TrailLine") < 0)

     {

      ObjectCreate(0, "TT_TrailLine", OBJ_HLINE, 0, 0, price);

      ObjectSetInteger(0, "TT_TrailLine", OBJPROP_STYLE,      STYLE_DASHDOT);

      ObjectSetInteger(0, "TT_TrailLine", OBJPROP_WIDTH,      1);

      ObjectSetInteger(0, "TT_TrailLine", OBJPROP_SELECTABLE, false);

      ObjectSetInteger(0, "TT_TrailLine", OBJPROP_HIDDEN,     true);

     }

   ObjectSetDouble (0, "TT_TrailLine", OBJPROP_PRICE,  price);

   ObjectSetInteger(0, "TT_TrailLine", OBJPROP_COLOR,  clr);

   ObjectSetString (0, "TT_TrailLine", OBJPROP_TOOLTIP,

                    "SmartTrail | Regime: " + regime +

                    " | Stop: " + DoubleToString(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));



   // ── Label: create once, update in-place ─────────────────────────

   datetime labelTime = (datetime)(TimeCurrent() + PeriodSeconds() * 8);

   if(ObjectFind(0, "TT_TrailLabel") < 0)

     {

      ObjectCreate(0, "TT_TrailLabel", OBJ_TEXT, 0, labelTime, price);

      ObjectSetInteger(0, "TT_TrailLabel", OBJPROP_FONTSIZE,   8);

      ObjectSetString (0, "TT_TrailLabel", OBJPROP_FONT,       "Arial Bold");

      ObjectSetInteger(0, "TT_TrailLabel", OBJPROP_SELECTABLE, false);

      ObjectSetInteger(0, "TT_TrailLabel", OBJPROP_HIDDEN,     true);

     }

   ObjectSetDouble (0, "TT_TrailLabel", OBJPROP_PRICE, price);

   ObjectSetString (0, "TT_TrailLabel", OBJPROP_TEXT,  "TRAIL [" + regime + "]");

   ObjectSetInteger(0, "TT_TrailLabel", OBJPROP_COLOR, clr);

   ChartRedraw(0);

  }



void UpdateTrailButton()

  {

   if(ObjectFind(0, "TT_Panel_TrailBtn") < 0) return;

   if(g_TrailActive)

     {

      ObjectSetString (0, "TT_Panel_TrailBtn", OBJPROP_TEXT,    "SMART TRAIL  ON");

      ObjectSetInteger(0, "TT_Panel_TrailBtn", OBJPROP_BGCOLOR, C'0,80,80');

     }

   else

     {

      ObjectSetString (0, "TT_Panel_TrailBtn", OBJPROP_TEXT,    "SMART TRAIL  OFF");

      ObjectSetInteger(0, "TT_Panel_TrailBtn", OBJPROP_BGCOLOR, C'40,40,40');

     }

  }



//+------------------------------------------------------------------+



//+------------------------------------------------------------------+

//  TRADE HISTORY MARKS

//+------------------------------------------------------------------+

bool g_HistoryOn = false;



void DrawHistoryMarks()

  {

   DeleteHistoryMarks();

   string sym = _Symbol;

   datetime from = iTime(sym, PERIOD_CURRENT,

                         iBars(sym, PERIOD_CURRENT) - 1); // full chart history

   if(!HistorySelect(from, TimeCurrent())) return;



   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)

     {

      ulong  ticket = HistoryDealGetTicket(i);

      if(ticket == 0) continue;

      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != sym) continue;



      ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);

      if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) continue;



      datetime t     = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

      double   price = HistoryDealGetDouble(ticket, DEAL_PRICE);

      bool     isBuy = (dtype == DEAL_TYPE_BUY);



      string name = "TT_Hist_" + IntegerToString(ticket);



      // Green circle for buys, red circle for sells

      ObjectCreate(0, name, OBJ_ARROW, 0, t, price);

      ObjectSetInteger(0, name, OBJPROP_ARROWCODE,  159); // •

      ObjectSetInteger(0, name, OBJPROP_COLOR,      isBuy ? C'80,220,80' : C'220,80,80');

      ObjectSetInteger(0, name, OBJPROP_WIDTH,      2);

      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);

     }

   ChartRedraw(0);

  }



void DeleteHistoryMarks()

  {

   int total = ObjectsTotal(0);

   for(int i = total - 1; i >= 0; i--)

     {

      string name = ObjectName(0, i);

      if(StringFind(name, "TT_Hist_") == 0)

         ObjectDelete(0, name);

     }

  }



int OnInit()

  {

   // ── LICENSE CHECK (offline key + online server) ───────────────────

   {

      long   acct = AccountInfoInteger(ACCOUNT_LOGIN);

      string svr  = AccountInfoString(ACCOUNT_SERVER);

      if(!_LicValidate(LicenseKey))

        {

         MessageBox("ThothTrader — License invalid, expired, or revoked.\n\n"

                    "Account : " + IntegerToString(acct) + "\n"

                    "Server  : " + svr + "\n\n"

                    "Contact the developer with your account number\n"

                    "and server name to obtain or renew your license.",

                    "License Error", MB_ICONERROR | MB_OK);

         return INIT_FAILED;

        }

   }

   // ───────────────────────────────────────────────────────────────────

   TT_CheckForUpdate();  // auto-update: checks server, downloads if newer version exists

   g_LotSize  = DefaultLotSize;

   g_AtrHandle = iATR(_Symbol, PERIOD_CURRENT, AtrPeriod);

   if(g_AtrHandle == INVALID_HANDLE)

     {

      Print("Failed to create ATR indicator handle");

      return INIT_FAILED;

     }

   // Always create M30 handle; used when chart TF is smaller than M30

   g_M30AtrHandle = iATR(_Symbol, PERIOD_M30, AtrPeriod);

   if(g_M30AtrHandle == INVALID_HANDLE)

      Print("Warning: failed to create M30 ATR handle");

   TrailInit();

   EventSetTimer(2);

   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, 1);

   BuildPanel();

   UpdateAll();

   return INIT_SUCCEEDED;

  }



void OnDeinit(const int reason)

  {

   EventKillTimer();

   if(g_AtrHandle    != INVALID_HANDLE) IndicatorRelease(g_AtrHandle);

   if(g_M30AtrHandle != INVALID_HANDLE) IndicatorRelease(g_M30AtrHandle);

   TrailDeinit();

   DeleteHistoryMarks();

   if(reason == REASON_REMOVE)

     {

      ObjectDelete(0, CTX_ALERT_LINE);

      ObjectDelete(0, CTX_ALERT_LBL);

     }

   DeleteAll();

  }



void OnTick()

  {

   if(g_PendingShift != 0)

     {

      int dir = g_PendingShift;

      g_PendingShift = 0;

      ShiftZoneOrders(dir);

     }

   UpdateAll();

  }

void OnTimer()

  {

   if(g_PendingShift != 0)

     {

      int dir = g_PendingShift;

      g_PendingShift = 0;

      ShiftZoneOrders(dir);

     }

   UpdateAll();

  }



//+------------------------------------------------------------------+

double GetCurrentATR()

  {

   double atrBuf[];

   ArraySetAsSeries(atrBuf, true);

   // Use M30 ATR as minimum — if chart is on a smaller TF, use M30 instead

   int handle = (Period() < PERIOD_M30 && g_M30AtrHandle != INVALID_HANDLE)

                ? g_M30AtrHandle

                : g_AtrHandle;

   if(CopyBuffer(handle, 0, 0, 3, atrBuf) < 1) return 0;

   return atrBuf[1]; // use last closed bar

  }



double GetM30ATR()

  {

   // Always returns M30 ATR — used for liq distance checks so threshold is

   // consistent regardless of what timeframe the chart is displayed on

   int handle = (g_M30AtrHandle != INVALID_HANDLE) ? g_M30AtrHandle : g_AtrHandle;

   double atrBuf[];

   ArraySetAsSeries(atrBuf, true);

   if(CopyBuffer(handle, 0, 0, 3, atrBuf) < 1) return 0;

   return atrBuf[1];

  }



double GetVPP(string sym)

  {

   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);

   if(ts <= 0) return 0;

   return tv / ts;

  }



void SetStatus(string msg, color clr)

  {

   if(ObjectFind(0, P_STATUS) >= 0)

     {

      ObjectSetString (0, P_STATUS, OBJPROP_TEXT,  msg);

      ObjectSetInteger(0, P_STATUS, OBJPROP_COLOR, clr);

      ChartRedraw(0);

     }

  }



//+------------------------------------------------------------------+



//+------------------------------------------------------------------+

void OnTradeTransaction(const MqlTradeTransaction &trans,

                        const MqlTradeRequest     &request,

                        const MqlTradeResult      &result)

  {

   // Track realized PnL for deals closed on our symbol during a hedge session

   if(!g_HedgeSessionActive) return;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   if(trans.symbol != _Symbol) return;



   // Only count closing deals (DEAL_ENTRY_OUT or DEAL_ENTRY_INOUT)

   if(!HistoryDealSelect(trans.deal)) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;



   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)

                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)

                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_HedgeSessionPnL += profit;

   UpdateAll();

  }





void HideContextMenu()

  {

   ObjectDelete(0, CTX_SET_SL);

   ObjectDelete(0, CTX_SET_TP);

   ObjectDelete(0, CTX_ALERT);

   ObjectDelete(0, CTX_ORDER_BUY);

   ObjectDelete(0, CTX_ORDER_SEL);

   ObjectDelete(0, CTX_ORDER_BSTP);

   ObjectDelete(0, CTX_ORDER_SSTP);

   ObjectDelete(0, CTX_TXT_BUY);

   ObjectDelete(0, CTX_TXT_SEL);

   ObjectDelete(0, CTX_LINE);

   ObjectDelete(0, CTX_BG);

   ObjectDelete(0, CTX_HEADER);

   ObjectDelete(0, CTX_SEP1);

   ObjectDelete(0, CTX_SEP2);

   g_CtxMenuOpen = false;

  }



// Context Menu — dark floating card, offset from native MT5 right-click menu

void ShowContextMenu(double price)

  {

   HideContextMenu();



   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   int    rowH   = 28;   // taller rows for easier clicking

   int    menuW  = 195;  // width of the menu card

   int    padX   = 8;    // text padding inside card



   // Shift further from cursor so it never overlaps native MT5 context menu

   // Native menu is typically ~150px wide, so offset by 180px right

   int startX = g_CtxMouseX + 180;

   int startY = g_CtxMouseY - 30;



   // Clamp to screen edges

   int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);

   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

   if(startX + menuW > chartW - 10) startX = g_CtxMouseX - menuW - 10;

   if(startY < 5) startY = 5;

   int totalH = rowH * 6 + 12;  // header + 5 rows + padding

   if(startY + totalH > chartH - 5) startY = chartH - totalH - 5;



   // ── DARK BACKGROUND CARD ────────────────────────────────────────

   ObjectCreate(0, CTX_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, CTX_BG, OBJPROP_CORNER,      CORNER_LEFT_UPPER);

   ObjectSetInteger(0, CTX_BG, OBJPROP_XDISTANCE,   startX - 4);

   ObjectSetInteger(0, CTX_BG, OBJPROP_YDISTANCE,   startY - 4);

   ObjectSetInteger(0, CTX_BG, OBJPROP_XSIZE,       menuW + 8);

   ObjectSetInteger(0, CTX_BG, OBJPROP_YSIZE,       totalH + 8);

   ObjectSetInteger(0, CTX_BG, OBJPROP_BGCOLOR,     C'22,26,35');

   ObjectSetInteger(0, CTX_BG, OBJPROP_BORDER_TYPE, BORDER_FLAT);

   ObjectSetInteger(0, CTX_BG, OBJPROP_COLOR,       C'55,65,80');

   ObjectSetInteger(0, CTX_BG, OBJPROP_WIDTH,       1);

   ObjectSetInteger(0, CTX_BG, OBJPROP_SELECTABLE,  false);

   ObjectSetInteger(0, CTX_BG, OBJPROP_BACK,        true);



   // ── PRICE HEADER ────────────────────────────────────────────────

   ObjectCreate(0, CTX_HEADER, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, CTX_HEADER, OBJPROP_CORNER,    CORNER_LEFT_UPPER);

   ObjectSetInteger(0, CTX_HEADER, OBJPROP_XDISTANCE, startX + padX);

   ObjectSetInteger(0, CTX_HEADER, OBJPROP_YDISTANCE, startY + 2);

   ObjectSetString (0, CTX_HEADER, OBJPROP_TEXT,      "@ " + DoubleToString(price, digits));

   ObjectSetInteger(0, CTX_HEADER, OBJPROP_COLOR,     C'130,160,200');

   ObjectSetInteger(0, CTX_HEADER, OBJPROP_FONTSIZE,  9);

   ObjectSetString (0, CTX_HEADER, OBJPROP_FONT,      "Arial");

   ObjectSetInteger(0, CTX_HEADER, OBJPROP_SELECTABLE, false);



   // Center reference line (dotted)

   ObjectCreate(0, CTX_LINE, OBJ_HLINE, 0, 0, price);

   ObjectSetInteger(0, CTX_LINE, OBJPROP_COLOR,      C'80,90,110');

   ObjectSetInteger(0, CTX_LINE, OBJPROP_STYLE,      STYLE_DOT);

   ObjectSetInteger(0, CTX_LINE, OBJPROP_SELECTABLE, false);



   // ── MENU ITEMS — logically grouped ──────────────────────────────

   int baseRow = startY + rowH;  // first item row (below header)



   string bId[9]   = {CTX_ALERT, 

                      CTX_SET_TP, CTX_SET_SL,

                      CTX_TXT_BUY, CTX_ORDER_BUY, CTX_ORDER_BSTP, 

                      CTX_TXT_SEL, CTX_ORDER_SEL, CTX_ORDER_SSTP};

   string bTxt[9]  = {" \x23F0  Set MT5 Alert",

                      " \x25A0  Set TP for All",  

                      " \x26D4  Set SL for All",

                      " \x25B2 Buy", "  Limit  ", "  Stop  ",

                      " \x25BC Sell", "  Limit  ", "  Stop  "};

   color  bBg[9]   = {C'30,45,65', 

                      C'28,55,40', C'55,30,30', 

                      C'22,26,35', C'30,60,40', C'30,60,40', 

                      C'22,26,35', C'65,30,28', C'65,30,28'};

   color  bFg[9]   = {C'100,180,255',

                      C'100,230,130', C'255,100,100',

                      C'100,230,120', C'100,230,120', C'100,230,120', 

                      C'230,110,100', C'230,110,100', C'230,110,100'};

   int    bX[9]    = {startX + padX, 

                      startX + padX, startX + padX,

                      startX + padX, startX + padX + 55, startX + padX + 105,

                      startX + padX, startX + padX + 55, startX + padX + 105};

   

   int rowOffsets[9] = {0, 1, 2, 3, 3, 3, 4, 4, 4}; // which logic row they belong to

   int sepOffsets[9] = {0, 4, 4, 8, 8, 8, 8, 8, 8}; // additional Y padding before this row



   for(int i = 0; i < 9; i++)

     {

      int yOff = baseRow + (rowOffsets[i] * rowH) + sepOffsets[i];

      ObjectCreate(0, bId[i], OBJ_LABEL, 0, 0, 0);

      ObjectSetInteger(0, bId[i], OBJPROP_CORNER,    CORNER_LEFT_UPPER);

      ObjectSetInteger(0, bId[i], OBJPROP_XDISTANCE, bX[i]);

      ObjectSetInteger(0, bId[i], OBJPROP_YDISTANCE, yOff);

      ObjectSetString (0, bId[i], OBJPROP_TEXT,      bTxt[i]);

      ObjectSetInteger(0, bId[i], OBJPROP_COLOR,     bFg[i]);

      ObjectSetInteger(0, bId[i], OBJPROP_BGCOLOR,   bBg[i]);

      ObjectSetInteger(0, bId[i], OBJPROP_FONTSIZE,  10);

      ObjectSetString (0, bId[i], OBJPROP_FONT,      "Arial Bold");

      ObjectSetInteger(0, bId[i], OBJPROP_SELECTABLE, (i != 3 && i != 6)); // Make labels non-selectable 

     }



   // ── SEPARATOR LINES ─────────────────────────────────────────────

   // Separator between Alert and Modifiers

   int sep1Y = baseRow + (1 * rowH) + 1;

   ObjectCreate(0, CTX_SEP1, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_CORNER,      CORNER_LEFT_UPPER);

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_XDISTANCE,   startX + padX);

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_YDISTANCE,   sep1Y);

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_XSIZE,       menuW - padX * 2);

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_YSIZE,       1);

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_BGCOLOR,     C'55,65,80');

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_BORDER_TYPE, BORDER_FLAT);

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_COLOR,       C'55,65,80');

   ObjectSetInteger(0, CTX_SEP1, OBJPROP_SELECTABLE,  false);



   // Separator between Modifiers and Orders

   int sep2Y = baseRow + (3 * rowH) + 5;

   ObjectCreate(0, CTX_SEP2, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_CORNER,      CORNER_LEFT_UPPER);

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_XDISTANCE,   startX + padX);

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_YDISTANCE,   sep2Y);

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_XSIZE,       menuW - padX * 2);

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_YSIZE,       1);

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_BGCOLOR,     C'55,65,80');

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_BORDER_TYPE, BORDER_FLAT);

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_COLOR,       C'55,65,80');

   ObjectSetInteger(0, CTX_SEP2, OBJPROP_SELECTABLE,  false);



   g_CtxMenuOpen = true;

   g_CtxPrice    = price;

   ChartRedraw(0);

  }



void SetAllSLAtPrice(double price)

  {

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   price = NormalizeDouble(price, digits);

   int modified  = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      ulong  ticket = PositionGetInteger(POSITION_TICKET);

      double tp     = PositionGetDouble(POSITION_TP);

      MqlTradeRequest req = {}; MqlTradeResult res = {};

      req.action = TRADE_ACTION_SLTP; req.symbol = sym;

      req.position = ticket; req.sl = price; req.tp = tp;

      if(OrderSend(req, res)) modified++;

     }

   SetStatus("SL → " + DoubleToString(price, digits) +

             " on " + IntegerToString(modified) + " positions", clrTomato);

  }



void SetAllTPAtPrice(double price)

  {

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   price = NormalizeDouble(price, digits);

   int modified  = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      ulong  ticket = PositionGetInteger(POSITION_TICKET);

      double sl     = PositionGetDouble(POSITION_SL);

      MqlTradeRequest req = {}; MqlTradeResult res = {};

      req.action = TRADE_ACTION_SLTP; req.symbol = sym;

      req.position = ticket; req.sl = sl; req.tp = price;

      if(OrderSend(req, res)) modified++;

     }

   SetStatus("TP → " + DoubleToString(price, digits) +

             " on " + IntegerToString(modified) + " positions", clrLimeGreen);

  }



// ── PIXEL HELPER ────────────────────────────────────────────────────────────

int PriceToY(double price)

  {

   int    h    = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

   double pMin = ChartGetDouble(0, CHART_PRICE_MIN);

   double pMax = ChartGetDouble(0, CHART_PRICE_MAX);

   if(pMax <= pMin) return 0;

   return (int)((pMax - price) / (pMax - pMin) * h);

  }

// ─────────────────────────────────────────────────────────────────────────────



// ═══════════════════════════════════════════════════════════════════════════

//  NEW RR VISUALIZATION — TradingView Style (Interactive Drag-and-Drop)

// ═══════════════════════════════════════════════════════════════════════════



color g_OrigBgClr = clrNONE;

color g_OrigFgClr = clrNONE;

color g_OrigGridClr = clrNONE;



void HideRR()

  {

   ObjectDelete(0, "TT_RR_Entry");

   ObjectDelete(0, "TT_RR_SL");

   ObjectDelete(0, "TT_RR_TP");

   ObjectDelete(0, "TT_RR_Row1");

   ObjectDelete(0, "TT_RR_Row2");

   ObjectDelete(0, "TT_RR_Row3");

   ObjectDelete(0, "TT_RR_Confirm");

   ObjectDelete(0, "TT_RR_Cancel");

   ObjectDelete(0, "TT_PREV_SL_LBL");

   ObjectDelete(0, "TT_PREV_TP_LBL");

   ObjectDelete(0, "TT_RR_DIM_TOP");

   ObjectDelete(0, "TT_RR_DIM_BOT");

   g_RRActive = false;

   

   ChartRedraw(0);

  }



void UpdateRRPnl()

  {

   if(!g_RRActive) return;

   

   string sym = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);

   double vpp    = GetVPP(sym);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   string currency = AccountInfoString(ACCOUNT_CURRENCY);



   bool isBuy = (g_RR_SLPrice < g_RR_EntryPrice); 

   g_RRType   = isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;

   

   double slDist = MathAbs(g_RR_EntryPrice - g_RR_SLPrice);

   double tpDist = MathAbs(g_RR_EntryPrice - g_RR_TPPrice);

   

   // --- Dynamic Risk Logic (Calculate dynamic lots if "USE REC" is toggled ON) ---

   double activeLots = g_LotSize; 

   if(g_UseRecLot && vpp > 0 && slDist > 0 && equity > 0)

     {

      double riskAmt = equity * 0.01; // Targeting 1% limit risk per trade

      double slMoney = slDist * vpp; 

      double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

      if(lotStep <= 0) lotStep = 0.01;

      

      double calcLots = (slMoney > 0) ? riskAmt / slMoney : activeLots;

      calcLots = NormalizeDouble(MathFloor(calcLots / lotStep) * lotStep, 2);

      activeLots = MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), 

                   MathMin(calcLots, SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX)));

     }



   // Maths

   double riskMoney = (vpp > 0) ? activeLots * vpp * slDist : 0;

   double rewMoney  = (vpp > 0) ? activeLots * vpp * tpDist : 0;

   double riskPct   = (equity > 0) ? (riskMoney / equity) * 100.0 : 0;

   double rewPct    = (equity > 0) ? (rewMoney / equity) * 100.0 : 0;

   double rrRatio   = (slDist > 0) ? (tpDist / slDist) : 0.0;

   string dirText   = isBuy ? "\x25B2 LIMIT BUY" : "\x25BC LIMIT SELL";



   int chartW  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);

   int xPanel  = (int)(chartW * 0.70); // Hug Right margin

   int yEntry  = PriceToY(g_RR_EntryPrice);

   color bgClr = C'25,30,45';



   // Dynamic Texts

   string r1 = " " + dirText + "  " + DoubleToString(activeLots, 2) + " lots  |  RR 1 : " + DoubleToString(rrRatio, 2) + (g_UseRecLot?" (Auto) ":" ") ;

   string r2 = " Risk: -" + DoubleToString(riskMoney,2) + " " + currency + "  (-" + DoubleToString(riskPct, 2) + "%)";

   string r3 = " Profit: +" + DoubleToString(rewMoney,2) + " " + currency + "  (+" + DoubleToString(rewPct, 2) + "%)";

   string names[5] = {"TT_RR_Row1", "TT_RR_Row2", "TT_RR_Row3", "TT_RR_Confirm", "TT_RR_Cancel"};

   string texts[5] = {r1, r2, r3, isBuy ? " \x2714 Confirm BUY " : " \x2714 Confirm SELL ", " \x2718 Cancel "};

   color  clrs[5]  = {clrWhite, C'255,100,100', C'100,255,100', clrWhite, clrWhite};

   color  bgs[5]   = {bgClr, bgClr, bgClr, isBuy ? C'30,120,40' : C'140,40,30', C'80,80,80'};

   int    ydist[5] = {-38, -18, +2, +24, +24}; // Y spacing based off the center line

   int    xoffs[5] = {0, 0, 0, 0, +130}; // the cancel button is pushed to right



   // Prevent going off screen (cap panel vertically if lines are dragged off top/bottom limits)

   if(yEntry < 60) yEntry = 60; 



   for(int i = 0; i < 5; i++)

     {

      if(ObjectFind(0, names[i]) < 0) ObjectCreate(0, names[i], OBJ_LABEL, 0, 0, 0);

      ObjectSetInteger(0, names[i], OBJPROP_CORNER,    CORNER_LEFT_UPPER);

      ObjectSetInteger(0, names[i], OBJPROP_XDISTANCE, xPanel + xoffs[i]);

      ObjectSetInteger(0, names[i], OBJPROP_YDISTANCE, yEntry + ydist[i]);

      ObjectSetString (0, names[i], OBJPROP_TEXT,      texts[i]);

      ObjectSetInteger(0, names[i], OBJPROP_COLOR,     clrs[i]);

      ObjectSetInteger(0, names[i], OBJPROP_BGCOLOR,   bgs[i]);

      ObjectSetInteger(0, names[i], OBJPROP_FONTSIZE,  9 + (i>2?2:0)); // make confirm bigger

      ObjectSetString (0, names[i], OBJPROP_FONT,      "Arial Bold");

      ObjectSetInteger(0, names[i], OBJPROP_SELECTABLE, i>2); // Only buttons selectable

     }



   // --- PREVIEW LABELS (Like Real Trades) ---

   string prevSlName = "TT_PREV_SL_LBL";

   string prevTpName = "TT_PREV_TP_LBL";

   int prevBars = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);

   datetime prevRightTime = (datetime)((long)iTime(sym, PERIOD_CURRENT, 0) + (long)PeriodSeconds() * (long)MathMax(3, prevBars / 20));

   

   if(ObjectFind(0, prevSlName) < 0) {

       ObjectCreate(0, prevSlName, OBJ_TEXT, 0, prevRightTime, g_RR_SLPrice);

       ObjectSetInteger(0, prevSlName, OBJPROP_ANCHOR, ANCHOR_LEFT);

       ObjectSetInteger(0, prevSlName, OBJPROP_SELECTABLE, false);

       ObjectSetString (0, prevSlName, OBJPROP_FONT, "Arial Bold");

       ObjectSetInteger(0, prevSlName, OBJPROP_FONTSIZE, 10);

       ObjectSetInteger(0, prevSlName, OBJPROP_COLOR, clrRed); 

   }

   ObjectSetString(0, prevSlName, OBJPROP_TEXT, "  -" + DoubleToString(riskMoney, 2) + currency + " (" + DoubleToString(riskPct, 1) + "%)");

   ObjectSetDouble(0, prevSlName, OBJPROP_PRICE, g_RR_SLPrice);

   ObjectSetInteger(0, prevSlName, OBJPROP_TIME, prevRightTime);

   

   if(ObjectFind(0, prevTpName) < 0) {

       ObjectCreate(0, prevTpName, OBJ_TEXT, 0, prevRightTime, g_RR_TPPrice);

       ObjectSetInteger(0, prevTpName, OBJPROP_ANCHOR, ANCHOR_LEFT);

       ObjectSetInteger(0, prevTpName, OBJPROP_SELECTABLE, false);

       ObjectSetString (0, prevTpName, OBJPROP_FONT, "Arial Bold");

       ObjectSetInteger(0, prevTpName, OBJPROP_FONTSIZE, 10);

       ObjectSetInteger(0, prevTpName, OBJPROP_COLOR, clrLime); 

   }

   ObjectSetString(0, prevTpName, OBJPROP_TEXT, "  +" + DoubleToString(rewMoney, 2) + currency + " (" + DoubleToString(rewPct, 1) + "%)");

   ObjectSetDouble(0, prevTpName, OBJPROP_PRICE, g_RR_TPPrice);

   ObjectSetInteger(0, prevTpName, OBJPROP_TIME, prevRightTime);



   // --- Darken OUTSIDE regions (very subtle dim outside SL/TP range) ---

   if(ObjectFind(0, "TT_RR_DIM_TOP") >= 0 && ObjectGetInteger(0, "TT_RR_DIM_TOP", OBJPROP_TYPE) != OBJ_RECTANGLE_LABEL)

       ObjectDelete(0, "TT_RR_DIM_TOP");

   if(ObjectFind(0, "TT_RR_DIM_BOT") >= 0 && ObjectGetInteger(0, "TT_RR_DIM_BOT", OBJPROP_TYPE) != OBJ_RECTANGLE_LABEL)

       ObjectDelete(0, "TT_RR_DIM_BOT");



   // Use chart background color with very low alpha so we truly "dim"

   color chartBg   = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);

   uint  dimColor  = ColorToARGB(chartBg, 12); // ~5% overlay, should never look black

   if(ObjectFind(0, "TT_RR_DIM_TOP") < 0) {

       ObjectCreate(0, "TT_RR_DIM_TOP", OBJ_RECTANGLE_LABEL, 0, 0, 0);

       ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_CORNER, CORNER_LEFT_UPPER);

       ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_BGCOLOR, dimColor);

       ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_COLOR, clrNONE); // no border

       ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_SELECTABLE, false);

       ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_HIDDEN, true);

       ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_ZORDER, -1);

       ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_BACK, true);      // behind candles

   } else {

       ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_BGCOLOR, dimColor);

   }

   

   if(ObjectFind(0, "TT_RR_DIM_BOT") < 0) {

       ObjectCreate(0, "TT_RR_DIM_BOT", OBJ_RECTANGLE_LABEL, 0, 0, 0);

       ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_CORNER, CORNER_LEFT_UPPER);

       ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_BGCOLOR, dimColor);

       ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_COLOR, clrNONE); // no border

       ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_SELECTABLE, false);

       ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_HIDDEN, true);

       ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_ZORDER, -1);

       ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_BACK, true);      // behind candles

   } else {

       ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_BGCOLOR, dimColor);

   }

   

   double topDarkBorder = MathMax(g_RR_SLPrice, g_RR_TPPrice);

   double botDarkBorder = MathMin(g_RR_SLPrice, g_RR_TPPrice);

   

   int yTopBorder = MathMax(0, PriceToY(topDarkBorder));

   int yBotBorder = MathMax(0, PriceToY(botDarkBorder));

   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);



   ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_XDISTANCE, 0);

   ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_YDISTANCE, 0);

   ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_XSIZE, chartW);

   ObjectSetInteger(0, "TT_RR_DIM_TOP", OBJPROP_YSIZE, yTopBorder);



   ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_XDISTANCE, 0);

   ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_YDISTANCE, yBotBorder);

   ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_XSIZE, chartW);

   ObjectSetInteger(0, "TT_RR_DIM_BOT", OBJPROP_YSIZE, MathMax(0, chartH - yBotBorder));



   ChartRedraw(0);

  }



void ShowRR(double entryPrice, ENUM_ORDER_TYPE orderType)

  {

   HideRR();

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double atr    = GetCurrentATR();

   

   if(atr <= 0) { SetStatus("ATR unavailable for RR build", WarningColor); return; }



   bool   isBuy  = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);

   double slDist = atr * AtrMultiplier;

   double tpDist = slDist * 3.0;



   g_RR_EntryPrice = NormalizeDouble(entryPrice, digits);

   g_RR_SLPrice    = NormalizeDouble(isBuy ? entryPrice - slDist : entryPrice + slDist, digits);

   g_RR_TPPrice    = NormalizeDouble(isBuy ? entryPrice + tpDist : entryPrice - tpDist, digits);

   g_RRType        = orderType;



   // ── INTERACTIVE DRAGGABLE LINES ─────────────────────────

   string names[3] = {"TT_RR_TP", "TT_RR_Entry", "TT_RR_SL"};

   color  clrs[3]  = {C'40,180,40', C'80,140,220', C'200,60,60'};

   double prc[3]   = {g_RR_TPPrice, g_RR_EntryPrice, g_RR_SLPrice};

   int    styles[3]= {STYLE_DASH, STYLE_SOLID, STYLE_DASH};

   int    widths[3]= {2, 2, 2};



   for(int i = 0; i < 3; i++)

     {

      ObjectCreate(0, names[i], OBJ_HLINE, 0, 0, prc[i]);

      ObjectSetInteger(0, names[i], OBJPROP_COLOR, clrs[i]);

      ObjectSetInteger(0, names[i], OBJPROP_STYLE, styles[i]);

      ObjectSetInteger(0, names[i], OBJPROP_WIDTH, widths[i]);

      ObjectSetInteger(0, names[i], OBJPROP_BACK,  true); // render behind candles

      

      // Pro UX Feature: Pre-Select them so they are immediately draggable!

      ObjectSetInteger(0, names[i], OBJPROP_SELECTABLE, true);

      ObjectSetInteger(0, names[i], OBJPROP_SELECTED,   true);

     }



   g_RRActive = true;

   UpdateRRPnl(); // Computes Math & Renders UI Panel

  }



// ═══════════════════════════════════════════════════════════════════════════



// Places a LIMIT order at right-click price using standard non-custom sizes

void PlaceOrderAtPrice(double price, ENUM_ORDER_TYPE limitType)

  {

   if(g_Blocked) { SetStatus("Blocked — liq too close", WarningColor); return; }



   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);

   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);

   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);

   price = NormalizeDouble(price, digits);



   double atr     = GetCurrentATR();

   if(atr <= 0) { SetStatus("ATR unavailable", WarningColor); return; }



   double slDist = atr * AtrMultiplier;

   double tpDist = slDist * 3.0;



   // Enforce broker minimum stop

   long   stopLvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);

   double minStop = MathMax(stopLvl * point, (ask - bid) * 2.0);

   if(slDist < minStop) slDist = minStop;



   bool isBuy = (limitType == ORDER_TYPE_BUY_LIMIT);



   double sl = isBuy ? NormalizeDouble(price - slDist, digits)

                     : NormalizeDouble(price + slDist, digits);

   double tp = isBuy ? NormalizeDouble(price + tpDist, digits)

                     : NormalizeDouble(price - tpDist, digits);



   // Detect filling mode

   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_RETURN;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;



   MqlTradeRequest req = {};

   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_PENDING;

   req.symbol       = sym;

   req.volume       = g_LotSize;

   req.type         = limitType;

   req.price        = price;

   req.sl           = sl;

   req.tp           = tp;

   req.deviation    = 20;

   req.magic        = 20240101;

   req.comment      = "TT_LimitOrder";

   req.type_filling = filling;

   req.type_time    = ORDER_TIME_GTC;



   if(!OrderSend(req, res))

     {

      SetStatus("Limit order failed: " + DecodeRetcode(res.retcode), WarningColor);

      return;

     }



   string dir = isBuy ? "BUY" : "SELL";

   SetStatus(dir + " LIMIT @ " + DoubleToString(price, digits) +

             "  SL:" + DoubleToString(sl, digits) +

             "  TP:" + DoubleToString(tp, digits), clrLime);

   UpdateAll();

  }




//+------------------------------------------------------------------+
//  Immediately draw P&L labels on a freshly placed pending order's
//  SL and TP lines.  Called right after OrderSend() succeeds so the
//  labels appear without waiting for the next timer tick.
//+------------------------------------------------------------------+
void DrawOrderPnlLabels(ulong   ticket,
                        double  entryPrice,
                        double  sl,
                        double  tp,
                        double  lots,
                        bool    isBuy,
                        string  sym)
  {
   string   currency = AccountInfoString(ACCOUNT_CURRENCY);
   double   equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double   vpp      = GetVPP(sym);
   int      visible  = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
   datetime rightT   = (datetime)((long)iTime(sym, PERIOD_CURRENT, 0)
                       + (long)PeriodSeconds() * (long)MathMax(3, visible / 20));

   //── SL label ──────────────────────────────────────────────────────
   if(sl > 0 && vpp > 0)
     {
      double slDist  = isBuy ? (entryPrice - sl) : (sl - entryPrice);
      double myLoss  = MathAbs(slDist) * lots * vpp;
      double myLossP = equity > 0 ? (myLoss / equity) * 100.0 : 0;
      string slLbl   = "TT_SL_ORD_" + IntegerToString(ticket);
      if(ObjectFind(0, slLbl) < 0)
        {
         ObjectCreate(0, slLbl, OBJ_TEXT, 0, rightT, sl);
         ObjectSetInteger(0, slLbl, OBJPROP_ANCHOR,     ANCHOR_LEFT);
         ObjectSetInteger(0, slLbl, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, slLbl, OBJPROP_HIDDEN,     true);
         ObjectSetString (0, slLbl, OBJPROP_FONT,       "Arial");
         ObjectSetInteger(0, slLbl, OBJPROP_FONTSIZE,   9);
         ObjectSetInteger(0, slLbl, OBJPROP_COLOR,      clrRed);
        }
      ObjectSetString (0, slLbl, OBJPROP_TEXT,
                       "  -" + DoubleToString(myLoss, 2) + " " + currency +
                       "  (" + DoubleToString(myLossP, 1) + "%)");
      ObjectSetDouble (0, slLbl, OBJPROP_PRICE, sl);
      ObjectSetInteger(0, slLbl, OBJPROP_TIME,  rightT);
     }

   //── TP label ──────────────────────────────────────────────────────
   if(tp > 0 && vpp > 0)
     {
      double tpDist  = isBuy ? (tp - entryPrice) : (entryPrice - tp);
      double myGain  = MathAbs(tpDist) * lots * vpp;
      double myGainP = equity > 0 ? (myGain / equity) * 100.0 : 0;
      string tpLbl   = "TT_TP_ORD_" + IntegerToString(ticket);
      if(ObjectFind(0, tpLbl) < 0)
        {
         ObjectCreate(0, tpLbl, OBJ_TEXT, 0, rightT, tp);
         ObjectSetInteger(0, tpLbl, OBJPROP_ANCHOR,     ANCHOR_LEFT);
         ObjectSetInteger(0, tpLbl, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, tpLbl, OBJPROP_HIDDEN,     true);
         ObjectSetString (0, tpLbl, OBJPROP_FONT,       "Arial");
         ObjectSetInteger(0, tpLbl, OBJPROP_FONTSIZE,   9);
         ObjectSetInteger(0, tpLbl, OBJPROP_COLOR,      clrLime);
        }
      ObjectSetString (0, tpLbl, OBJPROP_TEXT,
                       "  +" + DoubleToString(myGain, 2) + " " + currency +
                       "  (+" + DoubleToString(myGainP, 1) + "%)");
      ObjectSetDouble (0, tpLbl, OBJPROP_PRICE, tp);
      ObjectSetInteger(0, tpLbl, OBJPROP_TIME,  rightT);
     }

   ChartRedraw(0);
  }

// Place user-adjusted Draggable Limit Order (Respects Lot size recalculation)

void PlaceCustomRR(ENUM_ORDER_TYPE orderType, double customPrc, double customSL, double customTP)

  {

   if(g_Blocked) { SetStatus("Blocked \x2014 Liq distance threshold exceeded!", WarningColor); return; }



   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   

   // Verify minimum limits per broker rules

   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);

   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);

   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);

   double stopLevelPts = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);

   double minStop = MathMax(stopLevelPts * point, (ask - bid) * 2.0);



   if(MathAbs(customPrc - customSL) < minStop) {

        SetStatus("Order Rejected: SL too close for this broker", WarningColor); return;

   }



   // Enforce Smart Sizing

   double activeLots = g_LotSize;

   if(g_UseRecLot)

     {

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);

      double vpp = GetVPP(sym);

      double slDist = MathAbs(customPrc - customSL);

      if(vpp > 0 && equity > 0 && slDist > 0)

        {

         double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

         double slMoney = slDist * vpp;

         double rawLots = (equity * 0.01) / slMoney;

         activeLots = NormalizeDouble(MathFloor(rawLots / lotStep) * lotStep, 2);

        }

     }

     

   activeLots = MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), 

                MathMin(activeLots, SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX)));



   // Detect filling mode for pending orders

   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_RETURN;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;



   MqlTradeRequest req = {};

   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_PENDING;

   req.symbol       = sym;

   req.volume       = activeLots;

   

   // Auto-detect Limit vs Stop based on current price relative to entry

   bool isBuy = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);

   if(isBuy)

     {

      req.type = (customPrc > ask) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_BUY_LIMIT;

     }

   else

     {

      req.type = (customPrc < bid) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_SELL_LIMIT;

     }



   req.price        = customPrc;

   req.sl           = customSL;

   req.tp           = customTP;

   req.deviation    = 20;

   req.magic        = 20240101;

   req.comment      = "TT_DragDrop";

   req.type_filling = filling;

   req.type_time    = ORDER_TIME_GTC;



   if(!OrderSend(req, res))
     {
      SetStatus("Execution error: " + DecodeRetcode(res.retcode), WarningColor);
     }
   else
     {
      SetStatus("Order placed @ " + DoubleToString(customPrc, digits) +
                "  SL:" + DoubleToString(customSL, digits) +
                "  TP:" + DoubleToString(customTP, digits), clrLime);
      // Draw P&L labels on SL/TP lines immediately (no timer-tick delay)
      if(res.order > 0)
         DrawOrderPnlLabels(res.order, customPrc, customSL, customTP, activeLots, isBuy, sym);
     }

   UpdateAll();

  }



void OnChartEvent(const int id, const long &lparam,

                  const double &dparam, const string &sparam)

  {

   if(id == CHARTEVENT_CHART_CHANGE)

     {

      UpdateAll();

      if(g_RRActive) UpdateRRPnl();

      return;

     }



   // ==== Real-time drag processing for the visual Risk/Reward TradingView layout ====

   if(id == CHARTEVENT_OBJECT_DRAG)

     {

      // Update alert line label when dragged

      if(sparam == CTX_ALERT_LINE)

        {

         double alertP = ObjectGetDouble(0, CTX_ALERT_LINE, OBJPROP_PRICE);

         int    alertD = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

         datetime lblT = (datetime)(TimeCurrent() + PeriodSeconds() * 5);

         

         ObjectSetInteger(0, CTX_ALERT_LINE, OBJPROP_COLOR, C'80,180,255');

         

         if(ObjectFind(0, CTX_ALERT_LBL) >= 0)

           {

            ObjectSetDouble (0, CTX_ALERT_LBL, OBJPROP_PRICE, alertP);

            ObjectSetInteger(0, CTX_ALERT_LBL, OBJPROP_TIME,  lblT);

            ObjectSetString (0, CTX_ALERT_LBL, OBJPROP_TEXT,  "ALERT " + DoubleToString(alertP, alertD));

            ObjectSetInteger(0, CTX_ALERT_LBL, OBJPROP_COLOR, C'80,180,255');

           }

         ObjectSetString(0, CTX_ALERT_LINE, OBJPROP_TOOLTIP,

                         "Alert @ " + DoubleToString(alertP, alertD));

         return;

        }

      if(sparam == "TT_RR_Entry" || sparam == "TT_RR_SL" || sparam == "TT_RR_TP")

        {

         if(sparam == "TT_RR_Entry")

           {

            // Sync moving both SL and TP precisely with the order line displacement

            double newEntry = ObjectGetDouble(0, "TT_RR_Entry", OBJPROP_PRICE);

            double diff     = newEntry - g_RR_EntryPrice;

            g_RR_EntryPrice = newEntry;

            g_RR_SLPrice   += diff;

            g_RR_TPPrice   += diff;

            ObjectSetDouble(0, "TT_RR_SL", OBJPROP_PRICE, g_RR_SLPrice);

            ObjectSetDouble(0, "TT_RR_TP", OBJPROP_PRICE, g_RR_TPPrice);

           }

         else

           {

            // Independent SL/TP dragging

            g_RR_EntryPrice = ObjectGetDouble(0, "TT_RR_Entry", OBJPROP_PRICE);

            g_RR_SLPrice    = ObjectGetDouble(0, "TT_RR_SL",    OBJPROP_PRICE);

            g_RR_TPPrice    = ObjectGetDouble(0, "TT_RR_TP",    OBJPROP_PRICE);

           }

         // Dynamically refresh panel with the new distances/R:R maths!

         UpdateRRPnl(); 

         return; 

        }

     }



   double lotMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lotMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lotMin <= 0) lotMin = 0.01;

   if(lotMax <= 0) lotMax = 100.0;



   if(id == CHARTEVENT_OBJECT_CLICK)

     {

      if(sparam == P_LOTS_UP)

        {

         g_LotSize = NormalizeDouble(g_LotSize + 0.1, 2);

         if(g_LotSize > lotMax) g_LotSize = lotMax;

         ObjectSetString(0, P_LOTS_EDIT, OBJPROP_TEXT, DoubleToString(g_LotSize, 2));

         UpdateAll();

        }

      else if(sparam == P_LOTS_DN)

        {

         g_LotSize = NormalizeDouble(g_LotSize - 0.1, 2);

         if(g_LotSize < lotMin) g_LotSize = lotMin;

         ObjectSetString(0, P_LOTS_EDIT, OBJPROP_TEXT, DoubleToString(g_LotSize, 2));

         UpdateAll();

        }

      else if(sparam == P_BUY_BTN)

        {

         ObjectSetInteger(0, P_BUY_BTN, OBJPROP_STATE, false);

         if(!g_Blocked) PlaceTrade(ORDER_TYPE_BUY);

         else           SetStatus("BLOCKED: would breach liq threshold!", WarningColor);

        }

      else if(sparam == P_SELL_BTN)

        {

         ObjectSetInteger(0, P_SELL_BTN, OBJPROP_STATE, false);

         if(!g_Blocked) PlaceTrade(ORDER_TYPE_SELL);

         else           SetStatus("BLOCKED: would breach liq threshold!", WarningColor);

        }

      else if(sparam == P_FLAT_BTN)

        {

         ObjectSetInteger(0, P_FLAT_BTN, OBJPROP_STATE, false);

         FlattenAll();

        }

      else if(sparam == P_ZBUY_BTN)

        {

         ObjectSetInteger(0, P_ZBUY_BTN, OBJPROP_STATE, false);

         if(!g_Blocked) PlaceZoneOrders(ORDER_TYPE_BUY_LIMIT);

         else           SetStatus("BLOCKED: would breach liq threshold!", WarningColor);

        }

      else if(sparam == P_ZSELL_BTN)

        {

         ObjectSetInteger(0, P_ZSELL_BTN, OBJPROP_STATE, false);

         if(!g_Blocked) PlaceZoneOrders(ORDER_TYPE_SELL_LIMIT);

         else           SetStatus("BLOCKED: would breach liq threshold!", WarningColor);

        }

      else if(sparam == P_ZONE_UP)

        {

         ObjectSetInteger(0, P_ZONE_UP, OBJPROP_STATE, false);

         g_PendingShift = 1;

        }

      else if(sparam == P_ZONE_DN)

        {

         ObjectSetInteger(0, P_ZONE_DN, OBJPROP_STATE, false);

         g_PendingShift = -1;

        }

      // Hedge buttons

      else if(sparam == P_HIST_BTN)

        {

         ObjectSetInteger(0, P_HIST_BTN, OBJPROP_STATE, false);

         g_HistoryOn = !g_HistoryOn;

         if(g_HistoryOn) DrawHistoryMarks();

         else            DeleteHistoryMarks();

         ObjectSetString (0, P_HIST_BTN, OBJPROP_TEXT,

                          g_HistoryOn ? "HISTORY ON" : "HISTORY");

         ObjectSetInteger(0, P_HIST_BTN, OBJPROP_BGCOLOR,

                          g_HistoryOn ? C'0,80,110' : C'40,55,65');

        }

      else if(sparam == P_USE_REC)

        {

         ObjectSetInteger(0, P_USE_REC, OBJPROP_STATE, false);

         g_UseRecLot = !g_UseRecLot;

         ObjectSetString (0, P_USE_REC, OBJPROP_TEXT,

                          g_UseRecLot ? "USE REC  ON" : "USE REC");

         ObjectSetInteger(0, P_USE_REC, OBJPROP_BGCOLOR,

                          g_UseRecLot ? C'0,110,60' : C'55,70,55');

        // Instantly force UI update if dragged layout active

        if(g_RRActive) UpdateRRPnl();

        }

      else if(sparam == P_ADD_1)

        {

         ObjectSetInteger(0, P_ADD_1, OBJPROP_STATE, false);

         AddToPosition(0.5);

        }

      else if(sparam == P_ADD_2)

        {

         ObjectSetInteger(0, P_ADD_2, OBJPROP_STATE, false);

         AddToPosition(1.0);

        }

      else if(sparam == P_ADD_3)

        {

         ObjectSetInteger(0, P_ADD_3, OBJPROP_STATE, false);

         AddToPosition(1.5);

        }

      else if(sparam == P_ADD_4)

        {

         ObjectSetInteger(0, P_ADD_4, OBJPROP_STATE, false);

         AddToPosition(2.0);

        }

      else if(sparam == P_REV_BTN)

        {

         ObjectSetInteger(0, P_REV_BTN, OBJPROP_STATE, false);

         ReversePosition();

        }

      else if(sparam == P_TRAIL_BTN)

        {

         ObjectSetInteger(0, P_TRAIL_BTN, OBJPROP_STATE, false);

         g_TrailActive = !g_TrailActive;

         if(!g_TrailActive) { g_TrailStop = 0; DeleteTrailLine(); }

         UpdateTrailButton();

         SetStatus(g_TrailActive ? "Smart trail ACTIVE" : "Smart trail OFF", g_TrailActive ? clrAqua : clrSilver);

        }

      else if(sparam == P_CHDG_BTN)

        {

         ObjectSetInteger(0, P_CHDG_BTN, OBJPROP_STATE, false);

         CloseProfitablePositions();

        }

      else if(sparam == P_HDG_1)

        {

         ObjectSetInteger(0, P_HDG_1, OBJPROP_STATE, false);

         PlaceHedge(0.3333);

        }

      else if(sparam == P_HDG_2)

        {

         ObjectSetInteger(0, P_HDG_2, OBJPROP_STATE, false);

         PlaceHedge(0.5);

        }

      else if(sparam == P_HDG_3)

        {

         ObjectSetInteger(0, P_HDG_3, OBJPROP_STATE, false);

         PlaceHedge(0.8);

        }

      else if(sparam == P_HDG_4)

        {

         ObjectSetInteger(0, P_HDG_4, OBJPROP_STATE, false);

         PlaceHedge(1.0);

        }

      // Close buttons

      else if(sparam == P_CLS_1)

        {

         ObjectSetInteger(0, P_CLS_1, OBJPROP_STATE, false);

         PartialClose(0.3333);

        }

      else if(sparam == P_CLS_2)

        {

         ObjectSetInteger(0, P_CLS_2, OBJPROP_STATE, false);

         PartialClose(0.5);

        }

      else if(sparam == P_CLS_3)

        {

         ObjectSetInteger(0, P_CLS_3, OBJPROP_STATE, false);

         PartialClose(0.8);

        }

      else if(sparam == P_CLS_4)

        {

         ObjectSetInteger(0, P_CLS_4, OBJPROP_STATE, false);

         PartialClose(1.0);

        }

     }



   if(id == CHARTEVENT_OBJECT_ENDEDIT && sparam == P_LOTS_EDIT)

     {

      string txt = ObjectGetString(0, P_LOTS_EDIT, OBJPROP_TEXT);

      double val = StringToDouble(txt);

      if(val < lotMin) val = lotMin;

      if(val > lotMax) val = lotMax;

      g_LotSize = NormalizeDouble(val, 2);

      ObjectSetString(0, P_LOTS_EDIT, OBJPROP_TEXT, DoubleToString(g_LotSize, 2));

      UpdateAll();

      if(g_RRActive) UpdateRRPnl(); // Update preview math natively when changing base lot 

     }



   // ---- RIGHT-CLICK CONTEXT MENU ----

   if(id == CHARTEVENT_MOUSE_MOVE)

     {

      g_CtxMouseX = (int)lparam;

      g_CtxMouseY = (int)dparam;

      

      int window = 0;

      datetime timeAtMouse = 0;

      double priceAtMouse = 0;

      if(!g_CtxMenuOpen && ChartXYToTimePrice(0, g_CtxMouseX, g_CtxMouseY, window, timeAtMouse, priceAtMouse))

        {

         g_CtxPrice = priceAtMouse;

        }



      bool rightDown = ((int)StringToInteger(sparam) & 2) != 0;

      if(rightDown && !g_WasRightDown)

        {

         bool hasPos = false;

         for(int i = 0; i < PositionsTotal(); i++)

            if(PositionGetSymbol(i) == _Symbol) { hasPos = true; break; }

         

         // In standard implementation show it even if no positions are active so user can always prep limits

         ShowContextMenu(g_CtxPrice); 

        }

      g_WasRightDown = rightDown;

     }



   if(id == CHARTEVENT_OBJECT_CLICK)

     {

      if(sparam == CTX_SET_SL)

        { HideContextMenu(); SetAllSLAtPrice(g_CtxPrice); UpdateAll(); }

      else if(sparam == CTX_SET_TP)

        { HideContextMenu(); SetAllTPAtPrice(g_CtxPrice); UpdateAll(); }

      else if(sparam == CTX_ALERT)

        {

         HideContextMenu();

         // Place a draggable alert line at the right-click price

         string sym2    = _Symbol;

         int    dig2    = (int)SymbolInfoInteger(sym2, SYMBOL_DIGITS);

         // Remove any existing alert line first

         ObjectDelete(0, CTX_ALERT_LINE);

         ObjectDelete(0, CTX_ALERT_LBL);

         // Create draggable horizontal line

         ObjectCreate(0, CTX_ALERT_LINE, OBJ_HLINE, 0, 0, g_CtxPrice);

         ObjectSetInteger(0, CTX_ALERT_LINE, OBJPROP_COLOR,      C'80,180,255');

         ObjectSetInteger(0, CTX_ALERT_LINE, OBJPROP_STYLE,      STYLE_DASH);

         ObjectSetInteger(0, CTX_ALERT_LINE, OBJPROP_WIDTH,      1);

         ObjectSetInteger(0, CTX_ALERT_LINE, OBJPROP_SELECTABLE, true);

         ObjectSetInteger(0, CTX_ALERT_LINE, OBJPROP_SELECTED,   true);

         ObjectSetString (0, CTX_ALERT_LINE, OBJPROP_TOOLTIP,

                          "Alert @ " + DoubleToString(g_CtxPrice, dig2) + " — drag to move, Delete key to remove");

         // Label next to it

         datetime lblTime = (datetime)(TimeCurrent() + PeriodSeconds() * 5);

         ObjectCreate(0, CTX_ALERT_LBL, OBJ_TEXT, 0, lblTime, g_CtxPrice);

         ObjectSetString (0, CTX_ALERT_LBL, OBJPROP_TEXT,  "ALERT " + DoubleToString(g_CtxPrice, dig2));

         ObjectSetInteger(0, CTX_ALERT_LBL, OBJPROP_COLOR, C'80,180,255');

         ObjectSetInteger(0, CTX_ALERT_LBL, OBJPROP_FONTSIZE, 8);

         ObjectSetString (0, CTX_ALERT_LBL, OBJPROP_FONT, "Arial Bold");

         ObjectSetInteger(0, CTX_ALERT_LBL, OBJPROP_SELECTABLE, false);

         SetStatus("Alert line placed @ " + DoubleToString(g_CtxPrice, dig2) + " — drag to adjust", C'80,180,255');

        }

      else if(sparam == CTX_ORDER_BUY)

        { HideContextMenu(); ShowRR(g_CtxPrice, ORDER_TYPE_BUY_LIMIT); }

      else if(sparam == CTX_ORDER_SEL)

        { HideContextMenu(); ShowRR(g_CtxPrice, ORDER_TYPE_SELL_LIMIT); }

      else if(sparam == CTX_ORDER_BSTP)

        { HideContextMenu(); ShowRR(g_CtxPrice, ORDER_TYPE_BUY_STOP); }

      else if(sparam == CTX_ORDER_SSTP)

        { HideContextMenu(); ShowRR(g_CtxPrice, ORDER_TYPE_SELL_STOP); }

      

      // Changed handler branch to connect execution to new dynamically updating Drag method

      else if(sparam == "TT_RR_Confirm" && g_RRActive)

        {

         HideRR();

         PlaceCustomRR(g_RRType, g_RR_EntryPrice, g_RR_SLPrice, g_RR_TPPrice);

        }

      else if(sparam == "TT_RR_Cancel"  && g_RRActive)

        { HideRR(); SetStatus("Draggable UI sequence cancelled", clrSilver); }

      else if(g_CtxMenuOpen && sparam != P_LOTS_EDIT)

        { HideContextMenu(); ChartRedraw(0); }

     }



   if(id == CHARTEVENT_CLICK && g_CtxMenuOpen)

     { HideContextMenu(); ChartRedraw(0); }



   if(id == CHARTEVENT_KEYDOWN && lparam == 27) // Escape key

     {

      if(g_CtxMenuOpen) { HideContextMenu(); ChartRedraw(0); }

      if(g_RRActive)    { HideRR(); }

     }



   // Repin RR compact panel logically to exact coordinate location mapped dynamically via formula processing loop update func!

   if(id == CHARTEVENT_CHART_CHANGE && g_RRActive)

     {

      UpdateRRPnl();

     }



  }



//+------------------------------------------------------------------+

void CloseProfitablePositions()

  {

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);

   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);

   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);



   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;

   else                                              filling = ORDER_FILLING_RETURN;



   // Capture the close price before any orders go out — this becomes the SL anchor

   double closeLevelBid = bid;

   double closeLevelAsk = ask;



   // ATR SL distance — same as used everywhere else

   double atr    = GetCurrentATR();

   double slDist = atr * AtrMultiplier;

   double minStop = MathMax(SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point,

                            (ask - bid) * 2.0);

   if(slDist < minStop) slDist = minStop;



   // ── PASS 1: close positions tagged as hedges or check if fully hedged ──

   double buyVol = 0, sellVol = 0;

   int hedgeFound = 0;

   for(int i = 0; i < PositionsTotal(); i++)

     {

      if(PositionGetSymbol(i) != sym) continue;

      string cmt = PositionGetString(POSITION_COMMENT);

      if(StringFind(cmt, "Hedge") >= 0) hedgeFound++;

      double lots = PositionGetDouble(POSITION_VOLUME);

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyVol += lots;

      else sellVol += lots;

     }



   int closed = 0, failed = 0, skipped = 0;

   bool isFullyHedged = (buyVol > 0 && sellVol > 0 && MathAbs(buyVol - sellVol) < 0.00001);

   bool closingHedges = (hedgeFound > 0 || isFullyHedged);



   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      string cmt    = PositionGetString(POSITION_COMMENT);

      bool   isHedgePos = (StringFind(cmt, "Hedge") >= 0);



      // If tagged hedges exist, or we're fully hedged → close them regardless of profit

      if(closingHedges)

        { if(!isFullyHedged && !isHedgePos) { skipped++; continue; } }

      else

        {

         double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

         if(profit <= 0) { skipped++; continue; }

        }



      ulong  ticket  = PositionGetInteger(POSITION_TICKET);

      double lots    = PositionGetDouble(POSITION_VOLUME);

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      ENUM_ORDER_TYPE closeType = (pt == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      double closePrice = (closeType == ORDER_TYPE_SELL) ? bid : ask;



      MqlTradeRequest req = {};

      MqlTradeResult  res = {};

      req.action       = TRADE_ACTION_DEAL;

      req.symbol       = sym;

      req.volume       = lots;

      req.type         = closeType;

      req.price        = closePrice;

      req.position     = ticket;

      req.deviation    = 20;

      req.magic        = 20240101;

      req.comment      = closingHedges ? "CloseHedge" : "CloseProfit";

      req.type_filling = filling;

      if(OrderSend(req, res)) closed++;

      else                    failed++;

     }



   if(closed == 0 && failed == 0)

     {

      SetStatus(closingHedges ? "No hedge positions found"

                              : (skipped > 0 ? "No profitable positions" : "No positions"),

                clrSilver);

      return;

     }



   // Set SL on all remaining (losing) positions anchored to the hedge-close price level

   int slSet = 0;

   if(skipped > 0)

     {

      Sleep(200);

      for(int i = PositionsTotal() - 1; i >= 0; i--)

        {

         if(PositionGetSymbol(i) != sym) continue;



         ulong  ticket  = PositionGetInteger(POSITION_TICKET);

         double tp      = PositionGetDouble(POSITION_TP);

         ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);



         // SL placed ATR*mult away from the close level — in losing direction to give room

         double sl = (pt == POSITION_TYPE_BUY)

                     ? NormalizeDouble(closeLevelBid - slDist, digits)   // long: SL below close level

                     : NormalizeDouble(closeLevelAsk + slDist, digits);  // short: SL above close level



         MqlTradeRequest modReq = {};

         MqlTradeResult  modRes = {};

         modReq.action   = TRADE_ACTION_SLTP;

         modReq.symbol   = sym;

         modReq.position = ticket;

         modReq.sl       = sl;

         modReq.tp       = tp;

         if(OrderSend(modReq, modRes)) slSet++;

        }

     }



   // Reset hedge session so floating PnL shows only remaining positions' unrealized P&L

   g_HedgeSessionActive = false;

   g_HedgeSessionPnL    = 0;



   string msg = "Closed " + IntegerToString(closed) + " profitable";

   if(skipped > 0) msg += "  |  SL set on " + IntegerToString(slSet) + " remaining";

   if(failed  > 0) msg += " (" + IntegerToString(failed) + " close failed)";

   SetStatus(msg, failed > 0 ? WarningColor : clrLime);

   UpdateAll();

  }



void PlaceHedge(double pct)

  {

   string sym    = _Symbol;



   double buyVol = 0, sellVol = 0;

   for(int i = 0; i < PositionsTotal(); i++)

     {

      if(PositionGetSymbol(i) != sym) continue;

      double lots = PositionGetDouble(POSITION_VOLUME);

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(pt == POSITION_TYPE_BUY) buyVol  += lots;

      else                        sellVol += lots;

     }



   double netVol = buyVol - sellVol;

   if(MathAbs(netVol) < 0.00001)

     {

      SetStatus("No net exposure to hedge", clrSilver);

      return;

     }



   ENUM_ORDER_TYPE hedgeType = (netVol > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;



   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double lotMin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   double lotMax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   if(lotStep <= 0) lotStep = 0.01;



   double hedgeVol = NormalizeDouble(MathFloor((MathAbs(netVol) * pct) / lotStep) * lotStep, 2);

   hedgeVol = MathMax(hedgeVol, lotMin);

   hedgeVol = MathMin(hedgeVol, lotMax);



   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;

   else                                              filling = ORDER_FILLING_RETURN;



   double price = (hedgeType == ORDER_TYPE_SELL)

                  ? SymbolInfoDouble(sym, SYMBOL_BID)

                  : SymbolInfoDouble(sym, SYMBOL_ASK);



   string pctLabel = DoubleToString(pct * 100.0, 0) + "%";



   MqlTradeRequest req = {};

   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;

   req.symbol       = sym;

   req.volume       = hedgeVol;

   req.type         = hedgeType;

   req.price        = price;

   req.deviation    = 20;

   req.magic        = 20240101;

   req.comment      = "Hedge_" + pctLabel;

   req.type_filling = filling;



   if(!OrderSend(req, res))

     {

      SetStatus("Hedge failed: " + DecodeRetcode(res.retcode), WarningColor);

      UpdateAll();

      return;

     }



   // Activate hedge session tracking if not already running

   if(!g_HedgeSessionActive)

     {

      g_HedgeSessionActive = true;

      g_HedgeSessionStart  = TimeCurrent();

      g_HedgeSessionPnL    = 0;

     }

      // After placing the hedge, remove SL from all existing positions

   // (hedged position protects downside; open SL orders become redundant)

   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      ulong  ticket = PositionGetInteger(POSITION_TICKET);

      double sl     = PositionGetDouble(POSITION_SL);

      double tp     = PositionGetDouble(POSITION_TP);

      if(sl == 0) continue;   // already no SL

      MqlTradeRequest mReq = {};

      MqlTradeResult  mRes = {};

      mReq.action   = TRADE_ACTION_SLTP;

      mReq.symbol   = sym;

      mReq.position = ticket;

      mReq.sl       = 0;

      mReq.tp       = tp;

      if(!OrderSend(mReq, mRes)) Print("OrderSend failed: ", mRes.retcode);

     }



   SetStatus("Hedge " + pctLabel + ": " + DoubleToString(hedgeVol, 2) +

             " lots " + (hedgeType == ORDER_TYPE_SELL ? "SELL" : "BUY") +

             " | SLs removed", clrLime);

   UpdateAll();

  }



void PartialClose(double pct)

  {

   string sym    = _Symbol;



   // Collect all positions on this symbol, largest first so we close proportionally

   int    n      = PositionsTotal();

   ulong  tickets[];

   double vols[];

   ENUM_POSITION_TYPE types[];

   int    count  = 0;



   for(int i = 0; i < n; i++)

     {

      if(PositionGetSymbol(i) != sym) continue;

      ArrayResize(tickets, count + 1);

      ArrayResize(vols,    count + 1);

      ArrayResize(types,   count + 1);

      tickets[count] = PositionGetInteger(POSITION_TICKET);

      vols[count]    = PositionGetDouble(POSITION_VOLUME);

      types[count]   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      count++;

     }



   if(count == 0)

     {

      SetStatus("No positions to close", clrSilver);

      return;

     }



   // Total gross volume

   double totalVol = 0;

   for(int i = 0; i < count; i++) totalVol += vols[i];



   // Volume to close = pct of total

   double lotStep  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double lotMin   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   if(lotStep <= 0) lotStep = 0.01;

   double toClose  = NormalizeDouble(MathFloor((totalVol * pct) / lotStep) * lotStep, 2);

   if(toClose < lotMin) toClose = lotMin;



   // Detect filling mode

   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;

   else                                              filling = ORDER_FILLING_RETURN;



   string pctLabel = DoubleToString(pct * 100.0, 0) + "%";

   int    closed   = 0;

   int    failed   = 0;

   double remaining = toClose;



   // Work through positions, closing each partially or fully until target volume is reached

   for(int i = 0; i < count && remaining > 0.00001; i++)

     {

      double closeVol = MathMin(vols[i], remaining);

      closeVol = NormalizeDouble(MathFloor(closeVol / lotStep) * lotStep, 2);

      if(closeVol < lotMin) continue;



      ENUM_ORDER_TYPE closeType = (types[i] == POSITION_TYPE_BUY)

                                  ? ORDER_TYPE_SELL

                                  : ORDER_TYPE_BUY;

      double closePrice = (closeType == ORDER_TYPE_SELL)

                          ? SymbolInfoDouble(sym, SYMBOL_BID)

                          : SymbolInfoDouble(sym, SYMBOL_ASK);



      MqlTradeRequest req = {};

      MqlTradeResult  res = {};

      req.action       = TRADE_ACTION_DEAL;

      req.symbol       = sym;

      req.volume       = closeVol;

      req.type         = closeType;

      req.price        = closePrice;

      req.position     = tickets[i];

      req.deviation    = 20;

      req.magic        = 20240101;

      req.comment      = "Close_" + pctLabel;

      req.type_filling = filling;



      if(OrderSend(req, res))

        {

         closed++;

         remaining = NormalizeDouble(remaining - closeVol, 2);

        }

      else

        {

         failed++;

         Print("PartialClose failed ticket=", tickets[i],

               " vol=", closeVol, " retcode=", res.retcode);

        }

     }



   if(failed == 0)

      SetStatus("Closed " + pctLabel + " (" +

                DoubleToString(toClose - remaining, 2) + " lots)", clrLime);

   else

      SetStatus("Closed " + IntegerToString(closed) +

                " pos, " + IntegerToString(failed) + " failed", WarningColor);



   UpdateAll();

  }



void AddToPosition(double pct)

  {

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);



   // Net position direction and size

   double buyVol = 0, sellVol = 0;

   for(int i = 0; i < PositionsTotal(); i++)

     {

      if(PositionGetSymbol(i) != sym) continue;

      double lots = PositionGetDouble(POSITION_VOLUME);

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(pt == POSITION_TYPE_BUY) buyVol  += lots;

      else                        sellVol += lots;

     }



   double netVol = buyVol - sellVol;

   if(MathAbs(netVol) < 0.00001)

     {

      SetStatus("No position to add to", clrSilver);

      return;

     }



   bool   isLong  = (netVol > 0);



   // Liq distance check — simulate adding the new volume

   {

      double vpp = GetVPP(sym);

      double atr = GetM30ATR();

      if(vpp > 0 && atr > 0)

        {

         double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

         double margin  = AccountInfoDouble(ACCOUNT_MARGIN);

         double soPct   = GetStopOutPercent();

         double addSize = MathAbs(netVol) * pct;

         double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);

         double bid     = SymbolInfoDouble(sym, SYMBOL_BID);

         double mid     = (ask + bid) / 2.0;



         double lotMargin = 0;

         ENUM_ORDER_TYPE addType = isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

         if(!OrderCalcMargin(addType, sym, addSize, isLong ? ask : bid, lotMargin)) lotMargin = 0;



         double newBuy  = isLong  ? (buyVol + addSize) : buyVol;

         double newSell = !isLong ? (sellVol + addSize) : sellVol;

         double newNet  = newBuy - newSell;

         double newMargin = margin + lotMargin;

         double newEqBuf  = equity - (soPct / 100.0) * newMargin;

         double newLiq    = mid - (newEqBuf / (newNet * vpp));



         if(newLiq > 0)

           {

            double liqDistATR = MathAbs(mid - newLiq) / atr;

            if(liqDistATR < MinLiqDistanceATR)

              {

               SetStatus("Add blocked! Liq would be " + DoubleToString(liqDistATR, 2) +

                         " ATRs away (min " + DoubleToString(MinLiqDistanceATR, 1) + ")", WarningColor);

               Alert("ADD BLOCKED on " + sym + " — liq would be " +

                     DoubleToString(liqDistATR, 2) + " ATRs away (min: " +

                     DoubleToString(MinLiqDistanceATR, 1) + ")");

               return;

              }

           }

        }

   }



   double addVol  = MathAbs(netVol) * pct;



   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double lotMin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   double lotMax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   if(lotStep <= 0) lotStep = 0.01;

   addVol = NormalizeDouble(MathFloor(addVol / lotStep) * lotStep, 2);

   addVol = MathMax(addVol, lotMin);

   addVol = MathMin(addVol, lotMax);



   ENUM_ORDER_TYPE orderType = isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;



   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;

   else                                              filling = ORDER_FILLING_RETURN;



   double price = isLong ? SymbolInfoDouble(sym, SYMBOL_ASK)

                         : SymbolInfoDouble(sym, SYMBOL_BID);



   // Step 1: place market order without SL

   MqlTradeRequest req = {};

   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;

   req.symbol       = sym;

   req.volume       = addVol;

   req.type         = orderType;

   req.price        = price;

   req.deviation    = 20;

   req.magic        = 20240101;

   req.comment      = "Add_" + DoubleToString(pct * 100.0, 0) + "%";

   req.type_filling = filling;



   if(!OrderSend(req, res))

     {

      SetStatus("Add failed: " + DecodeRetcode(res.retcode), WarningColor);

      UpdateAll();

      return;

     }



   Sleep(300);



   // Step 2: attach ATR SL to the new position

   double atr     = GetCurrentATR();

   double slDist  = atr * AtrMultiplier;

   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);

   double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);

   double bid     = SymbolInfoDouble(sym, SYMBOL_BID);

   double minStop = MathMax(SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point,

                            (ask - bid) * 2.0);

   if(slDist < minStop) slDist = minStop;



   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      if(PositionGetInteger(POSITION_MAGIC) != 20240101) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(isLong  && pt != POSITION_TYPE_BUY)  continue;

      if(!isLong && pt != POSITION_TYPE_SELL) continue;

      // Pick most recently opened

      if(PositionGetInteger(POSITION_TIME) < (long)TimeCurrent() - 5) continue;



      ulong  ticket    = PositionGetInteger(POSITION_TICKET);

      double fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      double sl = isLong ? NormalizeDouble(fillPrice - slDist, digits)

                         : NormalizeDouble(fillPrice + slDist, digits);



      MqlTradeRequest modReq = {};

      MqlTradeResult  modRes = {};

      modReq.action   = TRADE_ACTION_SLTP;

      modReq.symbol   = sym;

      modReq.position = ticket;

      modReq.sl       = sl;

      modReq.tp       = 0;

      if(!OrderSend(modReq, modRes)) Print("SLTP modify failed: ", modRes.retcode);

      break;

     }



   SetStatus("Added +" + DoubleToString(pct * 100.0, 0) + "% (" +

             DoubleToString(addVol, 2) + " lots) + ATR SL", clrLime);

   UpdateAll();

  }



void ReversePosition()

  {

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);



   // Step 1: record net exposure before closing

   double buyVol = 0, sellVol = 0;

   for(int i = 0; i < PositionsTotal(); i++)

     {

      if(PositionGetSymbol(i) != sym) continue;

      double lots = PositionGetDouble(POSITION_VOLUME);

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(pt == POSITION_TYPE_BUY) buyVol  += lots;

      else                        sellVol += lots;

     }



   double netVol = buyVol - sellVol;

   if(MathAbs(netVol) < 0.00001)

     {

      SetStatus("No net position to reverse", clrSilver);

      return;

     }



   bool wasLong = (netVol > 0);

   double revVol = MathAbs(netVol);



   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;

   else                                              filling = ORDER_FILLING_RETURN;



   // Step 2: close ALL open positions on this symbol

   int closed = 0, failed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      ulong  ticket    = PositionGetInteger(POSITION_TICKET);

      double lots      = PositionGetDouble(POSITION_VOLUME);

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      ENUM_ORDER_TYPE closeType = (pt == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      double closePrice = (closeType == ORDER_TYPE_SELL)

                          ? SymbolInfoDouble(sym, SYMBOL_BID)

                          : SymbolInfoDouble(sym, SYMBOL_ASK);



      MqlTradeRequest cReq = {};

      MqlTradeResult  cRes = {};

      cReq.action       = TRADE_ACTION_DEAL;

      cReq.symbol       = sym;

      cReq.volume       = lots;

      cReq.type         = closeType;

      cReq.price        = closePrice;

      cReq.position     = ticket;

      cReq.deviation    = 20;

      cReq.magic        = 20240101;

      cReq.comment      = "ReverseClose";

      cReq.type_filling = filling;

      if(OrderSend(cReq, cRes)) closed++;

      else                      failed++;

     }



   if(failed > 0)

     {

      SetStatus("Reverse: " + IntegerToString(failed) + " close(s) failed", WarningColor);

      UpdateAll();

      return;

     }



   Sleep(400);



   // Step 3: open new position in opposite direction = same net size

   ENUM_ORDER_TYPE newType = wasLong ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double lotMin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   double lotMax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   if(lotStep <= 0) lotStep = 0.01;

   revVol = NormalizeDouble(MathFloor(revVol / lotStep) * lotStep, 2);

   revVol = MathMax(revVol, lotMin);

   revVol = MathMin(revVol, lotMax);



   double entryPrice = (newType == ORDER_TYPE_SELL)

                       ? SymbolInfoDouble(sym, SYMBOL_BID)

                       : SymbolInfoDouble(sym, SYMBOL_ASK);



   MqlTradeRequest oReq = {};

   MqlTradeResult  oRes = {};

   oReq.action       = TRADE_ACTION_DEAL;

   oReq.symbol       = sym;

   oReq.volume       = revVol;

   oReq.type         = newType;

   oReq.price        = entryPrice;

   oReq.deviation    = 20;

   oReq.magic        = 20240101;

   oReq.comment      = "ReverseOpen";

   oReq.type_filling = filling;



   if(!OrderSend(oReq, oRes))

     {

      SetStatus("Reverse open failed: " + DecodeRetcode(oRes.retcode), WarningColor);

      UpdateAll();

      return;

     }



   Sleep(300);



   // Step 4: attach ATR SL to the new position

   double atr     = GetCurrentATR();

   double slDist  = atr * AtrMultiplier;

   double point   = SymbolInfoDouble(sym, SYMBOL_POINT);

   double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);

   double bid     = SymbolInfoDouble(sym, SYMBOL_BID);

   double minStop = MathMax(SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point,

                            (ask - bid) * 2.0);

   if(slDist < minStop) slDist = minStop;



   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      if(PositionGetInteger(POSITION_MAGIC) != 20240101) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(wasLong  && pt != POSITION_TYPE_SELL) continue;

      if(!wasLong && pt != POSITION_TYPE_BUY)  continue;



      ulong  ticket    = PositionGetInteger(POSITION_TICKET);

      double fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      double sl = !wasLong

                  ? NormalizeDouble(fillPrice - slDist, digits)

                  : NormalizeDouble(fillPrice + slDist, digits);

      double tp = !wasLong

                  ? NormalizeDouble(fillPrice + slDist * 3.0, digits)

                  : NormalizeDouble(fillPrice - slDist * 3.0, digits);



      MqlTradeRequest modReq = {};

      MqlTradeResult  modRes = {};

      modReq.action   = TRADE_ACTION_SLTP;

      modReq.symbol   = sym;

      modReq.position = ticket;

      modReq.sl       = sl;

      modReq.tp       = tp;

      if(!OrderSend(modReq, modRes))

         Print("ReversePosition SL/TP modify failed: ", modRes.retcode);

      break;

     }



   string dir = wasLong ? "SHORT" : "LONG";

   SetStatus("Reversed to " + dir + " " + DoubleToString(revVol, 2) + " lots + ATR SL/TP", clrLime);

   UpdateAll();

  }



void FlattenAll()

  {

   string sym        = _Symbol;

   bool   hasPending = false;

   bool   hasPos     = false;

   double buyVol = 0, sellVol = 0;



   for(int i = 0; i < OrdersTotal(); i++)

     {

      ulong ticket = OrderGetTicket(i);

      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == sym) hasPending = true;

     }

   for(int i = 0; i < PositionsTotal(); i++)

     {

      if(PositionGetSymbol(i) == sym)

        {

         hasPos = true;

         double lots = PositionGetDouble(POSITION_VOLUME);

         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyVol += lots;

         else sellVol += lots;

        }

     }

     

   bool isFullyHedged = (buyVol > 0 && sellVol > 0 && MathAbs(buyVol - sellVol) < 0.00001);

   bool doClosePos    = (g_FlattenArmed || isFullyHedged || !hasPending);



   int cancelled = 0, cancelFailed = 0;



   // Always cancel pending orders if we are proceeding

   if(hasPending)

     {

      for(int i = OrdersTotal() - 1; i >= 0; i--)

        {

         ulong ticket = OrderGetTicket(i);

         if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != sym) continue;

         MqlTradeRequest req = {};

         MqlTradeResult  res = {};

         req.action = TRADE_ACTION_REMOVE;

         req.order  = ticket;

         if(OrderSend(req, res)) cancelled++;

         else                    cancelFailed++;

        }

     }



   if(hasPos && !doClosePos)

     {

      g_FlattenArmed = true;

      if(ObjectFind(0, P_FLAT_BTN) >= 0)

        {

         ObjectSetString (0, P_FLAT_BTN, OBJPROP_TEXT,   "PRESS AGAIN TO CLOSE TRADES");

         ObjectSetInteger(0, P_FLAT_BTN, OBJPROP_BGCOLOR, C'200,20,20');

        }

      string msg2 = "Cancelled " + IntegerToString(cancelled) + " order(s) — press again to close positions";

      SetStatus(msg2, clrOrange);

      UpdateAll();

      return;

     }



   if(!hasPos && hasPending)

     {

      g_FlattenArmed = false;

      ResetFlattenButton();

      string msg2 = "Cancelled " + IntegerToString(cancelled) + " order(s)";

      if(cancelFailed > 0) msg2 += " (" + IntegerToString(cancelFailed) + " failed)";

      SetStatus(msg2, cancelFailed > 0 ? WarningColor : clrLime);

      UpdateAll();

      return;

     }



   // ── SECOND PRESS (or no pending orders): close all positions ──

   g_FlattenArmed = false;

   ResetFlattenButton();

   // Reset hedge session when fully flattened

   g_HedgeSessionActive = false;

   g_HedgeSessionPnL    = 0;

   // Clean up trail line immediately — no positions = no trail

   g_TrailActive = false;

   g_TrailStop   = 0;

   DeleteTrailLine();

   UpdateTrailButton();



   if(!hasPos)

     {

      SetStatus("Nothing to flatten", clrSilver);

      UpdateAll();

      return;

     }



   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;

   else                                              filling = ORDER_FILLING_RETURN;



   int closed = 0, failed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      ulong  ticket   = PositionGetInteger(POSITION_TICKET);

      double lots     = PositionGetDouble(POSITION_VOLUME);

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      ENUM_ORDER_TYPE closeType  = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      double closePrice          = (closeType == ORDER_TYPE_SELL)

                                   ? SymbolInfoDouble(sym, SYMBOL_BID)

                                   : SymbolInfoDouble(sym, SYMBOL_ASK);

      MqlTradeRequest req = {};

      MqlTradeResult  res = {};

      req.action       = TRADE_ACTION_DEAL;

      req.symbol       = sym;

      req.volume       = lots;

      req.type         = closeType;

      req.price        = closePrice;

      req.position     = ticket;

      req.deviation    = 20;

      req.magic        = 20240101;

      req.comment      = "Flatten";

      req.type_filling = filling;

      if(OrderSend(req, res)) closed++;

      else                    failed++;

     }



   string msg = "Closed " + IntegerToString(closed) + " position(s)";

   if(failed > 0) msg += " (" + IntegerToString(failed) + " failed)";

   SetStatus(msg, failed > 0 ? WarningColor : clrLime);

   UpdateAll();

  }



void ResetFlattenButton()

  {

   if(ObjectFind(0, P_FLAT_BTN) >= 0)

     {

      ObjectSetString (0, P_FLAT_BTN, OBJPROP_TEXT,   "FLATTEN ALL");

      ObjectSetInteger(0, P_FLAT_BTN, OBJPROP_BGCOLOR, C'120,20,20');

     }

  }



void ShiftZoneOrders(int direction) // +1 = up, -1 = down

  {

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);



   // Step size = ATR * 1.5 / 3 (same increment used when placing)

   double step = (GetCurrentATR() * 1.5) / 3.0;

   double shift = step * direction;



   int moved = 0, failed = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)

     {

      ulong ticket = OrderGetTicket(i);

      if(ticket == 0) continue;

      if(OrderGetString(ORDER_SYMBOL) != sym) continue;

      if(OrderGetInteger(ORDER_MAGIC) != 20240101) continue;



      double oldPrice = OrderGetDouble(ORDER_PRICE_OPEN);

      double oldSL    = OrderGetDouble(ORDER_SL);

      double oldTP    = OrderGetDouble(ORDER_TP);

      double newPrice = NormalizeDouble(oldPrice + shift, digits);



      // Always shift SL by the same distance as the price — that's the whole point

      double newSL = (oldSL > 0)

                     ? NormalizeDouble(oldSL + shift, digits)

                     : 0;

      double newTP = (oldTP > 0)

                     ? NormalizeDouble(oldTP + shift, digits)

                     : 0;



      MqlTradeRequest req = {};

      MqlTradeResult  res = {};

      req.action   = TRADE_ACTION_MODIFY;

      req.symbol   = sym;

      req.order    = ticket;

      req.price    = newPrice;

      req.sl       = newSL;

      req.tp       = newTP;

      req.type_time= ORDER_TIME_GTC;



      if(OrderSend(req, res)) moved++;

      else

        {

         failed++;

         Print("ShiftZone failed ticket=", ticket,

               " retcode=", res.retcode,

               " price=", newPrice, " sl=", newSL);

        }

     }



   if(moved == 0 && failed == 0)

     {

      // No pending orders — shift SL of open positions instead

      double point   = SymbolInfoDouble(sym, SYMBOL_POINT);

      double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);

      double bid     = SymbolInfoDouble(sym, SYMBOL_BID);

      double minStop = MathMax(SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point,

                               (ask - bid) * 2.0);

      int slMoved = 0, slFailed = 0, slSkipped = 0;



      for(int i = PositionsTotal() - 1; i >= 0; i--)

        {

         if(PositionGetSymbol(i) != sym) continue;

         double oldSL = PositionGetDouble(POSITION_SL);

         if(oldSL == 0) { slSkipped++; continue; }  // no SL to shift



         double tp      = PositionGetDouble(POSITION_TP);

         ulong  ticket  = PositionGetInteger(POSITION_TICKET);

         double newSL   = NormalizeDouble(oldSL + shift, digits);



         // Enforce broker minimum stop distance from current price

         ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         double ref = (pt == POSITION_TYPE_BUY) ? bid : ask;

         if(pt == POSITION_TYPE_BUY  && newSL > ref - minStop) newSL = NormalizeDouble(ref - minStop, digits);

         if(pt == POSITION_TYPE_SELL && newSL < ref + minStop) newSL = NormalizeDouble(ref + minStop, digits);



         MqlTradeRequest req = {};

         MqlTradeResult  res = {};

         req.action   = TRADE_ACTION_SLTP;

         req.symbol   = sym;

         req.position = ticket;

         req.sl       = newSL;

         req.tp       = tp;

         if(OrderSendAsync(req, res)) slMoved++;

         else                       slFailed++;

        }



      string dir = (direction > 0 ? "up" : "down");

      if(slMoved == 0 && slFailed == 0)

         SetStatus("No orders or SLs to shift", clrSilver);

      else if(slSkipped > 0 && slMoved == 0)

         SetStatus("Positions have no SL to shift", clrSilver);

      else if(slFailed == 0)

         SetStatus("SL shifted " + dir + " on " + IntegerToString(slMoved) + " position(s)", clrLime);

      else

         SetStatus("SL shift: " + IntegerToString(slMoved) + " OK, " +

                   IntegerToString(slFailed) + " failed", WarningColor);

     }

   else if(failed == 0)

      SetStatus("Shifted " + IntegerToString(moved) + " order(s) " +

                (direction > 0 ? "up" : "down") + " by " +

                DoubleToString(step, digits), clrLime);

   else

      SetStatus("Shifted " + IntegerToString(moved) + ", failed: " +

                IntegerToString(failed), WarningColor);



   UpdateAll();

  }



void PlaceZoneOrders(ENUM_ORDER_TYPE limitType)

  {

   if(!ValidateZoneLotSize(limitType)) return;

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);

   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);

   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);



   bool   isBuy  = (limitType == ORDER_TYPE_BUY_LIMIT);

   double refPrice = isBuy ? bid : ask; // anchor to current market



   // Zone = ATR * 1.5, split into 3 equal steps

   double atr      = GetCurrentATR();

   double zone     = atr * 1.5;

   double step     = zone / 3.0;       // distance between each limit order

   int    orders   = 3;



   // Each order gets 1/3 of total lot, rounded down to lot step

   double lotStep  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double lotMin   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   if(lotStep <= 0) lotStep = 0.01;

   double lotEach  = NormalizeDouble(MathFloor((g_LotSize / orders) / lotStep) * lotStep, 2);

   if(lotEach < lotMin) lotEach = lotMin;



   // Broker min stop distance

   double minStop = MathMax(

      SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point,

      (ask - bid) * 2.0);



   int placed = 0, failed = 0;

   for(int i = 0; i < orders; i++)

     {

      // Buy limits go below bid, sell limits go above ask, each step further

      double offset = step * (i + 1);

      double price  = isBuy

                      ? NormalizeDouble(refPrice - offset, digits)

                      : NormalizeDouble(refPrice + offset, digits);



      // ATR-based SL + TP (3x SL) on each limit order

      double slDist = GetCurrentATR() * AtrMultiplier;

      if(slDist < minStop) slDist = minStop;

      double tpDist = slDist * 3.0;

      double sl = isBuy

                  ? NormalizeDouble(price - slDist, digits)

                  : NormalizeDouble(price + slDist, digits);

      double tp = isBuy

                  ? NormalizeDouble(price + tpDist, digits)

                  : NormalizeDouble(price - tpDist, digits);



      MqlTradeRequest req = {};

      MqlTradeResult  res = {};

      req.action       = TRADE_ACTION_PENDING;

      req.symbol       = sym;

      req.volume       = lotEach;

      req.type         = limitType;

      req.price        = price;

      req.sl           = sl;

      req.tp           = tp;

      req.deviation    = 20;

      req.magic        = 20240101;

      req.comment      = "Zone_" + IntegerToString(i + 1) + "/3";

      req.type_filling = ORDER_FILLING_RETURN; // pending orders always use RETURN



      if(OrderSend(req, res))
        {
         placed++;
         // Immediately draw P&L labels for this zone limit order
         if(res.order > 0)
            DrawOrderPnlLabels(res.order, price, sl, tp, lotEach, isBuy, sym);
        }
      else

        {

         failed++;

         Print("Zone order ", i+1, " failed: ", DecodeRetcode(res.retcode),

               " price=", price, " sl=", sl);

        }

     }



   if(failed == 0)

      SetStatus("Zone: " + IntegerToString(placed) + " limits placed (" +

                DoubleToString(lotEach, 2) + " lots each)", clrLime);

   else

      SetStatus("Zone: " + IntegerToString(placed) + " OK, " +

                IntegerToString(failed) + " failed", WarningColor);



   UpdateAll();

  }



void PlaceTrade(ENUM_ORDER_TYPE orderType)

  {

   // Snap to recommended lot if USE REC is active

   if(g_UseRecLot)

     {

      double recAtr = GetCurrentATR();

      double recVpp = GetVPP(_Symbol);

      if(recAtr > 0 && recVpp > 0)

        {

         double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

         double slDist  = recAtr * AtrMultiplier;

         double riskAmt = equity * 0.01;

         double slMoney = slDist * recVpp;

         double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

         if(lotStep <= 0) lotStep = 0.01;

         double recLots = (slMoney > 0) ? riskAmt / slMoney : g_LotSize;

         recLots = NormalizeDouble(MathFloor(recLots / lotStep) * lotStep, 2);

         recLots = MathMax(recLots, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

         recLots = MathMin(recLots, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));

         g_LotSize = recLots;

        }

     }

   if(!ValidateLotSize(orderType)) return;



   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);

   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);

   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);

   double entryPrice = (orderType == ORDER_TYPE_BUY) ? ask : bid;



   // --- Detect broker filling mode ---

   ENUM_ORDER_TYPE_FILLING filling = ORDER_FILLING_IOC;

   int fillingMode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      filling = ORDER_FILLING_FOK;

   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) filling = ORDER_FILLING_IOC;

   else                                              filling = ORDER_FILLING_RETURN;



   // --- STEP 1: Place the market order WITHOUT SL ---

   MqlTradeRequest req = {};

   MqlTradeResult  res = {};

   req.action       = TRADE_ACTION_DEAL;

   req.symbol       = sym;

   req.volume       = g_LotSize;

   req.type         = orderType;

   req.price        = entryPrice;

   req.deviation    = 20;

   req.magic        = 20240101;

   req.comment      = "TT_ATRx" + DoubleToString(AtrMultiplier, 1);

   req.type_filling = filling;



   // Diagnostic: check if trading is actually allowed

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))

     { SetStatus("Terminal AutoTrading is OFF - click the button in the toolbar", WarningColor); return; }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))

     { SetStatus("EA trade permission denied - check EA properties > Allow Algo Trading", WarningColor); return; }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))

     { SetStatus("Account trading disabled by broker", WarningColor); return; }

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))

     { SetStatus("Broker does not allow EA trading on this account", WarningColor); return; }



   if(!OrderSend(req, res))

     {

      string errMsg = DecodeRetcode(res.retcode);

      Print("PlaceTrade OrderSend failed: retcode=", res.retcode, " (", errMsg, ")",

            " terminal_trade=", TerminalInfoInteger(TERMINAL_TRADE_ALLOWED),

            " mql_trade=", MQLInfoInteger(MQL_TRADE_ALLOWED),

            " type=", orderType, " vol=", g_LotSize, " price=", entryPrice);

      SetStatus("Failed: " + errMsg, WarningColor);

      return;

     }



   // --- STEP 2: Find the opened position and set SL via SLTP modify ---

   Sleep(300); // brief wait for position to register



   double atr        = GetCurrentATR();

   double slDistance = atr * AtrMultiplier;



   // Enforce broker minimum stop distance

   long   stopLevelPts = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);

   double minStopDist  = MathMax(stopLevelPts * point, (ask - bid) * 2.0);

   if(slDistance < minStopDist) slDistance = minStopDist;



   // Find our position by magic number

   ulong ticket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      if(PositionGetInteger(POSITION_MAGIC) != 20240101) continue;

      // Pick the most recently opened one

      if(PositionGetInteger(POSITION_TIME) >= (long)TimeCurrent() - 5)

        {

         ticket = PositionGetInteger(POSITION_TICKET);

         break;

        }

     }



   if(ticket == 0)

     {

      // Fallback: just grab any position on this symbol with our magic

      for(int i = 0; i < PositionsTotal(); i++)

        {

         if(PositionGetSymbol(i) == sym &&

            PositionGetInteger(POSITION_MAGIC) == 20240101)

           {

            ticket = PositionGetInteger(POSITION_TICKET);

            break;

           }

        }

     }



   if(ticket == 0)

     {

      SetStatus("Order OK but position not found for SL", clrOrange);

      UpdateAll();

      return;

     }



   // Get actual fill price from position

   PositionSelectByTicket(ticket);

   double fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);



   double slPrice = (posType == POSITION_TYPE_BUY)

                    ? NormalizeDouble(fillPrice - slDistance, digits)

                    : NormalizeDouble(fillPrice + slDistance, digits);

   double tpPrice = (posType == POSITION_TYPE_BUY)

                    ? NormalizeDouble(fillPrice + slDistance * 3.0, digits)

                    : NormalizeDouble(fillPrice - slDistance * 3.0, digits);



   MqlTradeRequest modReq = {};

   MqlTradeResult  modRes = {};

   modReq.action   = TRADE_ACTION_SLTP;

   modReq.symbol   = sym;

   modReq.position = ticket;

   modReq.sl       = slPrice;

   modReq.tp       = tpPrice;



   if(!OrderSend(modReq, modRes))

     {

      SetStatus("Order OK, SL/TP failed (" + DecodeRetcode(modRes.retcode) +

                ") SL=" + DoubleToString(slPrice, digits), clrOrange);

     }

   else

     {

      SetStatus("OK @ " + DoubleToString(fillPrice, digits) +

                "  SL: " + DoubleToString(slPrice, digits) +

                "  TP: " + DoubleToString(tpPrice, digits), clrLime);

     }



   UpdateAll();

  }



//+------------------------------------------------------------------+

string DecodeRetcode(int code)

  {

   switch(code)

     {

      case 10004: return "Requote";

      case 10006: return "Rejected";

      case 10007: return "Cancelled";

      case 10010: return "Placed (partial)";

      case 10014: return "Invalid volume";

      case 10015: return "Invalid price";

      case 10016: return "Invalid stops";

      case 10018: return "Market closed";

      case 10019: return "No money";

      case 10024: return "Too many orders";

      case 10030: return "Filling unsupported";

      default:    return "Code " + IntegerToString(code);

     }

  }



//+------------------------------------------------------------------+

bool ValidateZoneLotSize(ENUM_ORDER_TYPE limitType)

  {

   double vpp = GetVPP(_Symbol);

   if(vpp <= 0) return true;



   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   double margin = AccountInfoDouble(ACCOUNT_MARGIN);

   double soPct  = GetStopOutPercent();

   double atr    = GetM30ATR();

   if(atr <= 0) return true;



   bool   isBuy  = (limitType == ORDER_TYPE_BUY_LIMIT);

   double buyVol = 0, sellVol = 0;



   for(int i = 0; i < PositionsTotal(); i++)

     {

      if(PositionGetSymbol(i) != _Symbol) continue;

      double lots = PositionGetDouble(POSITION_VOLUME);

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(pt == POSITION_TYPE_BUY) buyVol  += lots;

      else                        sellVol += lots;

     }



   if(isBuy) buyVol  += g_LotSize;

   else      sellVol += g_LotSize;



   double newNet = buyVol - sellVol;

   if(MathAbs(newNet) < 0.00001) return true;



   ENUM_ORDER_TYPE mktType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double lotMargin = 0;

   if(!OrderCalcMargin(mktType, _Symbol, g_LotSize,

      isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)

            : SymbolInfoDouble(_Symbol, SYMBOL_BID), lotMargin))

      lotMargin = 0;



   double newMargin = margin + lotMargin;

   double newEqBuf  = equity - (soPct / 100.0) * newMargin;

   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double mid       = (ask + bid) / 2.0;

   double newLiq    = mid - (newEqBuf / (newNet * vpp));

   if(newLiq <= 0) return true;



   double liqDistATR = MathAbs(mid - newLiq) / GetM30ATR();



   if(liqDistATR < MinLiqDistanceATR)

     {

      string dir = isBuy ? "ZONE BUY" : "ZONE SELL";

      SetStatus(dir + " blocked! Liq " + DoubleToString(liqDistATR, 2) +

                " ATRs away (min " + DoubleToString(MinLiqDistanceATR, 1) + ")",

                WarningColor);

      Alert("ZONE BLOCKED: " + dir + " " + DoubleToString(g_LotSize, 2) +

            " lots on " + _Symbol + " — liq would be " +

            DoubleToString(liqDistATR, 2) + " ATRs away (min: " +

            DoubleToString(MinLiqDistanceATR, 1) + ")");

      return false;

     }

   return true;

  }



bool ValidateLotSize(ENUM_ORDER_TYPE orderType)

  {

   double vpp = GetVPP(_Symbol);

   if(vpp <= 0) return true;



   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   double margin = AccountInfoDouble(ACCOUNT_MARGIN);

   double soPct  = GetStopOutPercent();

   double atr    = GetM30ATR();

   if(atr <= 0) return true;



   double buyVol = 0, sellVol = 0;

   for(int i = 0; i < PositionsTotal(); i++)

     {

      if(PositionGetSymbol(i) != _Symbol) continue;

      double lots = PositionGetDouble(POSITION_VOLUME);

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(pt == POSITION_TYPE_BUY) buyVol  += lots;

      else                        sellVol += lots;

     }



   if(orderType == ORDER_TYPE_BUY)  buyVol  += g_LotSize;

   else                              sellVol += g_LotSize;



   double newNet = buyVol - sellVol;

   if(MathAbs(newNet) < 0.00001) return true;



   double lotMargin = 0;

   if(!OrderCalcMargin(orderType, _Symbol, g_LotSize,

      (orderType == ORDER_TYPE_BUY)

         ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)

         : SymbolInfoDouble(_Symbol, SYMBOL_BID), lotMargin))

      lotMargin = 0;



   double newMargin  = margin + lotMargin;

   double newEqBuf   = equity - (soPct / 100.0) * newMargin;

   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double mid        = (ask + bid) / 2.0;

   double newLiq     = mid - (newEqBuf / (newNet * vpp));

   if(newLiq <= 0) return true;



   // ATR-relative distance check

   double liqDistATR = MathAbs(mid - newLiq) / GetM30ATR();



   if(liqDistATR < MinLiqDistanceATR)

     {

      string dir = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";

      SetStatus(dir + " blocked! Liq " + DoubleToString(liqDistATR, 2) +

                " ATRs away (min " + DoubleToString(MinLiqDistanceATR, 1) + ")",

                WarningColor);

      Alert("TRADE BLOCKED: " + dir + " " + DoubleToString(g_LotSize, 2) +

            " lots on " + _Symbol + " — liq would be " +

            DoubleToString(liqDistATR, 2) + " ATRs away (min: " +

            DoubleToString(MinLiqDistanceATR, 1) + ")");

      return false;

     }

   return true;

  }



//+------------------------------------------------------------------+

void DeleteAll()

  {

   HideContextMenu();

   string prefixes[] = { LIQ_LINE, LIQ_LABEL, RISK_LINE, RISK_LABEL, BE_LINE, BE_LABEL,

                         BE_LOCKED, WARN_PRE, INFO_PRE,

                         P_BG, P_TITLE, P_LOTS_LBL, P_LOTS_EDIT,

                         P_LOTS_UP, P_LOTS_DN, P_BUY_BTN, P_SELL_BTN,

                         P_RISK_LBL, P_STATUS, P_ATR_LBL, P_FLAT_BTN,

                         P_ZBUY_BTN, P_ZSELL_BTN, P_ZONE_LBL,

                         P_ZONE_UP, P_ZONE_DN,

                         P_HEDGE_LBL, P_HDG_1, P_HDG_2, P_HDG_3, P_HDG_4, P_CHDG_BTN,

                         P_CLOSE_LBL, P_CLS_1, P_CLS_2, P_CLS_3, P_CLS_4,

                         P_REC_LBL, P_USE_REC, P_HIST_BTN, P_TRAIL_BTN, P_REV_BTN,

                         P_ADD_LBL, P_ADD_1, P_ADD_2, P_ADD_3, P_ADD_4 };

   int total = ObjectsTotal(0);

   for(int i = total - 1; i >= 0; i--)

     {

      string name = ObjectName(0, i);

      for(int p = 0; p < ArraySize(prefixes); p++)

         if(StringFind(name, prefixes[p]) == 0)

           { ObjectDelete(0, name); break; }

     }

  }



//+------------------------------------------------------------------+

void DrawHLine(string lineName, string labelName, double price,

               color lineColor, string labelText, int digits, string tooltip)

  {

   // ── LINE: create once, update price in-place ─────────────────────

   if(ObjectFind(0, lineName) < 0)

     {

      ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, price);

      ObjectSetInteger(0, lineName, OBJPROP_WIDTH,      LineWidth);

      ObjectSetInteger(0, lineName, OBJPROP_STYLE,      STYLE_SOLID);

      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);

      ObjectSetInteger(0, lineName, OBJPROP_HIDDEN,     true);

     }

   ObjectSetDouble (0, lineName, OBJPROP_PRICE,   price);

   ObjectSetInteger(0, lineName, OBJPROP_COLOR,   lineColor);

   ObjectSetString (0, lineName, OBJPROP_TOOLTIP, tooltip);



   // ── LABEL: create once, update text + price in-place ─────────────

   datetime labelTime = (datetime)(TimeCurrent() + PeriodSeconds() * 5);

   if(ObjectFind(0, labelName) < 0)

     {

      ObjectCreate(0, labelName, OBJ_TEXT, 0, labelTime, price);

      ObjectSetString (0, labelName, OBJPROP_FONT,       "Arial");

      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR,     ANCHOR_LEFT);

      ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);

      ObjectSetInteger(0, labelName, OBJPROP_HIDDEN,     true);

     }

   ObjectSetDouble (0, labelName, OBJPROP_PRICE, price);

   ObjectSetString (0, labelName, OBJPROP_TEXT,  labelText);

   ObjectSetInteger(0, labelName, OBJPROP_COLOR, lineColor);

  }



// Top-left corner label (for big warnings)

void DrawTopLeftLabel(string name, string text, color clr, int yd, int fs)

  {

   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  10);

   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  yd);

   ObjectSetString (0, name, OBJPROP_TEXT,        text);

   ObjectSetInteger(0, name, OBJPROP_COLOR,       clr);

   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,    fs);

   ObjectSetString (0, name, OBJPROP_FONT,        "Arial Bold");

   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);

  }



// Bottom-left corner label (for panel-adjacent messages)

void DrawBottomLeftLabel(string name, string text, color clr, int xd, int yd, int fs)

  {

   if(ObjectFind(0, name) < 0)

     {

      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_LOWER);

      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  xd);

      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  yd);

      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   fs);

      ObjectSetString (0, name, OBJPROP_FONT,       "Arial Bold");

      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

     }

   ObjectSetString (0, name, OBJPROP_TEXT,  text);

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);

  }



double GetStopOutPercent()

  {

   if(StopOutLevelOverride > 0.0) return StopOutLevelOverride;

   ENUM_ACCOUNT_STOPOUT_MODE soMode  = (ENUM_ACCOUNT_STOPOUT_MODE)AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE);

   double                    soValue = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);

   double                    margin  = AccountInfoDouble(ACCOUNT_MARGIN);

   if(soMode == ACCOUNT_STOPOUT_MODE_PERCENT) return soValue;

   if(margin > 0) return (soValue / margin) * 100.0;

   return 50.0;

  }



//+------------------------------------------------------------------+

void BuildPanel()

  {

   int baseY = PAN_Y + PAN_H; // distance from bottom to top of panel



   // Background

   ObjectCreate(0, P_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, P_BG, OBJPROP_CORNER,      CORNER_LEFT_LOWER);

   ObjectSetInteger(0, P_BG, OBJPROP_XDISTANCE,   PAN_X);

   ObjectSetInteger(0, P_BG, OBJPROP_YDISTANCE,   PAN_Y);

   ObjectSetInteger(0, P_BG, OBJPROP_XSIZE,       PAN_W);

   ObjectSetInteger(0, P_BG, OBJPROP_YSIZE,       PAN_H);

   ObjectSetInteger(0, P_BG, OBJPROP_BGCOLOR,     PanelBgColor);

   ObjectSetInteger(0, P_BG, OBJPROP_BORDER_TYPE, BORDER_FLAT);

   ObjectSetInteger(0, P_BG, OBJPROP_WIDTH,       2);

   ObjectSetInteger(0, P_BG, OBJPROP_COLOR,       C'100,115,130');

   ObjectSetInteger(0, P_BG, OBJPROP_SELECTABLE,  false);



   // Title

   MakeLabel(P_TITLE, "  ThothTrader Panel",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 14, clrWhite, 8);



   // Lot size label

   MakeLabel(P_LOTS_LBL, "  Lot Size:",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 38, clrSilver, 8);



   // Edit box

   ObjectCreate(0, P_LOTS_EDIT, OBJ_EDIT, 0, 0, 0);

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_CORNER,       CORNER_LEFT_LOWER);



   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_XDISTANCE,    PAN_X + 80);

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_YDISTANCE,    baseY - 58);

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_XSIZE,        60);

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_YSIZE,        22);

   ObjectSetString (0, P_LOTS_EDIT, OBJPROP_TEXT,         DoubleToString(g_LotSize, 2));

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_COLOR,        clrWhite);

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_BGCOLOR,      C'50,50,50');

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_BORDER_COLOR, C'90,90,90');

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_FONTSIZE,     9);

   ObjectSetString (0, P_LOTS_EDIT, OBJPROP_FONT,         "Arial Bold");

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_ALIGN,        ALIGN_CENTER);

   ObjectSetInteger(0, P_LOTS_EDIT, OBJPROP_SELECTABLE,   false);

   // Minus button

   MakeButton(P_LOTS_DN, " -",

              CORNER_LEFT_LOWER, PAN_X + 148, baseY - 58,

              36, 22, C'80,88,96', clrWhite, 11);



   // Plus button

   MakeButton(P_LOTS_UP, " +",

              CORNER_LEFT_LOWER, PAN_X + 188, baseY - 58,

              36, 22, C'80,88,96', clrWhite, 11);



   // Recommended lot size

   MakeLabel(P_REC_LBL, "  Rec: --",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 100, C'120,170,120', 7);

   MakeButton(P_HIST_BTN, "HISTORY",

              CORNER_LEFT_LOWER, PAN_X + 168, baseY - 100,

              54, 16, C'40,55,65', C'120,200,220', 7);

   MakeButton(P_USE_REC, "USE REC",

              CORNER_LEFT_LOWER, PAN_X + 168, baseY - 84,

              54, 16, C'55,70,55', C'160,230,160', 7);



   // ATR SL info label

   MakeLabel(P_ATR_LBL, "  SL: ATR x" + DoubleToString(AtrMultiplier, 1) + " = --  |  Zone: ATR x1.5",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 84, clrSilver, 7);



   // BUY button

   MakeButton(P_BUY_BTN, "   BUY",

              CORNER_LEFT_LOWER, PAN_X + 8, baseY - 118,

              100, 36, BuyBtnColor, clrWhite, 11);



   // SELL button

   MakeButton(P_SELL_BTN, "   SELL",

              CORNER_LEFT_LOWER, PAN_X + 116, baseY - 118,

              106, 36, SellBtnColor, clrWhite, 11);



   // Zone label

   MakeLabel(P_ZONE_LBL, "  Zone (3x limits, ATR x1.5):",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 162, C'150,150,150', 7);



   // Zone BUY limit button

   MakeButton(P_ZBUY_BTN, "  ZONE BUY",

              CORNER_LEFT_LOWER, PAN_X + 8, baseY - 160,

              105, 28, C'0,130,0', clrWhite, 9);



   // Zone SELL limit button

   MakeButton(P_ZSELL_BTN, "  ZONE SELL",

              CORNER_LEFT_LOWER, PAN_X + 119, baseY - 160,

              105, 28, C'170,0,0', clrWhite, 9);



   // Zone shift UP arrow — left half, below zone buttons

   MakeButton(P_ZONE_UP, "  \x25B2  Shift Up",

              CORNER_LEFT_LOWER, PAN_X + 8, baseY - 192,

              105, 24, C'70,80,110', clrWhite, 8);



   // Zone shift DOWN arrow — right half, below zone buttons

   MakeButton(P_ZONE_DN, "  \x25BC  Shift Down",

              CORNER_LEFT_LOWER, PAN_X + 119, baseY - 192,

              105, 24, C'70,80,110', clrWhite, 8);





   // ADD label + buttons

   MakeLabel(P_ADD_LBL, "Add to position (net size x):",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 215, C'160,200,80', 8);

   MakeButton(P_ADD_1, "+50%",

              CORNER_LEFT_LOWER, PAN_X + 8,   baseY - 245,

              50, 26, C'65,105,25', clrWhite, 9);

   MakeButton(P_ADD_2, "+100%",

              CORNER_LEFT_LOWER, PAN_X + 62,  baseY - 245,

              50, 26, C'65,105,25', clrWhite, 9);

   MakeButton(P_ADD_3, "+150%",

              CORNER_LEFT_LOWER, PAN_X + 116, baseY - 245,

              50, 26, C'65,105,25', clrWhite, 9);

   MakeButton(P_ADD_4, "+200%",

              CORNER_LEFT_LOWER, PAN_X + 170, baseY - 245,

              52, 26, C'55,90,18', clrWhite, 9);



   // HEDGE label + buttons

   MakeLabel(P_HEDGE_LBL, "Hedge (net exposure):",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 267, C'100,150,220', 8);

   MakeButton(P_CHDG_BTN, "close hedges",

              CORNER_LEFT_LOWER, PAN_X + 128, baseY - 283,

              94, 16, C'30,60,110', C'140,190,255', 7);

   MakeButton(P_HDG_1, "1/3",

              CORNER_LEFT_LOWER, PAN_X + 8,   baseY - 300,

              50, 26, C'40,80,160', clrWhite, 9);

   MakeButton(P_HDG_2, "1/2",

              CORNER_LEFT_LOWER, PAN_X + 62,  baseY - 300,

              50, 26, C'40,80,160', clrWhite, 9);

   MakeButton(P_HDG_3, "80%",

              CORNER_LEFT_LOWER, PAN_X + 116, baseY - 300,

              50, 26, C'40,80,160', clrWhite, 9);

   MakeButton(P_HDG_4, "Full",

              CORNER_LEFT_LOWER, PAN_X + 170, baseY - 300,

              52, 26, C'30,60,140', clrWhite, 9);



   // CLOSE label + buttons

   MakeLabel(P_CLOSE_LBL, "Partial close (gross):",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 322, C'220,100,100', 8);

   MakeButton(P_CLS_1, "1/3",

              CORNER_LEFT_LOWER, PAN_X + 8,   baseY - 352,

              50, 26, C'150,35,35', clrWhite, 9);

   MakeButton(P_CLS_2, "1/2",

              CORNER_LEFT_LOWER, PAN_X + 62,  baseY - 352,

              50, 26, C'150,35,35', clrWhite, 9);

   MakeButton(P_CLS_3, "80%",

              CORNER_LEFT_LOWER, PAN_X + 116, baseY - 352,

              50, 26, C'150,35,35', clrWhite, 9);

   MakeButton(P_CLS_4, "Full",

              CORNER_LEFT_LOWER, PAN_X + 170, baseY - 352,

              52, 26, C'130,25,25', clrWhite, 9);



   // Smart Trail — full width, below close section

   MakeButton(P_TRAIL_BTN, "SMART TRAIL  OFF",

              CORNER_LEFT_LOWER, PAN_X + 8, baseY - 380,

              PAN_W - 16, 28, C'50,55,60', C'0,210,210', 9);



   // Risk line (just above panel top edge)

   // This is drawn dynamically, see UpdateAll



   // Status line — space prevents MT5 rendering "Label" placeholder

   MakeLabel(P_STATUS, " ",

             CORNER_LEFT_LOWER, PAN_X + 8, baseY - 136, clrSilver, 7);



   // Risk label — just above the FLATTEN ALL button (button top = PAN_Y + 30 = 60px from bottom)

   MakeLabel(P_RISK_LBL, " ",

             CORNER_LEFT_LOWER, PAN_X + 8, 63, clrSilver, 7);



   // Reverse button — left half of bottom row

   MakeButton(P_REV_BTN, "REVERSE",

              CORNER_LEFT_LOWER, PAN_X + 8, PAN_Y,

              105, 30, C'110,55,0', clrWhite, 9);



   // Flatten All button — right half of bottom row

   MakeButton(P_FLAT_BTN, "FLATTEN ALL",

              CORNER_LEFT_LOWER, PAN_X + 117, PAN_Y,

              105, 30, C'160,25,25', clrWhite, 9);

  }



//+------------------------------------------------------------------+

void MakeLabel(string name, string text, ENUM_BASE_CORNER corner,

               int xd, int yd, color clr, int fs)

  {

   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,     corner);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  xd);

   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  yd);

   ObjectSetString (0, name, OBJPROP_TEXT,        text);

   ObjectSetInteger(0, name, OBJPROP_COLOR,       clr);

   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   fs);

   ObjectSetString (0, name, OBJPROP_FONT,       "Arial Bold");

   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

  }



//+------------------------------------------------------------------+

void RemoveAllSL()

  {

   // Strip SL from every position on this symbol — called when fully hedged (netVol = 0)

   string sym    = _Symbol;

   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   int    modified = 0;



   for(int i = PositionsTotal() - 1; i >= 0; i--)

     {

      if(PositionGetSymbol(i) != sym) continue;

      double sl = PositionGetDouble(POSITION_SL);

      if(sl == 0) continue; // already no SL



      ulong  ticket = PositionGetInteger(POSITION_TICKET);

      double tp     = PositionGetDouble(POSITION_TP);



      MqlTradeRequest req = {};

      MqlTradeResult  res = {};

      req.action   = TRADE_ACTION_SLTP;

      req.symbol   = sym;

      req.position = ticket;

      req.sl       = 0;

      req.tp       = tp;

      if(OrderSend(req, res)) modified++;

     }



   if(modified > 0)

      SetStatus("Full hedge — SL removed from " + IntegerToString(modified) + " positions", C'100,180,255');

  }



void UpdateAll()

  {

   // Auto-disarm flatten if pending orders were already removed externally

   if(g_FlattenArmed)

     {

      bool stillPending = false;

      for(int i = 0; i < OrdersTotal(); i++)

        {

         OrderGetTicket(i);

         if(OrderGetString(ORDER_SYMBOL) == _Symbol) { stillPending = true; break; }

        }

      if(!stillPending) { g_FlattenArmed = false; ResetFlattenButton(); }

     }



   // Remove transient warning labels only — persistent lines update in-place

   string linePfx[] = { WARN_PRE, INFO_PRE };

   int total = ObjectsTotal(0);

   for(int i = total - 1; i >= 0; i--)

     {

      string name = ObjectName(0, i);

      for(int p = 0; p < ArraySize(linePfx); p++)

         if(StringFind(name, linePfx[p]) == 0)

           { ObjectDelete(0, name); break; }

     }



    string sym    = _Symbol;

    int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

    int    nPos   = PositionsTotal();



    double buyVol = 0, buyW = 0, sellVol = 0, sellW = 0;

    int symPosCount = 0;

    for(int i = 0; i < nPos; i++)

      {

       if(PositionGetSymbol(i) != sym) continue;

       symPosCount++;

       double lots  = PositionGetDouble(POSITION_VOLUME);

       double price = PositionGetDouble(POSITION_PRICE_OPEN);

       ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

       if(pt == POSITION_TYPE_BUY) { buyVol  += lots; buyW  += lots * price; }

       else                        { sellVol += lots; sellW += lots * price; }

     

     int symOrdCount = 0;

     for(int i = 0; i < OrdersTotal(); i++) {

         ulong oticket = OrderGetTicket(i);

         if(oticket > 0 && OrderSelect(oticket) && OrderGetString(ORDER_SYMBOL) == sym) {

             symOrdCount++;

         }

     }

     int symTotalCount = symPosCount + symOrdCount;



    bool   hasBuys  = buyVol  > 0;

   bool   hasSells = sellVol > 0;

   bool   isHedged = hasBuys && hasSells;

   double netVol   = buyVol - sellVol;

   bool   hasAny   = hasBuys || hasSells;



   // Explicit cleanup when positions close — only fires on the transition tick

   if(g_HadPositions && !hasAny)

     {

      ObjectDelete(0, BE_LINE    + sym);

      ObjectDelete(0, BE_LABEL   + sym);

      ObjectDelete(0, BE_LOCKED  + sym);

      ObjectDelete(0, LIQ_LINE   + sym);

      ObjectDelete(0, LIQ_LABEL  + sym);

      ObjectDelete(0, RISK_LINE  + sym);

      ObjectDelete(0, RISK_LABEL + sym);

      ObjectDelete(0, PNL_LABEL  + sym);

      ObjectDelete(0, SL_LABEL   + sym);

      ObjectDelete(0, TP_LABEL   + sym);

     }

   g_HadPositions = hasAny;



   // Auto-remove SLs when fully hedged (netVol = 0) — only do it once per hedge state

   if(MathAbs(netVol) < 0.00001 && isHedged)

     {

      if(!g_SLRemovedForFullHedge) { RemoveAllSL(); g_SLRemovedForFullHedge = true; }

     }

   else

      g_SLRemovedForFullHedge = false; // reset when no longer fully hedged



   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);

   double margin   = AccountInfoDouble(ACCOUNT_MARGIN);

   string currency = AccountInfoString(ACCOUNT_CURRENCY);

   double soPct    = GetStopOutPercent();

   double eqBuf    = equity - (soPct / 100.0) * margin;

   double vpp      = GetVPP(sym);

   double ask      = SymbolInfoDouble(sym, SYMBOL_ASK);

   double bid      = SymbolInfoDouble(sym, SYMBOL_BID);

   double mid      = (ask + bid) / 2.0;



   // ---- BREAKEVEN ----

   if(ShowBreakeven && (hasBuys || hasSells))

     {

      if(!isHedged)

        {

         // Hide the locked-hedge label if we were in it before

         ObjectDelete(0, BE_LOCKED + sym);

         double be = NormalizeDouble((buyW + sellW) / (buyVol + sellVol), digits);

         DrawHLine(BE_LINE + sym, BE_LABEL + sym, be, BEColor, "breakeven", digits,

                   "Breakeven: " + DoubleToString(be, digits));

        }

      else if(MathAbs(netVol) < 0.00001)

        {

         // Full hedge — hide the line, show text label instead

         ObjectDelete(0, BE_LINE  + sym);

         ObjectDelete(0, BE_LABEL + sym);

         double pts = (sellW / sellVol) - (buyW / buyVol);

         DrawBottomLeftLabel(BE_LOCKED + sym,

                             "BE: locked hedge | " + DoubleToString(pts, digits) + " pts",

                             BEColor, 10, PAN_Y + PAN_H + 20, 7);

        }

      else

        {

         ObjectDelete(0, BE_LOCKED + sym);

         double be = NormalizeDouble((buyW - sellW) / netVol, digits);

         if(be > 0)

            DrawHLine(BE_LINE + sym, BE_LABEL + sym, be, BEColor, "breakeven", digits,

                      "Breakeven: " + DoubleToString(be, digits));

        }

     }

   else if(!ShowBreakeven || !(hasBuys || hasSells))

     {

      // Clean up all BE objects when disabled or no positions

      ObjectDelete(0, BE_LINE   + sym);

      ObjectDelete(0, BE_LABEL  + sym);

      ObjectDelete(0, BE_LOCKED + sym);

     }



   // ---- LIQUIDATION + RISK ----

   g_Blocked = false;

   string riskText = "No open positions";

   color  riskClr  = clrSilver;



   if(ShowLiquidation && equity > 0 && margin > 0 &&

      MathAbs(netVol) > 0.00001 && vpp > 0)

     {

      double liqPrice = NormalizeDouble(mid - (eqBuf / (netVol * vpp)), digits);



      if(liqPrice > 0)

        {

         double distPct = (MathAbs(mid - liqPrice) / mid) * 100.0;

         string tip = "Est. Liquidation: " + DoubleToString(liqPrice, digits) +

                      " | Dist: "    + DoubleToString(distPct, 2) + "%" +

                      " | Net lots: " + DoubleToString(netVol, 2) +

                      " | Stop-out: " + DoubleToString(soPct, 1) + "%" +

                      " | Buffer: "   + DoubleToString(eqBuf, 2) + " " + currency;

         DrawHLine(LIQ_LINE + sym, LIQ_LABEL + sym, liqPrice, LiqColor, "liquidation", digits, tip);



         // Risk threshold line: MinLiqDistanceATR M30-ATRs from trail stop (or BE if trail off)

         double m30Atr = GetM30ATR();

         if(m30Atr <= 0) m30Atr = GetCurrentATR();

         if(m30Atr > 0)

           {

            // Prefer trail stop as anchor (more dynamic) — fall back to BE

            double anchor = 0;

            if(g_TrailActive && g_TrailStop > 0)

               anchor = g_TrailStop;  // anchored to live trail level

            else

              {

               if(MathAbs(netVol) > 0.00001)

                  anchor = NormalizeDouble((buyW - sellW) / netVol, digits);

               if(anchor <= 0) anchor = mid;

              }



            double riskDir    = (netVol > 0) ? -1.0 : 1.0;

            double riskThresh = NormalizeDouble(anchor + riskDir * MinLiqDistanceATR * m30Atr, digits);

            double gapToLiq   = MathAbs(riskThresh - liqPrice) / m30Atr;

            string anchorLbl  = (g_TrailActive && g_TrailStop > 0) ? "trail stop" : "breakeven";

            string riskTip    = "Risk threshold: " + DoubleToString(MinLiqDistanceATR, 0) +

                                " ATRs from " + anchorLbl + "  |  " + DoubleToString(gapToLiq, 1) +

                                " ATRs to liq" +

                                " | M30 ATR=" + DoubleToString(m30Atr, digits) +

                                " | liq=" + DoubleToString(liqPrice, digits);

            DrawHLine(RISK_LINE + sym, RISK_LABEL + sym, riskThresh, C'160,80,20', "risk threshold", digits, riskTip);

            ObjectSetInteger(0, RISK_LINE + sym, OBJPROP_STYLE, STYLE_DASH);

            ObjectSetInteger(0, RISK_LINE + sym, OBJPROP_WIDTH, 1);

           }



         // ATR-relative distance

         double atrNow     = GetCurrentATR();

         double liqDistATR = (GetM30ATR() > 0) ? (MathAbs(mid - liqPrice) / GetM30ATR()) : 0;

         // Max additional lots before breaching threshold

         double minDistPrice = MinLiqDistanceATR * atrNow;

         double maxAbsNet    = (vpp > 0 && minDistPrice > 0)

                               ? MathAbs(eqBuf) / (vpp * minDistPrice) : 0;

         double maxAdd       = NormalizeDouble(

                               MathFloor(MathMax(maxAbsNet - MathAbs(netVol), 0) / 0.1) * 0.1, 2);



         if(liqDistATR < MinLiqDistanceATR && liqDistATR > 0)

           {

            g_Blocked = true;

            riskText  = "RISK! Liq " + DoubleToString(liqDistATR, 2) +

                        " ATRs (" + DoubleToString(distPct, 2) + "%) — REDUCE SIZE";

            riskClr   = WarningColor;



            DrawTopLeftLabel(WARN_PRE + "1",

                             "LIQUIDATION RISK: " + DoubleToString(liqDistATR, 2) +

                             " ATRs to liq  (min: " + DoubleToString(MinLiqDistanceATR, 1) + ")",

                             WarningColor, 20, 9);



            DrawBottomLeftLabel(WARN_PRE + "2",

                                "Reduce position — liq too close in ATR terms!",

                                WarningColor,

                                PAN_X, PAN_Y + PAN_H + 34, 7);

           }

         else

           {

            riskText = "Liq: " + DoubleToString(liqDistATR, 2) +

                       " ATRs (" + DoubleToString(distPct, 2) + "%)  |  Max add: " +

                       DoubleToString(maxAdd, 2) + " lots";

            riskClr  = clrSilver;

           }

        }

     }

   else

     {

      // No positions or liq not applicable — remove liq + risk threshold lines

      ObjectDelete(0, LIQ_LINE   + sym);

      ObjectDelete(0, LIQ_LABEL  + sym);

      ObjectDelete(0, RISK_LINE  + sym);

      ObjectDelete(0, RISK_LABEL + sym);

     }



   // ---- ATR LABEL ----

   double atr    = GetCurrentATR();

   double slDist = atr * AtrMultiplier;

   string atrTxt = "  Trail: Price ± ATR(" + IntegerToString(AtrPeriod) + ") x" +

                   DoubleToString(AtrMultiplier, 1) + " = " +

                   DoubleToString(slDist, digits) + " pts";

   if(ObjectFind(0, P_ATR_LBL) >= 0)

     {

      ObjectSetString(0, P_ATR_LBL, OBJPROP_TEXT, atrTxt);

      ObjectSetInteger(0, P_ATR_LBL, OBJPROP_COLOR, clrSilver);

     }



   // ---- RECOMMENDED LOT SIZE (ATR-based: risk 1% of equity per SL) ----

   if(ObjectFind(0, P_REC_LBL) >= 0)

     {

      double recAtr  = GetCurrentATR();

      double recVpp  = GetVPP(sym);

      string recTxt  = "  Rec: --";

      if(recAtr > 0 && recVpp > 0)

        {

         // 1% of equity / (SL distance in money per lot)

         double recSlDist = recAtr * AtrMultiplier;

         double riskAmt   = equity * 0.01;            // 1% of equity

         double slMoney   = recSlDist * recVpp;        // $ loss per lot if SL hit

         double recLots   = (slMoney > 0) ? riskAmt / slMoney : 0;

         double lotStep   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

         if(lotStep <= 0) lotStep = 0.01;

         recLots = NormalizeDouble(MathFloor(recLots / lotStep) * lotStep, 2);

         recLots = MathMax(recLots, SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN));

         recTxt  = "  Rec (1% risk): " + DoubleToString(recLots, 2) + " lots";

        }

      ObjectSetString(0, P_REC_LBL, OBJPROP_TEXT,  recTxt);

     }



   // ---- REFRESH PANEL DYNAMIC FIELDS ----

   if(ObjectFind(0, P_LOTS_EDIT) >= 0)

      ObjectSetString(0, P_LOTS_EDIT, OBJPROP_TEXT, DoubleToString(g_LotSize, 2));



   if(ObjectFind(0, P_RISK_LBL) >= 0)

     {

      ObjectSetString (0, P_RISK_LBL, OBJPROP_TEXT,  riskText);

      ObjectSetInteger(0, P_RISK_LBL, OBJPROP_COLOR, riskClr);

     }



   color buyBg  = g_Blocked ? DisabledBtnColor : BuyBtnColor;

   color sellBg = g_Blocked ? DisabledBtnColor : SellBtnColor;

   if(ObjectFind(0, P_BUY_BTN)  >= 0) ObjectSetInteger(0, P_BUY_BTN,  OBJPROP_BGCOLOR, buyBg);

   if(ObjectFind(0, P_SELL_BTN) >= 0) ObjectSetInteger(0, P_SELL_BTN, OBJPROP_BGCOLOR, sellBg);



   // ---- ALERT LINE CHECK ----

   if(ObjectFind(0, CTX_ALERT_LINE) >= 0)

     {

      double alertPrice = NormalizeDouble(ObjectGetDouble(0, CTX_ALERT_LINE, OBJPROP_PRICE), digits);

      color  alertColor = (color)ObjectGetInteger(0, CTX_ALERT_LINE, OBJPROP_COLOR);

      

      if(alertColor == clrRed)

        {

         // Already triggered - play sound persistently

         PlaySound("alert.wav");

        }

      else if(alertPrice > 0 && bid > 0 && ask > 0)

        {

         // Reset tracking if dragged to a new price or if EA reloaded

         if(alertPrice != g_AlertSetupPrice)

           {

            g_AlertSetupPrice = alertPrice;

            g_AlertSide       = (bid > alertPrice) ? 1 : -1;

           }

         

         // Fire alert when price crosses the line depending on original side

         bool crossed = (g_AlertSide == 1 && bid <= alertPrice) || (g_AlertSide == -1 && ask >= alertPrice);

           

         if(crossed)

           {

            ObjectSetInteger(0, CTX_ALERT_LINE, OBJPROP_COLOR, clrRed);

            if(ObjectFind(0, CTX_ALERT_LBL) >= 0)

              {

               ObjectSetInteger(0, CTX_ALERT_LBL, OBJPROP_COLOR, clrRed);

               string txt = ObjectGetString(0, CTX_ALERT_LBL, OBJPROP_TEXT);

               ObjectSetString(0, CTX_ALERT_LBL, OBJPROP_TEXT, "! " + txt + " !");

              }

            SetStatus("Alert triggered @ " + DoubleToString(alertPrice, digits) + " - playing sound", clrRed);

            PlaySound("alert.wav");

           }

        }

     }



   // ---- FLOATING PnL LABEL (between bid and ask) ----

   // ---- FLOATING PnL + CUMULATIVE SL / TP — price-scale labels ----

   // OBJ_TEXT positioned at actual price level, time hugs right edge of visible chart

   string pnlName = PNL_LABEL + sym;

   string slName  = SL_LABEL  + sym;

   string tpName  = TP_LABEL  + sym;



   // Right-edge time: 3 bars past latest bar — always visible, adapts to any zoom

   int      vBars     = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);

   datetime rightTime = (datetime)((long)iTime(_Symbol, PERIOD_CURRENT, 0) + (long)PeriodSeconds() * (long)MathMax(3, vBars / 20));



   // Show mid-price PnL only when we have actual open positions

   if(hasBuys || hasSells)

    {

      // --- PnL at mid price ---

      double floatingPnL = 0;

      for(int i = 0; i < nPos; i++)

        {

         if(PositionGetSymbol(i) != sym) continue;

         floatingPnL += PositionGetDouble(POSITION_PROFIT);

         floatingPnL += PositionGetDouble(POSITION_SWAP);

        }

      double totalPnL  = floatingPnL + (g_HedgeSessionActive ? g_HedgeSessionPnL : 0);

      double midPrice  = (ask + bid) / 2.0;

      string pnlSign   = (totalPnL >= 0) ? "+" : "";

      string pnlText   = pnlSign + DoubleToString(totalPnL, 2) + " " + currency;

      color  pnlColor  = (totalPnL >= 0) ? clrLime : clrOrangeRed;



      if(ObjectFind(0, pnlName) < 0)

        {

         ObjectCreate(0, pnlName, OBJ_TEXT, 0, rightTime, midPrice);

         ObjectSetInteger(0, pnlName, OBJPROP_FONTSIZE,   11);

         ObjectSetString (0, pnlName, OBJPROP_FONT,       "Arial Bold");

         ObjectSetInteger(0, pnlName, OBJPROP_ANCHOR,     ANCHOR_LEFT);

         ObjectSetInteger(0, pnlName, OBJPROP_SELECTABLE, false);

         ObjectSetInteger(0, pnlName, OBJPROP_HIDDEN,     true);

        }

      ObjectSetString (0, pnlName, OBJPROP_TEXT,  pnlText);

      ObjectSetInteger(0, pnlName, OBJPROP_COLOR, pnlColor);

      ObjectSetDouble (0, pnlName, OBJPROP_PRICE, midPrice);

      ObjectSetInteger(0, pnlName, OBJPROP_TIME,  rightTime);

    }



   // --- Cumulative SL / TP (Positions + Pending Orders) ---

   double totalSlLoss = 0, totalTpGain = 0;

   double vppNow = GetVPP(sym);

   bool   hasAnySL = false, hasAnyTP = false;

   double lowestSL = DBL_MAX, highestSL = 0;

   double pendingNetVol = 0;

   double lowestTP = DBL_MAX, highestTP = 0;



   // Cleanup individual labels of closed/removed positions or orders

   int tObjs = ObjectsTotal(0, -1, OBJ_TEXT);

   for(int i = tObjs - 1; i >= 0; i--) {

       string oname = ObjectName(0, i, -1, OBJ_TEXT);

       if(StringFind(oname, "TT_SL_TK_") == 0 || StringFind(oname, "TT_TP_TK_") == 0 ||

          StringFind(oname, "TT_SL_ORD_") == 0 || StringFind(oname, "TT_TP_ORD_") == 0) {

           int    prefLen = (StringFind(oname, "TT_SL_ORD_") == 0 ||
                            StringFind(oname, "TT_TP_ORD_") == 0) ? 10 : 9;
           string tstr    = StringSubstr(oname, prefLen);

           ulong tk = StringToInteger(tstr);

           // For positions, PositionSelectByTicket will succeed; for orders, OrderSelect(ticket) will succeed.

           if(!PositionSelectByTicket(tk) && !OrderSelect(tk)) {

               ObjectDelete(0, oname);

           }

       }

   }



   // Active positions contribution

   for(int i = 0; i < nPos; i++)

        {

        if(PositionGetSymbol(i) != sym) continue;

         ulong  ticket = PositionGetInteger(POSITION_TICKET);

         double lots = PositionGetDouble(POSITION_VOLUME);

         double sl   = PositionGetDouble(POSITION_SL);

         double tp   = PositionGetDouble(POSITION_TP);

         ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);



          if(sl > 0 && vppNow > 0)

            {

             double mySlDist = (pt == POSITION_TYPE_BUY) ? (openPrice - sl) : (sl - openPrice);

             double myLoss   = mySlDist * lots * vppNow;

             double myLossP  = equity > 0 ? (myLoss / equity) * 100.0 : 0;

             totalSlLoss  += myLoss;

             hasAnySL      = true;

             if(pt == POSITION_TYPE_SELL) { if(sl > highestSL) highestSL = sl; }

             else                         { if(sl < lowestSL)  lowestSL  = sl; }

             

             string slLblName = "TT_SL_TK_" + IntegerToString(ticket);

             if(ObjectFind(0, slLblName) < 0) {

                 ObjectCreate(0, slLblName, OBJ_TEXT, 0, rightTime, sl);

                 ObjectSetInteger(0, slLblName, OBJPROP_ANCHOR, ANCHOR_LEFT);

                 ObjectSetInteger(0, slLblName, OBJPROP_SELECTABLE, false);

                 ObjectSetInteger(0, slLblName, OBJPROP_HIDDEN, true);

                 ObjectSetString (0, slLblName, OBJPROP_FONT, "Arial");

                 ObjectSetInteger(0, slLblName, OBJPROP_FONTSIZE, 9);

                 ObjectSetInteger(0, slLblName, OBJPROP_COLOR, clrRed); 

             }

             datetime tkTime = (datetime)((long)rightTime + (long)PeriodSeconds() * 1);

             ObjectSetString(0, slLblName, OBJPROP_TEXT, "  -" + DoubleToString(myLoss, 2) + currency + " (" + DoubleToString(myLossP, 1) + "%)");

             ObjectSetDouble(0, slLblName, OBJPROP_PRICE, sl);

             ObjectSetInteger(0, slLblName, OBJPROP_TIME, tkTime);

            }

          else ObjectDelete(0, "TT_SL_TK_" + IntegerToString(ticket));

          

          if(tp > 0 && vppNow > 0)

            {

             double myTpDist = (pt == POSITION_TYPE_BUY) ? (tp - openPrice) : (openPrice - tp);

             double myGain   = myTpDist * lots * vppNow;

             double myGainP  = equity > 0 ? (myGain / equity) * 100.0 : 0;

             totalTpGain  += myGain;

             hasAnyTP      = true;

             if(pt == POSITION_TYPE_BUY)  { if(tp > highestTP) highestTP = tp; }

             else                         { if(tp < lowestTP)  lowestTP  = tp; }

             

             string tpLblName = "TT_TP_TK_" + IntegerToString(ticket);

             if(ObjectFind(0, tpLblName) < 0) {

                 ObjectCreate(0, tpLblName, OBJ_TEXT, 0, rightTime, tp);

                 ObjectSetInteger(0, tpLblName, OBJPROP_ANCHOR, ANCHOR_LEFT);

                 ObjectSetInteger(0, tpLblName, OBJPROP_SELECTABLE, false);

                 ObjectSetInteger(0, tpLblName, OBJPROP_HIDDEN, true);

                 ObjectSetString (0, tpLblName, OBJPROP_FONT, "Arial");

                 ObjectSetInteger(0, tpLblName, OBJPROP_FONTSIZE, 9);

                 ObjectSetInteger(0, tpLblName, OBJPROP_COLOR, clrLime); 

             }

             datetime tkTime2 = (datetime)((long)rightTime + (long)PeriodSeconds() * 1);

             ObjectSetString(0, tpLblName, OBJPROP_TEXT, "  +" + DoubleToString(myGain, 2) + currency + " (" + DoubleToString(myGainP, 1) + "%)");

             ObjectSetDouble(0, tpLblName, OBJPROP_PRICE, tp);

             ObjectSetInteger(0, tpLblName, OBJPROP_TIME, tkTime2);

            }

          else ObjectDelete(0, "TT_TP_TK_" + IntegerToString(ticket));

         }



      // Pending orders contribution (estimated PnL even before execution)

      int nOrd = OrdersTotal();

      for(int j = 0; j < nOrd; j++)

        {

         ulong oticket = OrderGetTicket(j);

         if(oticket == 0) continue;

         if(!OrderSelect(oticket)) continue;

         if(OrderGetString(ORDER_SYMBOL) != sym) continue;



         double olots  = OrderGetDouble(ORDER_VOLUME_CURRENT);

         double osl    = OrderGetDouble(ORDER_SL);

         double otp    = OrderGetDouble(ORDER_TP);

         double oprice = OrderGetDouble(ORDER_PRICE_OPEN);

         ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);



         bool isBuyOrder = (otype == ORDER_TYPE_BUY || otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_BUY_STOP);

         bool isSellOrder = (otype == ORDER_TYPE_SELL || otype == ORDER_TYPE_SELL_LIMIT || otype == ORDER_TYPE_SELL_STOP);



         if(isBuyOrder) pendingNetVol += olots;

         else if(isSellOrder) pendingNetVol -= olots;



          if(osl > 0 && vppNow > 0 && (isBuyOrder || isSellOrder))

            {

             double mySlDist = isBuyOrder ? (oprice - osl) : (osl - oprice);

             double myLoss   = mySlDist * olots * vppNow;

             double myLossP  = equity > 0 ? (myLoss / equity) * 100.0 : 0;

             totalSlLoss  += myLoss;

             hasAnySL      = true;

             if(isSellOrder) { if(osl > highestSL) highestSL = osl; }

             else            { if(osl < lowestSL)  lowestSL  = osl; }



             string slOrdLbl = "TT_SL_ORD_" + IntegerToString(oticket);

             if(ObjectFind(0, slOrdLbl) < 0) {

                 ObjectCreate(0, slOrdLbl, OBJ_TEXT, 0, rightTime, osl);

                 ObjectSetInteger(0, slOrdLbl, OBJPROP_ANCHOR, ANCHOR_LEFT);

                 ObjectSetInteger(0, slOrdLbl, OBJPROP_SELECTABLE, false);

                 ObjectSetInteger(0, slOrdLbl, OBJPROP_HIDDEN, true);

                 ObjectSetString (0, slOrdLbl, OBJPROP_FONT, "Arial");

                 ObjectSetInteger(0, slOrdLbl, OBJPROP_FONTSIZE, 9);

                 ObjectSetInteger(0, slOrdLbl, OBJPROP_COLOR, clrRed);

             }

             datetime oTkTime = (datetime)((long)rightTime + (long)PeriodSeconds() * 1);

             ObjectSetString(0, slOrdLbl, OBJPROP_TEXT, "  -" + DoubleToString(myLoss, 2) + currency + " (" + DoubleToString(myLossP, 1) + "%)");

             ObjectSetDouble(0, slOrdLbl, OBJPROP_PRICE, osl);

             ObjectSetInteger(0, slOrdLbl, OBJPROP_TIME,  oTkTime);

            }

          else ObjectDelete(0, "TT_SL_ORD_" + IntegerToString(oticket));



          if(otp > 0 && vppNow > 0 && (isBuyOrder || isSellOrder))

            {

             double myTpDist = isBuyOrder ? (otp - oprice) : (oprice - otp);

             double myGain   = myTpDist * olots * vppNow;

             double myGainP  = equity > 0 ? (myGain / equity) * 100.0 : 0;

             totalTpGain  += myGain;

             hasAnyTP      = true;

             if(isBuyOrder) { if(otp > highestTP) highestTP = otp; }

             else           { if(otp < lowestTP)  lowestTP  = otp; }



             string tpOrdLbl = "TT_TP_ORD_" + IntegerToString(oticket);

             if(ObjectFind(0, tpOrdLbl) < 0) {

                 ObjectCreate(0, tpOrdLbl, OBJ_TEXT, 0, rightTime, otp);

                 ObjectSetInteger(0, tpOrdLbl, OBJPROP_ANCHOR, ANCHOR_LEFT);

                 ObjectSetInteger(0, tpOrdLbl, OBJPROP_SELECTABLE, false);

                 ObjectSetInteger(0, tpOrdLbl, OBJPROP_HIDDEN, true);

                 ObjectSetString (0, tpOrdLbl, OBJPROP_FONT, "Arial");

                 ObjectSetInteger(0, tpOrdLbl, OBJPROP_FONTSIZE, 9);

                 ObjectSetInteger(0, tpOrdLbl, OBJPROP_COLOR, clrLime);

             }

             datetime oTkTime2 = (datetime)((long)rightTime + (long)PeriodSeconds() * 1);

             ObjectSetString(0, tpOrdLbl, OBJPROP_TEXT, "  +" + DoubleToString(myGain, 2) + currency + " (" + DoubleToString(myGainP, 1) + "%)");

             ObjectSetDouble(0, tpOrdLbl, OBJPROP_PRICE, otp);

             ObjectSetInteger(0, tpOrdLbl, OBJPROP_TIME,  oTkTime2);

            }

          else ObjectDelete(0, "TT_TP_ORD_" + IntegerToString(oticket));

         }



      if(hasAnySL)

        {

         double totalExposure = netVol + pendingNetVol;

         double slPrice = (totalExposure > 0 || (totalExposure == 0 && lowestSL != DBL_MAX && highestSL == 0)) ? lowestSL : ((highestSL > 0) ? highestSL : lowestSL);

         double slPad   = SymbolInfoDouble(sym, SYMBOL_POINT) * 10.0; // draw text slightly below line

         double slLabelPrice = slPrice - slPad;

         double totLossP = equity > 0 ? (totalSlLoss / equity) * 100.0 : 0;

         string slText  = " Estimated Total Loss: -" + DoubleToString(totalSlLoss, 2) + " " + currency + " (" + DoubleToString(totLossP, 1) + "%) ";

         int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);

         int ySl    = PriceToY(slLabelPrice);

         if(ObjectFind(0, slName) < 0 || ObjectGetInteger(0, slName, OBJPROP_TYPE) != OBJ_LABEL)

           {

            if(ObjectFind(0, slName) >= 0) ObjectDelete(0, slName);

            ObjectCreate(0, slName, OBJ_LABEL, 0, 0, 0);

            ObjectSetInteger(0, slName, OBJPROP_CORNER,    CORNER_LEFT_UPPER);

            ObjectSetInteger(0, slName, OBJPROP_FONTSIZE,  11);

            ObjectSetString (0, slName, OBJPROP_FONT,      "Arial Bold");

            ObjectSetInteger(0, slName, OBJPROP_ANCHOR,    ANCHOR_CENTER);

            ObjectSetInteger(0, slName, OBJPROP_SELECTABLE,false);

            ObjectSetInteger(0, slName, OBJPROP_HIDDEN,    true);

           }

         ObjectSetString (0, slName, OBJPROP_TEXT,      slText);

         ObjectSetInteger(0, slName, OBJPROP_XDISTANCE, chartW / 2);

         ObjectSetInteger(0, slName, OBJPROP_YDISTANCE, ySl);

         ObjectSetInteger(0, slName, OBJPROP_COLOR,     clrRed);

        }

      else ObjectDelete(0, slName);



      if(hasAnyTP)

        {

         double totalExposure = netVol + pendingNetVol;

         double tpPrice = (totalExposure > 0 || (totalExposure == 0 && highestTP > 0 && lowestTP == DBL_MAX)) ? highestTP : ((lowestTP != DBL_MAX) ? lowestTP : highestTP);

         double tpPad   = SymbolInfoDouble(sym, SYMBOL_POINT) * 10.0; // draw text slightly above line

         double tpLabelPrice = tpPrice + tpPad;

         double totGainP = equity > 0 ? (totalTpGain / equity) * 100.0 : 0;

         string tpText  = " Estimated Total Profit: +" + DoubleToString(totalTpGain, 2) + " " + currency + " (" + DoubleToString(totGainP, 1) + "%) ";

         int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);

         int yTp    = PriceToY(tpLabelPrice);

         if(ObjectFind(0, tpName) < 0 || ObjectGetInteger(0, tpName, OBJPROP_TYPE) != OBJ_LABEL)

           {

            if(ObjectFind(0, tpName) >= 0) ObjectDelete(0, tpName);

            ObjectCreate(0, tpName, OBJ_LABEL, 0, 0, 0);

            ObjectSetInteger(0, tpName, OBJPROP_CORNER,    CORNER_LEFT_UPPER);

            ObjectSetInteger(0, tpName, OBJPROP_FONTSIZE,  11);

            ObjectSetString (0, tpName, OBJPROP_FONT,      "Arial Bold");

            ObjectSetInteger(0, tpName, OBJPROP_ANCHOR,    ANCHOR_CENTER);

            ObjectSetInteger(0, tpName, OBJPROP_SELECTABLE,false);

            ObjectSetInteger(0, tpName, OBJPROP_HIDDEN,    true);

           }

         ObjectSetString (0, tpName, OBJPROP_TEXT,      tpText);

         ObjectSetInteger(0, tpName, OBJPROP_XDISTANCE, chartW / 2);

         ObjectSetInteger(0, tpName, OBJPROP_YDISTANCE, yTp);

         ObjectSetInteger(0, tpName, OBJPROP_COLOR,     clrLime);

        }

      else ObjectDelete(0, tpName);



   // Update "close hedges" button label based on whether tagged hedges exist

   if(ObjectFind(0, P_CHDG_BTN) >= 0)

     {

      bool hasTaggedHedges = false;

      for(int i = 0; i < PositionsTotal(); i++)

        {

         if(PositionGetSymbol(i) != _Symbol) continue;

         if(StringFind(PositionGetString(POSITION_COMMENT), "Hedge_") == 0)

           { hasTaggedHedges = true; break; }

        }

      string btnLabel = "close hedges"; // always show close hedges

      ObjectSetString(0, P_CHDG_BTN, OBJPROP_TEXT, btnLabel);

     }



   UpdateTrailStop();

   ChartRedraw(0);

  }

  }

//+------------------------------------------------------------------+





void MakeButton(string name, string text, ENUM_BASE_CORNER corner,

                int xd, int yd, int w, int h, color bg, color fg, int fs)

  {

   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,     corner);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  xd);

   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  yd);

   ObjectSetInteger(0, name, OBJPROP_XSIZE,      w);

   ObjectSetInteger(0, name, OBJPROP_YSIZE,      h);

   ObjectSetString (0, name, OBJPROP_TEXT,       text);

   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,    bg);

   ObjectSetInteger(0, name, OBJPROP_COLOR,      fg);

   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   fs);

   ObjectSetString (0, name, OBJPROP_FONT,       "Arial Bold");

   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   ObjectSetInteger(0, name, OBJPROP_STATE, false);

  }

