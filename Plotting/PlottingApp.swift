//
//  PlottingApp.swift
//  Plotting
//
//  Created by Kevin Long on 6/14/26.
//

import SwiftUI
import CoreData

@main
struct PlottingApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
