# USBCameraTouch iOS — App 規格書 (Draft v0.1)

> 姊妹專案:`USBDisplay_IOS_Standalone_From_Python`(螢幕 → 設備)。
> 本 App 把來源從「螢幕擷取」換成「相機」,並**新增一條反向的觸摸訊號接口**(設備 → App)。
> 建議專案路徑:`/Users/test/Documents/USBCameraTouch_IOS/`
>
> ⚠️ 標示 **[待確認]** 的項目請先幫我確認(集中在文末「開放問題」),會影響設計方向。

---

## 1. 概述

一支 iOS App:
1. 擷取 **iPhone 相機**畫面 → 編碼 JPEG → 透過 **USB / NCM 本地網路 TCP** 傳給設備(`192.168.0.1:7658`)顯示。
2. 開一個**觸摸訊號接口**:設備(外接觸控螢幕)上的觸摸事件,透過同一條 TCP 連線**回傳**給 App;App 依觸摸點對相機做對應動作(對焦/曝光/縮放…)。

本質上 = **把 `USBDisplay` 的視訊來源從 ReplayKit 螢幕換成 AVFoundation 相機,並把既有的「1-byte ACK 反向通道」擴充成可攜帶觸摸事件**。因此可大量重用既有、且已在實機驗證/優化過的元件。

---

## 2. 目標與範圍

**In scope**
- 相機即時擷取 + 原生 JPEG 編碼 + 純 JPEG over TCP(沿用既有線路格式)。
- ACK 流量控制(沿用,已證實能消除延遲累積與秒級尖峰)。
- 設備 → App 的觸摸事件接收與解析(新協定)。
- 觸摸 → 相機控制(對焦/曝光,選配縮放)。
- 前/後鏡頭、解析度、品質、Target FPS 可設定。
- 逐幀 metrics(沿用 `metrics.csv` + RTT/ACK 機制)。

**Out of scope(初版不做)**
- 錄影/存檔、音訊、多相機同時、HDR/夜景等進階拍攝。
- 螢幕擷取(那是 `USBDisplay` 的職責)。
- 觸摸事件轉發到第三方(初版僅用於本機相機控制)。[待確認]

**平台**:iOS(單一 App target,**不需要 Broadcast Extension**,因相機用 AVFoundation 於 App 內即可)。deployment target 對齊 `USBDisplay`(iOS 26.x / Xcode 26)。

---

## 3. 系統架構

```
 ┌──────────────────────────── iPhone App ────────────────────────────┐
 │  AVCaptureSession (camera)                                          │
 │      └─ AVCaptureVideoDataOutput → CMSampleBuffer                   │
 │            └─ JPEGEncoder(原生 CoreImage/ImageIO)→ JPEG            │
 │                  └─ TCPTransport ── 純 JPEG(FF D8…FF D9)──────────┐ │
 │  TouchController ◀── 解析 0x02 觸摸封包 ◀── TCPTransport.onData ◀─┘ │
 │      └─ 座標映射 → AVCaptureDevice 對焦/曝光/縮放                  │
 │  Metrics/RuntimeBridge(逐幀 CSV、RTT)                             │
 └────────────────────────────────────────────────────────────────────┘
                         │ USB / NCM (TCP 192.168.0.1:7658)
                         ▼
                 ┌───────────────────────┐
                 │ 設備(外接觸控顯示器) │
                 │  收 JPEG → 解碼 → 顯示 │
                 │  回 0x01 ACK / 觸摸    │
                 └───────────────────────┘
```

- **出站(App → 設備)**:與 `USBDisplay` 完全相同 —— 連續的純 JPEG,無 HEADER32、無長度前綴。
- **入站(設備 → App)**:在**同一條 TCP 連線**上,擴充既有反向通道(目前只有 `0x01` ACK)以攜帶觸摸事件(見 §6)。

---

## 4. 功能需求

