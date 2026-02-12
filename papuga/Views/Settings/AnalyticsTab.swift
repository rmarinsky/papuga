import SwiftUI
import Defaults

struct AnalyticsTab: View {
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Default(.analyticsDayStamp) private var analyticsDayStamp
    @Default(.savedSecondsToday) private var savedSecondsToday

    var body: some View {
        Form {
            Section("Підсумок") {
                HStack {
                    Text("Заміни виконано")
                    Spacer()
                    Text("\(textReplacementCount)")
                        .monospacedDigit()
                }

                HStack {
                    Text("Замінено слів")
                    Spacer()
                    Text("\(totalReplacedWords)")
                        .monospacedDigit()
                }

                HStack {
                    Text("Сьогодні зекономлено секунд")
                    Spacer()
                    Text("\(todaySavedSeconds)")
                        .monospacedDigit()
                }

                HStack {
                    Text("Зекономив секунд життя")
                    Spacer()
                    Text("\(estimatedSecondsSaved)")
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var estimatedSecondsSaved: Int {
        Constants.estimatedSecondsSaved(replacementCount: textReplacementCount, totalWords: totalReplacedWords)
    }

    private var todaySavedSeconds: Int {
        analyticsDayStamp == Constants.currentDayStamp() ? savedSecondsToday : 0
    }
}
