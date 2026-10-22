import SwiftUI

@main
struct PulseApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor
    @AppStorage("menuBarStyle") private var style: String = "both"

    var body: some View {
        let cpu = "\(Int(monitor.system.cpu.rounded()))%"
        let temp = monitor.thermal.cpu.map { "\(Int($0.rounded()))°" }

        switch style {
        case "icon":
            Image(systemName: "waveform.path.ecg")
        case "cpu":
            Text("\(Image(systemName: "waveform.path.ecg")) \(cpu)").monospacedDigit()
        case "temp":
            Text("\(Image(systemName: "thermometer")) \(temp ?? cpu)").monospacedDigit()
        default:
            if let temp = temp {
                Text("\(Image(systemName: "waveform.path.ecg")) \(cpu)  \(temp)").monospacedDigit()
            } else {
                Text("\(Image(systemName: "waveform.path.ecg")) \(cpu)").monospacedDigit()
            }
        }
    }
}