### 4.1 相機擷取
- `AVCaptureSession`,`AVCaptureVideoDataOutput`(BGRA 或 YUV)→ `CMSampleBuffer`。
- 前/後鏡頭切換;預設**後鏡頭**。[待確認]
- 解析度(sessionPreset 或自訂輸出尺寸)可設定;預設對齊設備顯示,例如 1280×720。
- 影格率上限 = Target FPS(沿用 `targetFps`)。
- App 內即時預覽(`AVCaptureVideoPreviewLayer` 或用送出的 JPEG 回顯)。

### 4.2 編碼 / 傳輸(重用)
- **`JPEGEncoder`**:直接沿用 `USBDisplay` 的原生編碼器(CMSampleBuffer → resize → JPEG)。
- **`TCPTransport`**:沿用(noDelay、keepalive、自動重連 1s)。
- **ACK 流量控制**:沿用(送一張 → 等 `0x01` ACK 或 0.5s 逾時 → 送下一張)。在途幀數 = 1。
- 送圖格式:純 JPEG(不變),與設備現有接收端相容。

### 4.3 觸摸訊號接口(新)
- 從 `TCPTransport.onData` 讀入反向位元流,依 §6 協定解析:
  - `0x01` → 每幀 ACK(沿用,用於流量控制 + RTT)。
  - `0x02` → 觸摸事件(action / id / x / y)。
- 解析出的觸摸事件送入 `TouchController`。

### 4.4 觸摸 → 相機控制(預設行為,可設定)[待確認]
- **點按(down→up 同點)** → 在該點設定相機**對焦 + 曝光** POI(`focusPointOfInterest` / `exposurePointOfInterest`,座標 0..1)。
- **拖曳** → 調整曝光補償(選配)或忽略。
- **雙指** → 縮放 `videoZoomFactor`(選配)。
- 座標映射:設備回傳的 (x,y) 定義為「**送出影像的像素座標系**」(即目前 Width×Height),App 換算成相機/預覽座標與 POI。

### 4.5 設定 UI
- 開始/停止串流、鏡頭切換(前/後)。
- 解析度、JPEG 品質、Target FPS、ACK 流量控制開關(沿用 `USBDisplay` 的 UI 模式)。
- 觸摸行為選擇(對焦/曝光/縮放 開關)。[待確認]
- 連線狀態橫幅 + TEST TCP(沿用)。

### 4.6 量測(重用)
- 沿用 `RuntimeBridge` 的 `metrics.csv`(App Group 共享容器)與逐幀欄位;RTT 即「送出 → 收到 `0x01`」。
- 因無擴充,App 為單一程序,亦可直接寫檔到自身容器;仍建議沿用共享容器以便 `devicectl` 拉取分析。

---

## 5. 非功能需求
- **延遲**:端到端(擷取→送出完成)與 `USBDisplay` 同等級;沿用 ACK 節流避免延遲累積。
- **觸摸延遲**:設備觸摸 → App 反應(對焦)目標 < 100ms(受設備回傳頻率影響)。[待確認 目標值]
- **穩定性**:斷線自動重連;觸摸解析需容錯(半包/黏包處理,見 §6.3)。
- **相容性**:出站格式與設備現有 JPEG 接收端不變,設備端只需**新增觸摸事件的傳送**。

---

## 6. 通訊協定

### 6.1 出站:App → 設備(不變)
- 連續純 JPEG:`FF D8 … FF D9`,`FF D8 … FF D9` …
- 無 HEADER32、無長度前綴、無封包框。

### 6.2 入站:設備 → App(擴充既有反向通道)
在同一條 TCP 連線上,以 **1-byte 型別標籤**分辨訊息:

| 型別 | 名稱 | 後續位元組 | 說明 |
|---|---|---|---|
| `0x01` | ACK | 無 | 每處理完一幀回一個(沿用,用於流量控制 + RTT) |
| `0x02` | TOUCH | 6 bytes | 觸摸事件(見下) |

**TOUCH(0x02)封包 = 共 7 bytes:**

