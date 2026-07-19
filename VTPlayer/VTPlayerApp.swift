//
//  VTPlayerApp.swift
//  VTPlayer
//

import SwiftUI

@main
struct VTPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        Settings {
            MacSettingsView()
        }
        #endif
    }
}

#if os(macOS)
struct MacSettingsView: View {
    @AppStorage("VTShowFileExtensions") private var showFileExtensions = true
    @AppStorage("VTDefaultSRLevel") private var defaultSRLevel = 0
    @AppStorage("VTDefaultQSRLevel") private var defaultQSRLevel = 0
    @AppStorage("VTDefaultFILevel") private var defaultFILevel = 0
    @AppStorage("VTDefaultMBLevel") private var defaultMBLevel = 0
    @AppStorage("VTDefaultDNLevel") private var defaultDNLevel = 0.0
    @AppStorage("VTDefaultSharpness") private var defaultSharpness = 0.0
    @AppStorage("VTDefaultHDRBoost") private var defaultHDRBoost = 0.0

    var body: some View {
        TabView {
            // General Settings Tab - aligned to top
            VStack(alignment: .leading, spacing: 0) {
                Form {
                    Toggle("Show File Extensions in Sidebar", isOn: $showFileExtensions)
                        .toggleStyle(.checkbox)
                }
                Spacer()
            }
            .padding(30)
            .frame(width: 450, height: 180)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            
            // Enhancements/Defaults Tab - aligned to top
            VStack(alignment: .leading, spacing: 0) {
                Form {
                    Picker("Super Resolution:", selection: $defaultSRLevel) {
                        Text("Off").tag(0)
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    
                    Picker("Quality SR:", selection: $defaultQSRLevel) {
                        Text("Off").tag(0)
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    
                    Picker("Frame Interpolation:", selection: $defaultFILevel) {
                        Text("Off").tag(0)
                        Text("2x").tag(2)
                        Text("4x").tag(4)
                    }
                    
                    Picker("Motion Blur Strength:", selection: $defaultMBLevel) {
                        Text("Off").tag(0)
                        ForEach(1...30, id: \.self) { val in
                            Text("\(val)").tag(val)
                        }
                    }
                    
                    Picker("Denoise Strength:", selection: $defaultDNLevel) {
                        Text("Off").tag(0.0)
                        Text("0.25").tag(0.25)
                        Text("0.50").tag(0.50)
                        Text("0.75").tag(0.75)
                        Text("1.00").tag(1.00)
                    }
                    
                    Divider()
                        .padding(.vertical, 8)
                    
                    Slider(value: $defaultSharpness, in: 0.0...2.0, step: 0.05) {
                        Text("Sharpness:")
                    } minimumValueLabel: {
                        Text("Off").font(.caption)
                    } maximumValueLabel: {
                        Text("2.0").font(.caption)
                    }
                    
                    Slider(value: $defaultHDRBoost, in: 0.0...2.0, step: 0.05) {
                        Text("HDR Boost:")
                    } minimumValueLabel: {
                        Text("Off").font(.caption)
                    } maximumValueLabel: {
                        Text("2.0").font(.caption)
                    }
                }
                Spacer()
            }
            .padding(30)
            .frame(width: 480, height: 380)
            .tabItem {
                Label("Default Enhancements", systemImage: "wand.and.stars")
            }
        }
    }
}
#endif
