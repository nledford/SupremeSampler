import XCTest

@testable import SupremeSampler

/// Rule edits are undoable.
@MainActor
final class RuleUndoAndSessionTests: XCTestCase {
    // MARK: - Undo

    func test_givenAnUndoManager_whenARuleIsAddedThenUndone_thenTheRulesGoBack() {
        let model = SampleBuilderModel.forTesting()
        let undoManager = UndoManager()
        // A plain `UndoManager` groups by run-loop event; tests make one
        // group per edit by hand instead.
        undoManager.groupsByEvent = false
        model.undoManager = undoManager

        undoManager.beginUndoGrouping()
        model.rules.add(.rating)
        undoManager.endUndoGrouping()
        XCTAssertEqual(model.rules.rules.count, 1)
        XCTAssertEqual(undoManager.undoActionName, "Rule Change")

        undoManager.undo()
        XCTAssertTrue(model.rules.rules.isEmpty)

        undoManager.redo()
        XCTAssertEqual(model.rules.rules.count, 1)
    }

    func test_givenAnUndoManager_whenARemovedNestedGroupIsUndone_thenTheWholeGroupComesBack() {
        let model = SampleBuilderModel.forTesting()
        model.rules.addGroup()
        if case .group(var nested) = model.rules.rules[0].content {
            nested.add(.keyword)
            nested.add(.path)
            model.rules.rules[0].content = .group(nested)
        }
        let before = model.rules
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager

        undoManager.beginUndoGrouping()
        model.rules.removeRule(id: model.rules.rules[0].id)
        undoManager.endUndoGrouping()
        undoManager.undo()

        XCTAssertEqual(model.rules, before)
    }

    func test_givenNoUndoManager_whenEditingRules_thenNothingBreaks() {
        let model = SampleBuilderModel.forTesting()
        model.rules.add(.rating)
        XCTAssertEqual(model.rules.rules.count, 1)
    }

}

/// While a rule's text field is focused, AppKit's field editor undoes the
/// typing itself; the model registers the whole edit as one step when
/// editing ends, instead of once per debounced commit (which put each
/// edit on the stack twice and made ⌘Z bounce between old and new text).
@MainActor
final class TextEditUndoTests: XCTestCase {
    private func modelWithPathRule() -> (SampleBuilderModel, UndoManager) {
        let model = SampleBuilderModel.forTesting()
        model.rules.add(.path)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        return (model, undoManager)
    }

    private func setPathText(_ model: SampleBuilderModel, _ text: String) {
        model.rules.rules[0].content = .path(PathRuleDraft(operator: .contains, text: text))
    }

    func test_givenSeveralCommitsWhileAFieldIsFocused_whenEditingEnds_thenOneUndoStepRevertsThemAll() {
        let (model, undoManager) = modelWithPathRule()
        let before = model.rules

        // One group per event, as in the app: each debounced commit, and
        // the blur that ends the edit, is its own run-loop turn.
        func inGroup(_ body: () -> Void) {
            undoManager.beginUndoGrouping()
            body()
            undoManager.endUndoGrouping()
        }
        inGroup { model.beginTextEditing() }
        inGroup { setPathText(model, "tr") }
        inGroup { setPathText(model, "travel") }
        inGroup { model.endTextEditing() }

        // One undo goes all the way back -- not to "tr", which is where
        // it would stop if each commit had been registered.
        undoManager.undo()
        XCTAssertEqual(model.rules, before)

        undoManager.redo()
        guard case .path(let path) = model.rules.rules[0].content else { return XCTFail("not a path rule") }
        XCTAssertEqual(path.text, "travel")
    }

    func test_givenAFocusedFieldWithNoChange_whenEditingEnds_thenNothingIsRegistered() {
        let (model, undoManager) = modelWithPathRule()

        model.beginTextEditing()
        model.endTextEditing()

        XCTAssertFalse(undoManager.canUndo)
    }

    func test_givenAnUndoWhileAFieldIsFocused_whenEditingEnds_thenTheUndoIsNotItselfUndone() {
        let (model, undoManager) = modelWithPathRule()
        undoManager.beginUndoGrouping()
        setPathText(model, "old")
        undoManager.endUndoGrouping()

        model.beginTextEditing()
        undoManager.undo()  // back to "", with a redo registered
        model.endTextEditing()

        XCTAssertTrue(undoManager.canRedo, "ending the edit must not register over the redo")
        guard case .path(let path) = model.rules.rules[0].content else { return XCTFail("not a path rule") }
        XCTAssertEqual(path.text, "")
    }

    func test_givenUnbalancedEndCalls_whenEditingRulesAfterwards_thenUndoStillRegisters() {
        let (model, undoManager) = modelWithPathRule()
        model.endTextEditing()  // never began: ignored

        undoManager.beginUndoGrouping()
        setPathText(model, "x")
        undoManager.endUndoGrouping()

        XCTAssertTrue(undoManager.canUndo)
    }
}
