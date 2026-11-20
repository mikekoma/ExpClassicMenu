unit uExpClassicMenu;

{
  ExpClassicMenu 本体

  仕組み
    - 低レベルマウスフック(WH_MOUSE_LL)で右ボタンを監視する。
    - 右ボタン押下位置が Explorer のファイル表示(SHELLDLL_DefView)・
      ナビゲーションペイン(NamespaceTreeControl)・デスクトップの場合、
      押下イベントを通過させた直後に Shift 押下を SendInput で注入する。
    - 右ボタンを離したあと少し待ってから Shift を離す。
      → Explorer は WM_CONTEXTMENU 処理時に Shift 押下とみなし、従来メニューを出す。
    - 右ボタン自体は横取りしないので、右ドラッグもそのまま使える。
    - 低レベルキーボードフック(WH_KEYBOARD_LL)でアプリケーションキー(VK_APPS)も監視する。
      フォーカスのあるウィンドウが対象なら、最初の押下を止めて
      「Shift 押下 → アプリケーションキー押下」の順に送り直す。
      キーを離したあと少し待ってから Shift を離す。
}

interface

procedure RunApp;

implementation

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, System.Types, System.SysUtils,
  System.Win.Registry;

const
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  MSGFLT_ALLOW = 1;

function QueryFullProcessImageName(hProcess: THandle; dwFlags: DWORD;
  lpExeName: PChar; lpdwSize: PDWORD): BOOL; stdcall;
  external kernel32 name 'QueryFullProcessImageNameW';
function ChangeWindowMessageFilterEx(hWnd: HWND; message: UINT; action: DWORD;
  pChangeFilterStruct: Pointer): BOOL; stdcall;
  external user32 name 'ChangeWindowMessageFilterEx';

const
  APP_NAME      = 'ExpClassicMenu';
  APP_TITLE     = 'ExpClassicMenu - 従来の右クリックメニュー';
  APP_VERSION   = 'ver002';
  APP_COPYRIGHT = 'Copyright (c) 2026 mikekoma';
  APP_CONTACT   = 'mail: mike@s-m-l.org' + sLineBreak + 'web: https://www.s-m-l.org';
  WND_CLASS     = 'ExpClassicMenuWnd';
  MUTEX_NAME    = 'ExpClassicMenu_SingleInstance_Mutex';
  REG_KEY       = 'Software\ExpClassicMenu';
  RUN_KEY       = 'Software\Microsoft\Windows\CurrentVersion\Run';

  WM_TRAYICON   = WM_APP + 1;
  TRAY_ID       = 1;

  TIMER_RELEASE = 1;
  RELEASE_DELAY = 200;   // 右ボタンを離してから Shift を離すまで(ms)

  IDM_ENABLED   = 101;
  IDM_DIALOGS   = 102;
  IDM_STARTUP   = 103;
  IDM_ABOUT     = 104;
  IDM_EXIT      = 199;

  LLMHF_INJECTED_FLAG = $00000001;
  LLKHF_EXTENDED_FLAG = $00000001;
  LLKHF_INJECTED_FLAG = $00000010;

type
  PKbdLLHook = ^TKbdLLHook;
  TKbdLLHook = record
    vkCode: DWORD;
    scanCode: DWORD;
    flags: DWORD;
    time: DWORD;
    dwExtraInfo: ULONG_PTR;
  end;

  PMouseLLHook = ^TMouseLLHook;
  TMouseLLHook = record
    pt: TPoint;
    mouseData: DWORD;
    flags: DWORD;
    time: DWORD;
    dwExtraInfo: ULONG_PTR;
  end;

var
  GWnd: HWND;
  GHook: HHOOK;
  GKbdHook: HHOOK;
  GTaskbarCreatedMsg: UINT;
  GIconOn: HICON;
  GIconOff: HICON;

  GEnabled: Boolean = True;
  GIncludeDialogs: Boolean = False;

  GShiftInjected: Boolean = False;
  GAboutShown: Boolean = False;

  // プロセス判定のキャッシュ
  GCachePid: DWORD = 0;
  GCacheIsExplorer: Boolean = False;

