//
//  HelloApp.swift
//  Hello
//
//  Created by wang.lun on 2025/08/03.
//

import SwiftUI

@main
struct HelloApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    willAppear()
                }
        }
    }

    private func willAppear() {
        print("HelloApp willAppear")
    }
}
