//
//  ContentView.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VTPlayerView()
            #if os(macOS)
            .frame(minWidth: 800, minHeight: 600)
            #endif
    }
}

#Preview {
    ContentView()
}
