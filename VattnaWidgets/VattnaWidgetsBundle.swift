//
//  VattnaWidgetsBundle.swift
//  VattnaWidgets
//
//  Created by veitprogl on 21.11.25.
//

import WidgetKit
import SwiftUI

@main
struct VattnaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        VattnaWidgets()
        VattnaWidgetsControl()
        VattnaWidgetsLiveActivity()
    }
}
