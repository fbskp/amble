import Foundation
import AmbleCore

/// The achievements' names and descriptions, as translatable text.
extension AchievementID {
    var title: LocalizedStringResource {
        switch self {
        case .firstSteps: "First Steps"
        case .slowAndSteady: "Slow and Steady"
        case .branchToBranch: "Branch to Branch"
        case .threeToed: "Three-Toed"
        case .leafEater: "Leaf Eater"
        case .hangingOn: "Hanging On"
        case .treetopHabit: "Treetop Habit"
        case .aroundTheTree: "Around the Tree"
        case .slothMarathon: "Sloth Marathon"
        case .canopyCrossing: "Canopy Crossing"
        case .unhurried: "Unhurried"
        case .nightShift: "Night Shift"
        case .earlySloth: "Early Sloth"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .firstSteps: "Finish your first walk."
        case .slowAndSteady: "Walk 30 minutes in one go."
        case .branchToBranch: "Walk 60 minutes in one go."
        case .threeToed: "Walk 3 times in one week."
        case .leafEater: "Reach your weekly goals."
        case .hangingOn: "Walk in 4 weeks in a row."
        case .treetopHabit: "Reach your weekly goals 3 weeks in a row."
        case .aroundTheTree: "Walk 10 km in total."
        case .slothMarathon: "Walk 42.2 km in total."
        case .canopyCrossing: "Walk 100 km in total."
        case .unhurried: "Spend 10 hours walking in total."
        case .nightShift: "Start a walk after 9 pm."
        case .earlySloth: "Start a walk before 9 am."
        }
    }
}
