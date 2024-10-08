//
//  GrowGuardTests.swift
//  GrowGuardTests
//
//  Created by Veit Progl on 28.04.24.
//

import Testing


// This is just for testing Swift Testing! Has Nothing to do with my app and is completly pointless!

func calcN1(N: Int) -> Int {
    return N + 1
}

@Test("My first new test", arguments: [1,2,3,4])
func someFunThings(n: Int) {
    let result = calcN1(N: n)
    #expect(result == n + 1)
}


@Test("Test someting else")
func somethingelse() async throws {
    let result = calcN1(N: 3)
    #expect(result == 4)
}