| 位移 | 欄位 | 型別 | 說明 |
|---|---|---|---|
| 0 | type | u8 | `0x02` |
| 1 | action | u8 | 0=down, 1=move, 2=up, 3=cancel |
| 2 | touchId | u8 | 多點觸控 id(0..N);單點固定 0 |
| 3–4 | x | u16 (big-endian) | 送出影像像素座標 X |
| 5–6 | y | u16 (big-endian) | 送出影像像素座標 Y |

> 可擴充:壓力、時間戳可日後加型別 `0x03`。[待確認 是否需要多點/壓力]

### 6.3 解析注意
- TCP 是位元流,需自行**累積緩衝 + 依型別長度切包**(處理半包/黏包)。
- `0x01` 與 `0x02` 混流:讀到型別後,`0x01` 消費 1 byte、`0x02` 需再湊滿 6 bytes 才成立,否則留在緩衝等下一段。

---

## 7. 重用既有元件(來自 USBDisplay)

| 元件 | 重用方式 |
|---|---|
| `JPEGEncoder.swift` | 直接沿用(CMSampleBuffer → JPEG) |
| `TCPTransport.swift` | 直接沿用(含 `onData` 反向通道) |
| ACK 流量控制邏輯 | 沿用(BroadcastStreamController 的 pacing 抽出成共用 sender) |
| `RuntimeBridge` / `metrics.csv` | 沿用(逐幀 CSV、RTT) |
| `RuntimeConstants`(host/port/timeout) | 沿用 |
| UI 模式(狀態橫幅 / 設定 / 統計) | 沿用版型 |
| **新寫**:`CameraCaptureController` | AVFoundation 擷取,取代 ReplayKit `SampleHandler`/`BroadcastStreamController` |
| **新寫**:`TouchController` + 觸摸解析 | 反向通道解析 + 相機控制 |

> 建議把 `USBDisplay` 的 sender/pacing/JPEG/transport 抽成一個共用層,兩個 App 共享,避免分叉。[待確認 是否要共用 package]

---

## 8. 里程碑(建議)
1. **M1**:AVFoundation 擷取 + 原生 JPEG + TCP 送出(沿用 transport/pacing)→ 設備看到相機畫面。
2. **M2**:反向通道協定(0x01/0x02)解析 + `TouchController`;點按對焦/曝光。
3. **M3**:縮放/曝光補償、前後鏡頭、設定 UI、metrics 面板。
4. **M4**:實機調校(RTT、FPS、觸摸延遲)、穩定性(重連、容錯)。

---

## 9. 開放問題(請確認,會影響設計)

1. **相機資料流向**:確認是「相機 → 送到設備顯示」(本規格假設),而非「App 顯示遠端相機」?
2. **觸摸訊號來源與用途**:
   - 觸摸是**設備(外接觸控螢幕)產生、回傳給 App**(本規格假設)嗎?
   - 觸摸要做什麼?**對焦/曝光**(假設)?還是縮放、拍照快門、或**只是把座標轉發**給別的系統?
3. **觸摸傳輸方式**:走**同一條 TCP**(本規格假設,擴充 0x01/0x02),還是**另開一個 port / UDP**?
4. **觸摸封包格式**:上面 §6.2 的 7-byte 格式可接受嗎?需要**多點觸控 / 壓力 / 時間戳**嗎?座標是「送出影像像素座標」還是設備自己的螢幕解析度(需回報解析度做映射)?
5. **觸摸延遲 / 頻率目標**:設備多久回一次觸摸?可接受的反應延遲上限?
6. **是否與 `USBDisplay` 共用一個程式庫**(抽共用層),還是各自獨立複製?
7. **專案命名 / bundle id / Team**:沿用同一個個人帳號(Team `UQJKPW4GW8`)嗎?bundle id 命名(例:`wen.usbcamera`)?
8. **App 內是否需要顯示相機預覽**,還是純送出(無本機預覽)?

---

## 10. 裝置端(8808 FW)反向通道需求 — 待 FW 團隊評估

> 本節把 §6 的 App 端協定,整理成對**裝置端(8808 韌體)**的對應需求,交 FW 團隊評估可行性。
> App 端會把既有反向通道(目前每幀回 1-byte,App 端只計數、不檢查值)升級為**型別協定**,故裝置端送出格式需同步調整。