{ ---------------------------------------------------------------- 設定 }

procedure LoadSettings;
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(REG_KEY) then
    begin
      if Reg.ValueExists('Enabled') then
        GEnabled := Reg.ReadBool('Enabled');
      if Reg.ValueExists('IncludeDialogs') then
        GIncludeDialogs := Reg.ReadBool('IncludeDialogs');
    end;
  finally
    Reg.Free;
  end;
end;

procedure SaveSettings;
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey(REG_KEY, True) then
    begin
      Reg.WriteBool('Enabled', GEnabled);
      Reg.WriteBool('IncludeDialogs', GIncludeDialogs);
    end;
  finally
    Reg.Free;
  end;
end;

function IsStartupRegistered: Boolean;
var
  Reg: TRegistry;
begin
  Result := False;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(RUN_KEY) then
      Result := Reg.ValueExists(APP_NAME);
  finally
    Reg.Free;
  end;
end;

procedure SetStartupRegistered(AValue: Boolean);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey(RUN_KEY, True) then
    begin
      if AValue then
        Reg.WriteString(APP_NAME, '"' + ParamStr(0) + '"')
      else if Reg.ValueExists(APP_NAME) then
        Reg.DeleteValue(APP_NAME);
    end;
  finally
    Reg.Free;
  end;
end;

{ ---------------------------------------------------------------- 対象判定 }

function GetWndClass(AWnd: HWND): string;
var
  Buf: array[0..255] of Char;
  Len: Integer;
begin
  Len := GetClassName(AWnd, Buf, Length(Buf));
  SetString(Result, Buf, Len);
end;

function IsExplorerProcess(APid: DWORD): Boolean;
var
  hProc: THandle;
  Buf: array[0..MAX_PATH] of Char;
  Size: DWORD;
begin
  if (APid <> 0) and (APid = GCachePid) then
    Exit(GCacheIsExplorer);

  Result := False;
  hProc := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, APid);
  if hProc <> 0 then
  try
    Size := Length(Buf);
    if QueryFullProcessImageName(hProc, 0, Buf, @Size) then
      Result := SameText(ExtractFileName(Buf), 'explorer.exe');
  finally
    CloseHandle(hProc);
  end;

  GCachePid := APid;
  GCacheIsExplorer := Result;
end;

// 指定ウィンドウがシェルのファイル表示/ナビゲーションペイン(またはその子)か
function IsTargetWindow(AWnd: HWND): Boolean;
var
  h, Root: HWND;
  Pid: DWORD;
  Cls: string;
  OnShellView: Boolean;
begin
  Result := False;
  h := AWnd;
  if h = 0 then
    Exit;

  Root := GetAncestor(h, GA_ROOT);
  Cls := GetWndClass(Root);
  // タスクバー・通知領域は対象外
  if SameText(Cls, 'Shell_TrayWnd') or SameText(Cls, 'Shell_SecondaryTrayWnd') or
     SameText(Cls, 'NotifyIconOverflowWindow') then
    Exit;

  // 祖先にシェルビューまたはナビゲーションペインがあるか
  OnShellView := False;
  while h <> 0 do
  begin
    Cls := GetWndClass(h);
    if SameText(Cls, 'SHELLDLL_DefView') or SameText(Cls, 'NamespaceTreeControl') then
    begin
      OnShellView := True;
      Break;
    end;
    if h = Root then
      Break;
    h := GetParent(h);
  end;
  if not OnShellView then
    Exit;

  if GIncludeDialogs then
    Exit(True);

  GetWindowThreadProcessId(Root, Pid);
  Result := IsExplorerProcess(Pid);
end;

// 指定座標がシェルのファイル表示/ナビゲーションペイン上か
function IsTargetPoint(const APt: TPoint): Boolean;
begin
  Result := IsTargetWindow(WindowFromPoint(APt));
end;

