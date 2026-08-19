# M1 — Xcode 組裝與驗證

> 這台環境只能寫 Swift 原始碼，**無法產生 `.xcodeproj` / 編譯 / 上機**。以下在你的 Mac（Xcode 26）操作。
> M1 目標：**相機 → 8808 顯示器**（尚不含觸摸控相機，那是 M2）。

## 一、已產出的檔案（`USBCameraTouch_IOS/USBCameraTouch/`）

| 目錄 | 檔案 | 來源 |
|---|---|---|
| `Network/` | `TCPTransport.swift` | 複製沿用 |
| `JPEG/` | `JPEGEncoder.swift`、`JPEGSamplingInspector.swift` | 複製沿用 |
| `Runtime/` | `RuntimeBridge.swift` | 複製沿用 |
| `Runtime/` | `RuntimeConstants.swift` | 改：`appGroupID=group.wen.usbcameratouch`、移除 extension id |
| `Model/` | `AppModels.swift` | 擴充：`cameraPosition` / `touchFocus/Exposure/Zoom`、預設 1280×720 continuous |
| `Sender/` | `FrameStreamSender.swift` | 新：從 `BroadcastStreamController` 抽出（encode+pacing+ACK+metrics） |
| `Camera/` | `CameraCaptureController.swift` | 新：AVFoundation 擷取 → `sender.submit` |
| `App/` | `USBCameraTouchApp.swift`、`MainViewModel.swift` | 新 |
| `UI/` | `MainView.swift`、`CameraPreviewView.swift` | 新 |
| `Support/` | `Info.plist`、`USBCameraTouch.entitlements` | 新 |
| `Reverse/` | （空，M2 放 `ReverseChannelParser`/`TouchController`） | — |

## 二、Xcode 建立 target 並加入 source

1. **New Project** → iOS → **App**。Product Name `USBCameraTouch`，Interface **SwiftUI**，Language **Swift**。
2. **Bundle Identifier** `wen.usbcameratouch`，**Team** `UQJKPW4GW8`。
3. 專案建到 `/Users/test/Documents/USBCameraTouch_IOS/`（可先建到別處再把 `USBCameraTouch/` 這些 source 拖進來）。
4. **刪掉範本**自動產生的 `ContentView.swift` 與 `XxxApp.swift`（用本專案的 `USBCameraTouchApp.swift` / `MainView.swift`）。
5. 把 `USBCameraTouch/` 底下**所有 `.swift`** 加入 App target（拖進 Xcode，勾選 *Add to target*）。目錄可用 group 或 folder reference。
6. **Signing & Capabilities**：
   - 設 Team。
   - **+ Capability → App Groups**，勾 `group.wen.usbcameratouch`（或用 `Support/USBCameraTouch.entitlements`）。
7. **Info**：加 `NSCameraUsageDescription`（用 `Support/Info.plist` 的字串，或在 target Info 頁手動加）。
8. **Deployment Target** iOS 26（對齊 `USBDisplay`）。

> App Group 供 `RuntimeBridge` 寫 `metrics.csv` 到共享容器，方便日後 `devicectl` 拉取分析（沿用 USBDisplay 慣例）。

## 三、連線前提

- iPhone 透過 **USB-NCM** 取得 `192.168.0.x`，8808 為顯示端／DHCP，裝置位址 `192.168.0.1:7658`（`RuntimeConstants`）。
- 出站是**純 JPEG**（`FF D8 … FF D9`），與 8808 現有接收端相容，設備端 M1 不需改。

## 四、M1 驗證步驟

1. 跑 App → 允許相機 → 看到**本機預覽**（後鏡頭）。
2. 接上 8808（USB-NCM）→ 狀態列轉 **connected**（`192.168.0.1:7658`）。
3. 按 **開始投屏** → 8808 顯示器出現**相機即時畫面**。
4. 狀態列 **FPS / RTT / Mbps** 有數字跳動；App Group 容器出現 `metrics.csv`（逐幀）。
5. 「相機翻轉」可切前/後鏡頭。

✅ 出現即時畫面 + FPS/RTT 有值 = **M1 達成**。

## 五、M1 已知限制（M2 處理）

- **反向通道**：M1 沿用「每個 byte 當一個 ACK」（`FrameStreamSender.onReverseBytes == nil`），只做流量控制/RTT，**未解析觸摸**。M2 會設 `onReverseBytes` 接 `ReverseChannelParser`，改吃 `0x01`(ACK)/`0x02`(TOUCH)。
- **畫面方向/座標**：`CameraCaptureController` 先設 `videoRotationAngle = 90`（portrait）；送出影像方向要與 M2 的觸摸座標映射一致，屆時實機四角校正（SPEC §5）。
- **比例**：`JPEGEncoder` 是 stretch 到 `width×height`；相機 16:9/4:3 與面板比例不同會變形，M3 視需要加 letterbox。
- **觸摸控相機**（對焦/曝光）＝ M2，**依賴 FW 回覆 SPEC §10.4**（ACK 是否為 `0x01`、座標分工 A/B 等）。

## 六、下一步（M2 前置）

1. 建立 Xcode target、完成上面組裝、跑通 M1。
2. 收 FW 對 SPEC §10.4 的回覆 → 定案座標分工與 `0x01/0x02` 格式。
3. 進 M2：`Reverse/ReverseChannelParser.swift` + `Reverse/TouchController.swift`，把 `sender.onReverseBytes` 接上。
