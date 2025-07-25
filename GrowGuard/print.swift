//
//  print.swift
//  GrowGuard
//
//  Created by veitprogl on 05.03.25.
//
import os

public func print(_ object: Any...) {
    #if DEBUG
    for item in object {
//        Swift.print(item)
    }
    #endif
}

public func print(_ object: Any) {
    #if DEBUG
//    Swift.print(object)
    #endif
}