// キーボードフォーカスのあるウィンドウが対象か
function IsTargetFocus: Boolean;
var
  Fg: HWND;
  Info: TGUIThreadInfo;
begin
  Fg := GetForegroundWindow;
  if Fg = 0 then
    Exit(False);
  ZeroMemory(@Info, SizeOf(Info));
  Info.cbSize := SizeOf(Info);
  if GetGUIThreadInfo(GetWindowThreadProcessId(Fg, nil), Info) and (Info.hwndFocus <> 0) then
    Result := IsTargetWindow(Info.hwndFocus)
  else
    Result := IsTargetWindow(Fg);
end;

{ ---------------------------------------------------------------- Shift 注入 }

procedure MakeKeyInput(var AInp: TInput; AVk: Word; AScan: Word; AFlags: DWORD);
begin
  ZeroMemory(@AInp, SizeOf(AInp));
  AInp.Itype := INPUT_KEYBOARD;
  AInp.ki.wVk := AVk;
  AInp.ki.wScan := AScan;
  AInp.ki.dwFlags := AFlags;
end;

procedure SendShift(ADown: Boolean);
var
  Inp: TInput;
  Flags: DWORD;
begin
  Flags := 0;
  if not ADown then
    Flags := KEYEVENTF_KEYUP;
  MakeKeyInput(Inp, VK_LSHIFT, MapVirtualKey(VK_LSHIFT, MAPVK_VK_TO_VSC), Flags);
  SendInput(1, Inp, SizeOf(Inp));
end;

// Shift 押下とアプリケーションキー押下を、この順で送る
procedure SendShiftAndApps(const AKey: TKbdLLHook);
var
  Inp: array[0..1] of TInput;
  Flags: DWORD;
begin
  MakeKeyInput(Inp[0], VK_LSHIFT, MapVirtualKey(VK_LSHIFT, MAPVK_VK_TO_VSC), 0);
  Flags := 0;
  if (AKey.flags and LLKHF_EXTENDED_FLAG) <> 0 then
    Flags := KEYEVENTF_EXTENDEDKEY;
  MakeKeyInput(Inp[1], VK_APPS, AKey.scanCode, Flags);
  SendInput(Length(Inp), Inp[0], SizeOf(TInput));
end;

procedure ReleaseShift;
begin
  KillTimer(GWnd, TIMER_RELEASE);
  if GShiftInjected then
  begin
    GShiftInjected := False;
    SendShift(False);
  end;
end;

function ShiftPhysicallyDown: Boolean;
begin
  Result := (GetAsyncKeyState(VK_SHIFT) and $8000) <> 0;
end;