### 10.1 FW 需送出的格式(設備 → App,與 JPEG 走同一條 TCP,方向相反)

| type | 名稱 | 長度 | 內容 | 時機 |
|---|---|---|---|---|
| `0x01` | ACK | 1 B | 無 | 每處理完一幀回一個(維持 App 端流量控制 / RTT) |
| `0x02` | TOUCH | 7 B | `type, action(u8), touchId(u8), x(u16 BE), y(u16 BE)` | 觸控事件發生時 |

- `action`:0=down, 1=move, 2=up, 3=cancel
- `x/y`:**big-endian**
- 兩種訊息在同一位元流交錯,App 端依型別長度切包(0x01 消費 1 byte、0x02 需湊滿 7 bytes)。
- **相容性關鍵**:升級後 App 端會**檢查型別 byte**。若 ACK 送的不是 `0x01`,App 端 ACK gate 會等不到、掉到 0.5s 逾時節奏、**FPS 砍半**。故 ACK 必須固定送 `0x01`。

### 10.2 座標系分工(關鍵評估點)

App 端期望的 (x,y) 是「**送出影像的像素座標**」(即 App 目前送出 JPEG 的 width×height,例 1280×720),不是面板原生解析度——App 端只有送出影像尺寸,用它映射相機對焦點最直接。故需有人把「觸控 IC / 面板座標」換算成「送出影像像素座標」。兩種分工請 FW 評估:

- **方案 A(建議):設備端映射**。設備端把面板觸摸點換算成「當前顯示影像的像素座標」再送;設備端解碼 JPEG 時本就知道該幀 width×height,可當映射目標,App 端零負擔。
- **方案 B:設備端送原生座標**。設備端送面板 / IC 座標,並(握手或每包)告知座標範圍,由 App 換算;需擴充封包或加握手訊息。

### 10.3 頻率與節流(避免排擠 ACK)

觸摸與 ACK 共用同一條 TCP。`move` 事件請 FW 端**限制上限頻率(建議 ≤ 60Hz)並加位移門檻**(移動小於 N 像素不送),避免高頻 move 洗掉頻寬、拖慢每幀 ACK(App 端 ACK 節流:在途一幀,等 ACK 或 0.5s 逾時)。

### 10.4 請 FW 團隊回覆的評估點

1. 目前每幀回的 ACK 實際送什麼 byte?改成固定 `0x01` 可行嗎?
2. 觸控 IC 能否提供 action(down/move/up/cancel)、多點 touchId?初版可否至少做單點(id=0)的 down/up?
3. 座標分工採 §10.2 方案 A 或 B?設備端拿得到「當前顯示影像尺寸」嗎?
4. `move` 頻率、位移門檻可控嗎?
5. 反向通道(0x01 / 0x02 交錯)與現有 JPEG 接收在時序上有無衝突?

> 註:2ndbrain `觸摸反控-規格需求.md` 第十節另有一套 `'TC'` 開頭的觸控封包格式(用於「螢幕投屏反控 iPhone」場景)。本專案(相機 + 控相機)採用上表 `0x01/0x02`。若兩專案想共用同一套裝置端反向通道,需 FW 與 App 端先收斂協定,避免裝置端維護兩套格式。

---

## 11. 決議摘要(對應 §9 開放問題,2026-08-18)

| # | 開放問題 | 決議 |
|---|---|---|
| 1 | 相機資料流向 | 相機 → 送設備顯示,確認。 |
| 2 | 觸摸來源 / 用途 | 設備觸控螢幕回傳;初版**點按對焦 + 曝光**,拖曳 / 雙指縮放延 M3。 |
| 3 | 傳輸方式 | **同一條 TCP**,擴充 `0x01 / 0x02`。 |
| 4 | 封包格式 | 7-byte 可接受;座標 =**送出影像像素座標**(分工見 §10.2);初版單點(id=0),雙指縮放於 M3,壓力 / 時間戳日後 `0x03`。 |
| 5 | 延遲 / 頻率 | 反應目標 < 100ms;`move` 節流交 FW(§10.3)。 |
| 6 | 共用程式庫 | **先各自複製**(不抽 package),M3 穩定後再評估共用。 |
| 7 | 命名 / bundle / Team | bundle `wen.usbcameratouch`、App Group `group.wen.usbcameratouch`、Team `UQJKPW4GW8`(參考 `USBDisplay`)。 |
| 8 | App 內預覽 | 要,用 `AVCaptureVideoPreviewLayer`。 |

