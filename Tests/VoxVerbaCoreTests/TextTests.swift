import Testing
import Foundation
@testable import VoxVerbaCore

@Suite("Spoken number canonicalization")
struct SpokenNumbersTests {

    private func canon(_ text: String) -> [String] {
        TextTokenizer.comparableTokens(text)
    }

    @Test("Number words fold to digits")
    func numberWords() {
        #expect(canon("five hundred") == ["500"])
        #expect(canon("three hundred and twelve") == ["312"])
        #expect(canon("twenty one") == ["21"])
        #expect(canon("one thousand") == ["1000"])
        #expect(canon("two million") == ["2000000"])
        #expect(canon("seven") == ["7"])
    }

    @Test("Digits and number words land on the same token")
    func digitsAgree() {
        // The engine writes "500" where the speaker said "five hundred". Both
        // must compare equal or a correct transcript scores as three errors.
        #expect(canon("we sold five hundred units") == canon("we sold 500 units"))
        #expect(canon("three hundred and twelve") == canon("312"))
        #expect(canon("1,000") == ["1000"])
    }

    @Test("Ordinals fold to their cardinal digits")
    func ordinals() {
        #expect(canon("the third quarter") == canon("the 3rd quarter"))
        #expect(canon("twenty first") == ["21"])
        #expect(canon("first") == ["1"])
    }

    @Test("Different quantities stay different")
    func distinctValuesStayDistinct() {
        // The property the polish validator depends on: normalization must not
        // erase the difference between 500 and 1,000.
        #expect(canon("five hundred") != canon("one thousand"))
        #expect(canon("500") != canon("1000"))
        #expect(canon("approximately one thousand") != canon("five hundred"))
    }

    @Test("Ordinary words are untouched")
    func wordsSurvive() {
        #expect(canon("the quick brown fox") == ["the", "quick", "brown", "fox"])
        // "and" outside a number run stays a word.
        #expect(canon("bread and butter") == ["bread", "and", "butter"])
    }

    @Test("Case and punctuation are discarded")
    func normalization() {
        #expect(canon("Hello, World!") == ["hello", "world"])
        #expect(canon("David's") == ["david's"])
    }

    @Test("A number run ends where the number ends")
    func runBoundaries() {
        #expect(canon("five hundred units in the third quarter")
                == ["500", "units", "in", "the", "3", "quarter"])
    }
}
