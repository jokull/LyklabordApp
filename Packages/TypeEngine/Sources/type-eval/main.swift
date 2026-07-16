import EvalKit
import Foundation
import TypeEngine

// type-eval — the eval-studio CLI for the TypeEngine autocorrect stack.
//
//   type-eval                         micro-eval on the bundled TSV fixture
//   type-eval <file.tsv>              micro-eval on a fixture path
//   type-eval corpus <dev|heldout>    replay a corpus split (data/eval/*.jsonl)
//                                     through the REAL artifacts (dev = tuning,
//                                     heldout = REPORT-ONLY, never tune against)
//   type-eval scorecard [--heldout]   micro-eval + corpus dev + scenario suites
//                                     + bench → one JSON, appended to
//                                     scores/history.jsonl; non-zero exit on a
//                                     failed hard gate. --heldout adds a
//                                     REPORT-ONLY heldout section;
//                                     --note <text> annotates the history line.
//   type-eval ab --config <over.json> baseline vs EngineConfig-override diff on
//                                     corpus dev + micro-eval
//
// The micro-eval uses DictLexicon doubles (curated fixture vocabulary); the
// corpus / scorecard / A/B corpus runs use the real data/ artifacts. See
// scores/README.md for the dev/heldout discipline and the hard gates.

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "corpus":
    runCorpusCommand(Array(arguments.dropFirst()))

case "scorecard":
    runScorecardCommand(Array(arguments.dropFirst()))

case "ab":
    runABCommand(Array(arguments.dropFirst()))

default:
    // Legacy micro-eval: no subcommand, optional fixture-path override and
    // an optional --config <overrides.json> (same EngineConfig override set
    // as `ab` — dev-iteration tooling for pinpointing micro-eval diffs).
    var rest = arguments
    var config = EngineConfig()
    if let ci = rest.firstIndex(of: "--config"), ci + 1 < rest.count {
        do {
            (config, _) = try ConfigOverrides.load(
                from: URL(fileURLWithPath: rest[ci + 1]))
        } catch {
            FileHandle.standardError.write(Data("config error: \(error)\n".utf8))
            exit(2)
        }
        rest.removeSubrange(ci...(ci + 1))
    }
    let path = rest.first
    let cases = loadCases(path: path)
    let result = runMicroEval(cases: cases, config: config)
    printMicroEval(result)
    exit(result.validWordViolations.isEmpty ? 0 : 1)
}