實作展開見 `Docs/IMPLEMENTATION_PLAN.md`。

---

## 12. 協定對齊：改用 8808 已實作的 `'TC'` 協定(2026-08-18)

> 讀 8808 端規格(2ndbrain `觸摸反控-規格需求.md` §10.4)後確認:**裝置端已實作觸控反向通道**
> (`touch_feedback.c`, `struct touch_feedback_contact`, `#pragma pack(1)`),用 `'TC'` 協定,
> 非本文 §6.2/§10 假設的 `0x01/0x02`。**協定收斂到已實作的一方:App 端 M2 改吃 `'TC'`,
> §6.2/§10 的 `0x01/0x02` 作廢。**

### 12.1 `'TC'` 觸控封包(8808 → App,同一條 TCP)
```
'T' 'C' (0x54 0x43) | contact_count(1B, 0-2) | 每點連續 6B: touch_id(1B) + x(2B LE) + y(2B LE) + tip_switch(1B)
```
- 單點 9B、雙點 15B(`3 + count*6`)。
- `tip_switch`:1=down, 0=剛放開。
- 座標 `x/y`:**little-endian**(注意:與 §6.2 舊提案的 big-endian 相反,以 8808 實作為準)。

### 12.2 ACK(FW 已補上)
- 8808 端**每處理完一幀回一個 ACK**(FW 2026-08-18 補上),`FrameStreamSender` 流量控制(在途一幀)沿用即可,不需改 `ackPaced`。
- ACK 與 `'TC'` 在反向通道**交錯**。`ReverseChannelParser` 用 magic `0x54 0x43` + 結構(count 0-2、長度足)辨識 `'TC'`;**其餘 bytes 視為 ACK**(每 byte 一個)。此設計不需預先知道 ACK 的確切值,只要 ACK 不構成一個合法 `'TC'` 封包(建議 8808 端 ACK 避開 `0x54`)。

### 12.3 座標(App 端二次換算)
- `'TC'` 送 **640×1136 面板座標**(8808 面板,見 8808 §10.5),非相機送出影像座標。
- App 端:`nx = x/640, ny = y/1136` → 依 `videoRotationAngle`/鏡像轉成 `focus/exposurePointOfInterest`(0..1)。假設面板為送出影像全螢幕拉伸;方向/鏡像 M2 實機四角校正。

### 12.4 事件語意(App 端推導)
- `'TC'` 只有 `tip_switch(1/0)`,無 `move/cancel`。依同一 `touch_id` 序列推導:首見 `tip=1`→down;`tip=1` 座標變→move;`tip 1→0`→up。tap 對焦:down 後短時間、位移小的 up → 設 focus+exposure POI。

### 12.5 M2 影響
- `Reverse/ReverseChannelParser.swift`:解析 `'TC'` + ACK 區分;`onAck → sender.ackReceived()`、`onTouch → TouchController`。
- `Reverse/TouchController.swift`:640×1136 → POI 換算 + `AVCaptureDevice` 對焦/曝光。
- 接線:`sender.onReverseBytes = { parser.feed($0) }`(關掉 M1「每 byte 當 ACK」內建路徑)。

---

*Draft v0.3 — v0.1 依 `USBDisplay` 現有架構推導;v0.2(2026-08-18)追加 §10 裝置端需求、§11 決議摘要;v0.3(2026-08-18)§12 協定對齊到 8808 已實作的 `'TC'`(取代 §6.2/§10 的 `0x01/0x02`),ACK 由 FW 補上。*