function LowLevelMouseProc(nCode: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  P: PMouseLLHook;
begin
  if nCode = HC_ACTION then
  begin
    P := PMouseLLHook(lParam);
    if (P^.flags and LLMHF_INJECTED_FLAG) = 0 then
    begin
      case wParam of
        WM_RBUTTONDOWN:
          if GShiftInjected then
            // 前回の Shift がまだ押下中 → 解放を延期してそのまま使う
            KillTimer(GWnd, TIMER_RELEASE)
          else if GEnabled and (not ShiftPhysicallyDown) and IsTargetPoint(P^.pt) then
          begin
            GShiftInjected := True;
            // このイベントの後ろに Shift 押下が並ぶので、
            // 押下自体は通常の右ボタン押下として処理され、選択動作は変わらない
            SendShift(True);
          end;
        WM_RBUTTONUP:
          if GShiftInjected then
            SetTimer(GWnd, TIMER_RELEASE, RELEASE_DELAY, nil);
      end;
    end;
  end;
  Result := CallNextHookEx(GHook, nCode, wParam, lParam);
end;

function LowLevelKeyboardProc(nCode: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  P: PKbdLLHook;
begin
  if nCode = HC_ACTION then
  begin
    P := PKbdLLHook(lParam);
    if (P^.vkCode = VK_APPS) and ((P^.flags and LLKHF_INJECTED_FLAG) = 0) then
    begin
      case wParam of
        WM_KEYDOWN, WM_SYSKEYDOWN:
          if GShiftInjected then
            // 前回の Shift がまだ押下中(またはキーリピート) → 解放を延期してそのまま通す
            KillTimer(GWnd, TIMER_RELEASE)
          else if GEnabled and (not ShiftPhysicallyDown) and IsTargetFocus then
          begin
            GShiftInjected := True;
            // キー押下の時点で Shift が押されている必要があるので、
            // 元の押下は止めて Shift → アプリケーションキーの順に送り直す
            SendShiftAndApps(P^);
            Exit(1);
          end;
        WM_KEYUP, WM_SYSKEYUP:
          if GShiftInjected then
            SetTimer(GWnd, TIMER_RELEASE, RELEASE_DELAY, nil);
      end;
    end;
  end;
  Result := CallNextHookEx(GKbdHook, nCode, wParam, lParam);
end;

procedure InstallHook;
begin
  if GHook = 0 then
    GHook := SetWindowsHookEx(WH_MOUSE_LL, @LowLevelMouseProc, HInstance, 0);
  if GKbdHook = 0 then
    GKbdHook := SetWindowsHookEx(WH_KEYBOARD_LL, @LowLevelKeyboardProc, HInstance, 0);
end;

procedure UninstallHook;
begin
  if GHook <> 0 then
  begin
    UnhookWindowsHookEx(GHook);
    GHook := 0;
  end;
  if GKbdHook <> 0 then
  begin
    UnhookWindowsHookEx(GKbdHook);
    GKbdHook := 0;
  end;
  ReleaseShift;
end;

{ ---------------------------------------------------------------- アイコン }

// メニューを模した小さなアイコンを描画して作成する
function CreateMenuIcon(AActive: Boolean): HICON;
var
  W, H, i, Y, LineH: Integer;
  ScreenDC, ColorDC, MaskDC: HDC;
  ColorBmp, MaskBmp, OldColor, OldMask: HBITMAP;
  R: TRect;
  Br, Pen, OldPen: THandle;
  BgColor, FgColor: COLORREF;
  Info: TIconInfo;
begin
  W := GetSystemMetrics(SM_CXSMICON);
  H := GetSystemMetrics(SM_CYSMICON);

  ScreenDC := GetDC(0);
  ColorDC := CreateCompatibleDC(ScreenDC);
  MaskDC := CreateCompatibleDC(ScreenDC);
  ColorBmp := CreateCompatibleBitmap(ScreenDC, W, H);
  MaskBmp := CreateBitmap(W, H, 1, 1, nil);
  OldColor := SelectObject(ColorDC, ColorBmp);
  OldMask := SelectObject(MaskDC, MaskBmp);

  if AActive then
  begin
    BgColor := RGB(255, 255, 255);
    FgColor := RGB(0, 120, 215);
  end
  else
  begin
    BgColor := RGB(200, 200, 200);
    FgColor := RGB(110, 110, 110);
  end;

  // マスク:白=透過、黒=不透明
  R := Rect(0, 0, W, H);
  FillRect(MaskDC, R, GetStockObject(WHITE_BRUSH));
  FillRect(ColorDC, R, GetStockObject(BLACK_BRUSH));

  R := Rect(W div 8, 0, W - W div 8, H);
  FillRect(MaskDC, R, GetStockObject(BLACK_BRUSH));

  // 背景と枠
  Br := CreateSolidBrush(BgColor);
  FillRect(ColorDC, R, Br);
  DeleteObject(Br);
  Br := CreateSolidBrush(FgColor);
  FrameRect(ColorDC, R, Br);

  // メニュー項目の横線
  LineH := H div 5;
  Pen := CreatePen(PS_SOLID, 1, FgColor);
  OldPen := SelectObject(ColorDC, Pen);
  for i := 1 to 4 do
  begin
    Y := i * LineH;
    if Y >= H - 1 then
      Break;
    R := Rect(W div 8 + 3, Y - 1, W - W div 8 - 3, Y + 1);
    FillRect(ColorDC, R, Br);
  end;
  SelectObject(ColorDC, OldPen);
  DeleteObject(Pen);
  DeleteObject(Br);

  SelectObject(ColorDC, OldColor);
  SelectObject(MaskDC, OldMask);

  ZeroMemory(@Info, SizeOf(Info));
  Info.fIcon := True;
  Info.hbmMask := MaskBmp;
  Info.hbmColor := ColorBmp;
  Result := CreateIconIndirect(Info);

  DeleteObject(ColorBmp);
  DeleteObject(MaskBmp);
  DeleteDC(ColorDC);
  DeleteDC(MaskDC);
  ReleaseDC(0, ScreenDC);
end;

{ ---------------------------------------------------------------- トレイ }

procedure FillNotifyData(var AData: TNotifyIconData);
var
  Tip: string;
begin
  ZeroMemory(@AData, SizeOf(AData));
  AData.cbSize := SizeOf(AData);
  AData.Wnd := GWnd;
  AData.uID := TRAY_ID;
  AData.uFlags := NIF_MESSAGE or NIF_ICON or NIF_TIP;
  AData.uCallbackMessage := WM_TRAYICON;
  if GEnabled then
  begin
    AData.hIcon := GIconOn;
    Tip := APP_NAME + ' (有効)';
  end
  else
  begin
    AData.hIcon := GIconOff;
    Tip := APP_NAME + ' (無効)';
  end;
  StrPLCopy(AData.szTip, Tip, Length(AData.szTip) - 1);
end;

procedure TrayAdd;
var
  Data: TNotifyIconData;
begin
  FillNotifyData(Data);
  Shell_NotifyIcon(NIM_ADD, @Data);
end;

procedure TrayUpdate;
var
  Data: TNotifyIconData;
begin
  FillNotifyData(Data);
  Shell_NotifyIcon(NIM_MODIFY, @Data);
end;

procedure TrayDelete;
var
  Data: TNotifyIconData;
begin
  FillNotifyData(Data);
  Shell_NotifyIcon(NIM_DELETE, @Data);
end;

procedure SetEnabled(AValue: Boolean);
begin
  GEnabled := AValue;
  if not GEnabled then
    ReleaseShift;
  SaveSettings;
  TrayUpdate;
end;

procedure ShowAbout;
begin
  // 表示中に再度メニューから選ばれても二重に開かない
  if GAboutShown then
    Exit;
  GAboutShown := True;
  try
    MessageBox(GWnd, PChar(APP_NAME + ' ' + APP_VERSION + sLineBreak + sLineBreak +
      APP_COPYRIGHT + sLineBreak + APP_CONTACT),
      'バージョン情報', MB_OK or MB_ICONINFORMATION or MB_SETFOREGROUND);
  finally
    GAboutShown := False;
  end;
end;

procedure ShowTrayMenu;
const
  CHECKED: array[Boolean] of UINT = (MF_UNCHECKED, MF_CHECKED);
var
  Menu: HMENU;
  Pt: TPoint;
  Cmd: Integer;
begin
  Menu := CreatePopupMenu;
  try
    AppendMenu(Menu, MF_STRING or CHECKED[GEnabled], IDM_ENABLED, '有効(&E)');
    AppendMenu(Menu, MF_STRING or CHECKED[GIncludeDialogs], IDM_DIALOGS,
      '他アプリのファイルダイアログにも適用(&D)');
    AppendMenu(Menu, MF_STRING or CHECKED[IsStartupRegistered], IDM_STARTUP,
      'Windows 起動時に実行(&S)');
    AppendMenu(Menu, MF_SEPARATOR, 0, nil);
    AppendMenu(Menu, MF_STRING, IDM_ABOUT, 'バージョン情報(&A)');
    AppendMenu(Menu, MF_STRING, IDM_EXIT, '終了(&X)');
    SetMenuDefaultItem(Menu, IDM_ENABLED, 0);

    GetCursorPos(Pt);
    SetForegroundWindow(GWnd);
    Cmd := Integer(TrackPopupMenu(Menu, TPM_RETURNCMD or TPM_RIGHTBUTTON or TPM_NONOTIFY,
      Pt.X, Pt.Y, 0, GWnd, nil));
    PostMessage(GWnd, WM_NULL, 0, 0);
  finally
    DestroyMenu(Menu);
  end;

  case Cmd of
    IDM_ENABLED:
      SetEnabled(not GEnabled);
    IDM_DIALOGS:
      begin
        GIncludeDialogs := not GIncludeDialogs;
        SaveSettings;
      end;
    IDM_STARTUP:
      SetStartupRegistered(not IsStartupRegistered);
    IDM_ABOUT:
      ShowAbout;
    IDM_EXIT:
      DestroyWindow(GWnd);
  end;
end;

{ ---------------------------------------------------------------- ウィンドウ }

function WndProc(hWnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  Result := 0;
  case Msg of
    WM_TRAYICON:
      case LOWORD(lParam) of
        WM_RBUTTONUP:
          ShowTrayMenu;
        WM_LBUTTONDBLCLK:
          SetEnabled(not GEnabled);
      end;

    WM_TIMER:
      if wParam = TIMER_RELEASE then
        ReleaseShift;

    WM_DESTROY:
      begin
        UninstallHook;
        TrayDelete;
        PostQuitMessage(0);
      end;

    WM_QUERYENDSESSION:
      Result := 1;

    WM_ENDSESSION:
      if wParam <> 0 then
        UninstallHook;
  else
    if (GTaskbarCreatedMsg <> 0) and (Msg = GTaskbarCreatedMsg) then
      TrayAdd  // Explorer 再起動時にトレイアイコンを再登録
    else
      Result := DefWindowProc(hWnd, Msg, wParam, lParam);
  end;
end;

procedure RunApp;
var
  Mutex: THandle;
  WC: TWndClassEx;
  Msg: TMsg;
begin
  Mutex := CreateMutex(nil, True, MUTEX_NAME);
  if (Mutex = 0) or (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    MessageBox(0, '既に起動しています。', APP_TITLE, MB_OK or MB_ICONINFORMATION);
    Exit;
  end;

  try
    LoadSettings;

    GIconOn := CreateMenuIcon(True);
    GIconOff := CreateMenuIcon(False);

    ZeroMemory(@WC, SizeOf(WC));
    WC.cbSize := SizeOf(WC);
    WC.lpfnWndProc := @WndProc;
    WC.hInstance := HInstance;
    WC.lpszClassName := WND_CLASS;
    WC.hIcon := GIconOn;
    WC.hIconSm := GIconOn;
    if RegisterClassEx(WC) = 0 then
      Exit;

    GWnd := CreateWindowEx(0, WND_CLASS, APP_TITLE, WS_OVERLAPPED,
      0, 0, 0, 0, 0, 0, HInstance, nil);
    if GWnd = 0 then
      Exit;

    GTaskbarCreatedMsg := RegisterWindowMessage('TaskbarCreated');
    // 一般ユーザー権限で動作しても TaskbarCreated を受け取れるようにする
    ChangeWindowMessageFilterEx(GWnd, GTaskbarCreatedMsg, MSGFLT_ALLOW, nil);

    InstallHook;
    if (GHook = 0) or (GKbdHook = 0) then
    begin
      MessageBox(0, 'マウス/キーボードフックの設定に失敗しました。', APP_TITLE, MB_OK or MB_ICONERROR);
      DestroyWindow(GWnd);
      Exit;
    end;

    TrayAdd;

    while GetMessage(Msg, 0, 0, 0) do
    begin
      TranslateMessage(Msg);
      DispatchMessage(Msg);
    end;
  finally
    if GIconOn <> 0 then DestroyIcon(GIconOn);
    if GIconOff <> 0 then DestroyIcon(GIconOff);
    ReleaseMutex(Mutex);
    CloseHandle(Mutex);
  end;
end;

end.
