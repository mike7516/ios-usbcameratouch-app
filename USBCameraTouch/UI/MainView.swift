import SwiftUI

struct MainView: View {
    @StateObject private var vm = MainViewModel()
    @FocusState private var resFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vm.cameraAuthorized {
                CameraPreviewView(previewLayer: vm.previewLayer)
                    .ignoresSafeArea()
                    .gesture(
                        MagnifyGesture()
                            .onChanged { vm.pinchZoom($0.magnification) }
                            .onEnded { _ in vm.endPinch() }
                    )
            } else {
                ContentUnavailableView(
                    "需要相機權限",
                    systemImage: "camera",
                    description: Text("請到「設定」允許本 App 使用相機。")
                )
                .foregroundStyle(.white)
            }

            VStack {
                statusBar
                Spacer()
                resolutionRow
                controls
            }
            .padding()
        }
        .onAppear { vm.onAppear() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { resFocused = false }
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(vm.status.statusText)
                    .font(.footnote)
                Spacer()
            }
            HStack(spacing: 12) {
                Text(String(format: "FPS %.1f", vm.status.fps))
                Text(String(format: "RTT %.0fms", vm.status.responseMs))
                Text(String(format: "%.1f Mbps", vm.status.mbps))
                Spacer()
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                Text("Touch \(vm.touchCount)")
                Text(vm.lastTouch).foregroundStyle(.cyan)
                Spacer()
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                Text("RX \(vm.rxBytes)B")
                Text(vm.rxHex).foregroundStyle(.orange).lineLimit(1)
                Spacer()
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text("NZ \(vm.rxNonZero)")
                Text(vm.rxNonZeroHex).foregroundStyle(.yellow).lineLimit(1)
                Spacer()
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var resolutionRow: some View {
        HStack(spacing: 8) {
            Text("送出解析度").font(.caption2)
            TextField("寬", value: $vm.config.width, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 66)
                .focused($resFocused)
            Text("×")
            TextField("高", value: $vm.config.height, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 66)
                .focused($resFocused)
            Button("套用") { resFocused = false; vm.applyResolution() }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            Spacer()
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { vm.toggleCamera() } label: {
                Image(systemName: "camera.rotate").font(.title2)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            // Screen broadcast — keeps mirroring the whole screen (Home / other
            // apps) after this app is backgrounded, via the ReplayKit extension.
            VStack(spacing: 0) {
                BroadcastPickerView().frame(width: 46, height: 46)
                Text("螢幕").font(.caption2).foregroundStyle(.white)
            }

            Button {
                vm.isStreaming ? vm.stopStreaming() : vm.startStreaming()
            } label: {
                Text(vm.isStreaming ? "停止相機投屏" : "開始相機投屏")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isStreaming ? .red : .accentColor)
            .disabled(!vm.cameraAuthorized)
        }
    }

    private var stateColor: Color {
        switch vm.status.tcpState {
        case .connected:               return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected:            return .red
        case .idle:                    return .gray
        }
    }
}

#Preview {
    MainView()
}
