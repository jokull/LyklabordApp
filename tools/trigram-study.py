#!/usr/bin/env python3
"""Re-rank TypeEngine's dev candidate export with pinned Icegrams evidence.

Input is JSONL from `type-eval export-candidates dev`. Icegrams is an offline
teacher only: this script never reads heldout and does not modify app artifacts.
Set PYTHONPATH to an Icegrams checkout/install before invoking it. Recorded
results use https://github.com/mideind/Icegrams at commit
5538250cfcce9faca83cb6a630aed9e838ff1865.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
import sys

from icegrams import Ngrams


WEIGHTS = (
    0.0, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3,
    0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--signal",
        choices=("count", "lift"),
        default="count",
        help="count=log(1+trigram count); lift=trigram-vs-bigram conditional lift",
    )
    parser.add_argument(
        "--include-preserve",
        action="store_true",
        help="include IS preserve rows and use the typed token as gold",
    )
    return parser.parse_args()


def normalized(token: str) -> str:
    return token.lower()


def evidence(
    ngrams: Ngrams, previous2: str, previous1: str, word: str, signal: str
) -> tuple[int, float]:
    p2, p1, candidate = map(normalized, (previous2, previous1, word))
    trigram = ngrams.freq(p2, p1, candidate)
    if trigram == 0:
        return 0, 0.0
    if signal == "count":
        # Within one context the omitted denominator is shared by every
        # candidate. Missing candidates stay neutral rather than receiving a
        # synthetic negative probability.
        return trigram, math.log1p(trigram)
    context_count = ngrams.freq(p2, p1)
    bigram = ngrams.freq(p1, candidate)
    previous_count = ngrams.freq(p1)
    trigram_logp = math.log1p(trigram) - math.log1p(context_count)
    bigram_logp = math.log1p(bigram) - math.log1p(previous_count)
    return trigram, trigram_logp - bigram_logp


def main() -> int:
    args = parse_args()
    rows = [json.loads(line) for line in sys.stdin if line.strip()]
    ngrams = Ngrams()
    try:
        study = []
        for row in rows:
            candidates = row["candidates"]
            eligible = (
                row["lang"] == "is"
                and (row["expectation"] == "repair" or args.include_preserve)
                and len(row["context"]) >= 2
                and " " not in (
                    row["typo"] if row["expectation"] == "preserve" else row["intended"]
                )
                and any(
                    c["word"]
                    == (row["typo"] if row["expectation"] == "preserve" else row["intended"]).lower()
                    for c in candidates
                )
            )
            if not eligible:
                continue
            p2, p1 = row["context"][-2:]
            enriched = []
            for candidate in candidates:
                count, value = evidence(ngrams, p2, p1, candidate["word"], args.signal)
                enriched.append({**candidate, "trigramCount": count, "trigramEvidence": value})
            study.append((row, enriched))

        print(
            f"signal={args.signal} input_rows={len(rows)} "
            f"reachable_context_rich_is={len(study)}"
        )
        attested_gold = sum(
            any(
                c["word"]
                == (
                    row["typo"] if row["expectation"] == "preserve" else row["intended"]
                ).lower()
                and c["trigramCount"] > 0
                for c in candidates
            )
            for row, candidates in study
        )
        discriminating = sum(
            len({c["trigramEvidence"] for c in candidates}) > 1
            for _, candidates in study
        )
        print(
            f"gold_attested={attested_gold}/{len(study)} "
            f"({100 * attested_gold / max(len(study), 1):.1f}%) "
            f"discriminating={discriminating}/{len(study)} "
            f"({100 * discriminating / max(len(study), 1):.1f}%)"
        )

        results = []
        for weight in WEIGHTS:
            top1 = changed = correct = wrong = 0
            category_delta: dict[str, list[int]] = defaultdict(lambda: [0, 0])
            examples = []
            for row, candidates in study:
                baseline = candidates[0]["word"]
                gold = (
                    row["typo"] if row["expectation"] == "preserve" else row["intended"]
                ).lower()
                ranked = sorted(
                    candidates,
                    key=lambda c: (
                        -(c["score"] + weight * c["trigramEvidence"]),
                        c["word"],
                    ),
                )
                winner = ranked[0]["word"]
                top1 += winner == gold
                if winner == baseline:
                    continue
                changed += 1
                before_correct = baseline == gold
                after_correct = winner == gold
                if after_correct and not before_correct:
                    correct += 1
                    category_delta[row["category"]][0] += 1
                elif before_correct and not after_correct:
                    wrong += 1
                    category_delta[row["category"]][1] += 1
                if len(examples) < 8 and before_correct != after_correct:
                    examples.append(
                        f"{pithy_context(row)}: {row['typo']} | {baseline} -> {winner} "
                        f"(gold {gold})"
                    )
            results.append((weight, top1, changed, correct, wrong, category_delta, examples))

        baseline_top1 = results[0][1]
        print("weight  top1       delta   changed  correct  wrong  ratio")
        for weight, top1, changed, correct, wrong, _, _ in results:
            ratio = (
                "inf"
                if wrong == 0 and correct
                else (f"{correct / wrong:.2f}" if wrong else "-")
            )
            print(
                f"{weight:>6.3f}  {top1:>4}/{len(study):<4} "
                f"{top1 - baseline_top1:>+6}  {changed:>7}  {correct:>7}  {wrong:>5}  {ratio:>5}"
            )

        best = max(results, key=lambda item: (item[1], item[3] - item[4], -item[0]))
        weight, top1, changed, correct, wrong, category_delta, examples = best
        print(
            f"\nbest weight={weight:g}: top1 {baseline_top1}->{top1}, "
            f"changed={changed}, correct={correct}, wrong={wrong}"
        )
        if category_delta:
            print(
                "category wins/losses: "
                + ", ".join(
                    f"{name} +{counts[0]}/-{counts[1]}"
                    for name, counts in sorted(category_delta.items())
                )
            )
        for example in examples:
            print("  " + example)
        return 0
    finally:
        ngrams.close()


def pithy_context(row: dict) -> str:
    return " ".join(row["context"][-2:])


if __name__ == "__main__":
    raise SystemExit(main())
