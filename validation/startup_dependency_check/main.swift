import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
@MainActor
private struct StartupDependencyCheckHarness {
    static func main() async throws {
        let development = StartupDependencyCatalog.requirements(packaged: false)
        let packaged = StartupDependencyCatalog.requirements(packaged: true)

        try require(
            development.first?.id == "developer.homebrew",
            "development catalog does not check Homebrew first"
        )
        try require(
            !packaged.contains(where: { $0.id == "developer.homebrew" }),
            "packaged catalog incorrectly requires a local Homebrew installation"
        )
        try require(
            Set(development.flatMap(\.brewFormulae)).isSuperset(of: [
                "python", "numpy", "libomp", "suite-sparse", "highs", "gcc@13", "cjson",
            ]),
            "development catalog omits a declared Homebrew formula"
        )
        try require(
            packaged.filter { $0.scope == .bundled }.allSatisfy {
                if case .bundledExecutable = $0.probe { return true }
                return false
            },
            "packaged native dependencies are not checked through bundled solver probes"
        )
        try require(
            packaged.contains(where: { requirement in
                guard requirement.id == "bundled.rqna" else { return false }
                if case .bundledExecutable(let name, let subdirectory, let groups) = requirement.probe {
                    return name == "bna_rqna"
                        && subdirectory == "BNArqna"
                        && groups == ["infinite"]
                }
                return false
            }),
            "packaged startup checks do not verify the RQNA executable"
        )

        let requirements = [
            StartupDependencyRequirement(
                id: "one",
                name: "One",
                summary: "available",
                scope: .runtime,
                probe: .brewFormula("one"),
                brewFormulae: ["libomp", "suite-sparse"]
            ),
            StartupDependencyRequirement(
                id: "two",
                name: "Two",
                summary: "missing",
                scope: .developer,
                probe: .brewFormula("two"),
                brewFormulae: ["suite-sparse", "highs"]
            ),
            StartupDependencyRequirement(
                id: "three",
                name: "Three",
                summary: "timeout",
                scope: .optional,
                probe: .brewFormula("three"),
                brewFormulae: ["highs", "cjson"],
                supplementalInstallCommands: ["python3 -m pip install cvxpy"]
            ),
        ]

        let checker = StartupDependencyChecker(
            requirements: requirements,
            minimumVisibleNanoseconds: 0
        ) { requirement in
            switch requirement.id {
            case "one": return .available("ready")
            case "two": return .missing("not installed")
            default: return .timedOut("bounded timeout")
            }
        }

        await checker.runIfNeeded()

        let expectedEvents: [StartupDependencyEvent] = [
            .checking("one"),
            .completed("one", .available("ready")),
            .checking("two"),
            .completed("two", .missing("not installed")),
            .checking("three"),
            .completed("three", .timedOut("bounded timeout")),
            .finished,
        ]
        try require(checker.events == expectedEvents, "checks did not advance sequentially")
        try require(checker.hasRun && !checker.isRunning, "checker did not reach a terminal state")
        try require(checker.currentID == nil, "completed checker retained an active row")
        try require(checker.lastCheckedID == "three", "last-checked package was not retained")
        try require(checker.availableCount == 1, "available result count is wrong")
        try require(checker.attentionCount == 2, "attention result count is wrong")
        try require(
            checker.missingBrewFormulae == ["suite-sparse", "highs", "cjson"],
            "missing formulae were not filtered and de-duplicated in catalog order"
        )
        try require(
            checker.brewInstallCommand == "brew install suite-sparse highs cjson",
            "combined Homebrew command is wrong"
        )
        try require(
            checker.supplementalInstallCommands == ["python3 -m pip install cvxpy"],
            "non-Homebrew Python guidance was dropped"
        )

        await checker.runIfNeeded()
        try require(checker.events == expectedEvents, "runIfNeeded repeated an already completed launch check")

        await checker.rerun()
        try require(checker.events == expectedEvents, "manual recheck did not reset and replay cleanly")

        print("Startup dependency checklist checks passed.")
    }
}
