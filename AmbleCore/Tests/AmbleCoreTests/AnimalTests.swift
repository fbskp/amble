import Testing
@testable import AmbleCore

@Suite struct AnimalTests {
    @Test func slothIsAlwaysThere() {
        #expect(AnimalID.unlocked(distanceMeters: 0) == [.sloth])
    }

    @Test func animalsUnlockAtTheirDistance() {
        #expect(AnimalID.unlocked(distanceMeters: 9_999) == [.sloth])
        #expect(AnimalID.unlocked(distanceMeters: 10_000) == [.sloth, .snail])
        #expect(AnimalID.unlocked(distanceMeters: 25_000) == [.sloth, .snail, .tortoise])
    }

    @Test func progressIsClamped() {
        #expect(AnimalID.sloth.progress(distanceMeters: 0) == 1)
        #expect(AnimalID.snail.progress(distanceMeters: 5_000) == 0.5)
        #expect(AnimalID.tortoise.progress(distanceMeters: 99_000) == 1)
        #expect(AnimalID.tortoise.progress(distanceMeters: -5) == 0)
    }

    @Test func unlockOrderMatchesDistanceOrder() {
        let distances = AnimalID.allCases.map(\.unlockDistanceMeters)
        #expect(distances == distances.sorted())
    }
}
