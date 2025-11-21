//
//  GrowGuardWidgetsBundle.swift
//  GrowGuardWidgets
//
//  Created by veitprogl on 21.11.25.
//

import WidgetKit
import SwiftUI

@main
struct GrowGuardWidgetsBundle: WidgetBundle {
    var body: some Widget {
        GrowGuardWidgets()
        GrowGuardWidgetsControl()
        GrowGuardWidgetsLiveActivity()
    }
}
