import Testing
@testable import PrompterCore

struct PickerListTests {
    // header, item, item, header, item
    private let rows = [false, true, true, false, true]

    @Test func moveSkipsHeadersAndWraps() {
        #expect(PickerList.move(from: 1, by: 1, selectable: rows) == 2)
        #expect(PickerList.move(from: 2, by: 1, selectable: rows) == 4)
        #expect(PickerList.move(from: 4, by: 1, selectable: rows) == 1)
        #expect(PickerList.move(from: 1, by: -1, selectable: rows) == 4)
        #expect(PickerList.move(from: 4, by: -1, selectable: rows) == 2)
    }

    @Test func moveWithoutCurrentStartsFromAnEnd() {
        #expect(PickerList.move(from: nil, by: 1, selectable: rows) == 1)
        #expect(PickerList.move(from: nil, by: -1, selectable: rows) == 4)
    }

    @Test func moveWithNothingSelectableIsNil() {
        #expect(PickerList.move(from: nil, by: 1, selectable: []) == nil)
        #expect(PickerList.move(from: 0, by: 1, selectable: [false, false]) == nil)
    }

    @Test func ordinalCountsOnlySelectableRows() {
        #expect(PickerList.ordinal(1, selectable: rows) == 1)
        #expect(PickerList.ordinal(3, selectable: rows) == 4)
        #expect(PickerList.ordinal(4, selectable: rows) == nil)
        #expect(PickerList.ordinal(0, selectable: rows) == nil)
    }
}

struct PathLabelTests {
    @Test func homeIsAbbreviated() {
        #expect(PathLabel.folder(of: "/Users/me/Documents/notes/a.md", home: "/Users/me") == "~/Documents/notes")
        #expect(PathLabel.folder(of: "/Users/me/a.md", home: "/Users/me/") == "~")
    }

    @Test func directoriesAbbreviateTheSameWay() {
        #expect(PathLabel.abbreviated("/Users/me/Documents", home: "/Users/me") == "~/Documents")
        #expect(PathLabel.abbreviated("/Users/me", home: "/Users/me") == "~")
        #expect(PathLabel.abbreviated("/", home: "/Users/me") == "/")
    }

    @Test func otherFoldersAreUnchanged() {
        #expect(PathLabel.folder(of: "/Volumes/x/a.md", home: "/Users/me") == "/Volumes/x")
        #expect(PathLabel.folder(of: "/Users/meow/a.md", home: "/Users/me") == "/Users/meow")
        #expect(PathLabel.folder(of: "a.md", home: "/Users/me") == "/")
    }
}
