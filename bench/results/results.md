# Conductor Benchmark Results

MOCK DATA: these results were synthesized by run.py (BENCH_MOCK=1), not produced by real claude invocations. Numbers below prove the pipeline renders end to end; they are not evidence of real-world token or cost differences.

## Per-task results

| task | arm | runs | success rate | avg wall time (s) | main tokens (in/out) | sonnet tokens (in/out) | haiku tokens (in/out) | modeled cost | reported cost |
|---|---|---|---|---|---|---|---|---|---|
| t1_fizzbuzz_fix | baseline | 2 | 2/2 | 24.0 | 0/0 | 7,359/2,108 | 0/0 | $0.0537 | $0.0537 |
| t1_fizzbuzz_fix | conductor | 2 | 2/2 | 21.8 | 0/0 | 4,365/999 | 1,093/252 | $0.0304 | $0.0304 |
| t2_csv_dedupe | baseline | 2 | 2/2 | 31.4 | 0/0 | 4,972/1,678 | 0/0 | $0.0401 | $0.0401 |
| t2_csv_dedupe | conductor | 2 | 2/2 | 33.0 | 0/0 | 3,154/1,164 | 791/293 | $0.0292 | $0.0292 |
| t3_regex_extract | baseline | 2 | 2/2 | 26.2 | 0/0 | 4,173/2,020 | 0/0 | $0.0428 | $0.0428 |
| t3_regex_extract | conductor | 2 | 2/2 | 30.3 | 0/0 | 3,641/1,177 | 912/296 | $0.0310 | $0.0310 |
| t4_shell_wordcount | baseline | 2 | 2/2 | 16.7 | 0/0 | 5,908/2,354 | 0/0 | $0.0530 | $0.0530 |
| t4_shell_wordcount | conductor | 2 | 2/2 | 32.3 | 0/0 | 2,725/1,536 | 683/385 | $0.0338 | $0.0338 |
| t5_summarize_changelog | baseline | 2 | 2/2 | 25.0 | 0/0 | 5,272/1,886 | 0/0 | $0.0441 | $0.0441 |
| t5_summarize_changelog | conductor | 2 | 2/2 | 35.1 | 0/0 | 3,448/1,767 | 865/442 | $0.0399 | $0.0399 |
| t6_research_brief | baseline | 2 | 2/2 | 31.5 | 0/0 | 5,129/2,162 | 0/0 | $0.0478 | $0.0478 |
| t6_research_brief | conductor | 2 | 2/2 | 25.5 | 0/0 | 4,361/1,415 | 1,092/355 | $0.0372 | $0.0372 |
| t7_multifile_inventory | baseline | 2 | 2/2 | 32.8 | 0/0 | 4,840/2,862 | 0/0 | $0.0575 | $0.0575 |
| t7_multifile_inventory | conductor | 2 | 2/2 | 16.8 | 0/0 | 3,044/1,350 | 762/339 | $0.0318 | $0.0318 |
| t8_multifile_rename | baseline | 2 | 2/2 | 16.1 | 0/0 | 5,799/2,464 | 0/0 | $0.0544 | $0.0544 |
| t8_multifile_rename | conductor | 2 | 2/2 | 13.9 | 0/0 | 4,525/1,440 | 1,134/362 | $0.0381 | $0.0381 |

## Aggregate by arm

| arm | total runs | success rate | total wall time (s) | main tokens (in/out) | sonnet tokens (in/out) | haiku tokens (in/out) | total modeled cost | total reported cost |
|---|---|---|---|---|---|---|---|---|
| baseline | 16 | 16/16 | 407.5 | 0/0 | 43,452/17,534 | 0/0 | $0.3934 | $0.3934 |
| conductor | 16 | 16/16 | 417.5 | 0/0 | 29,263/10,848 | 7,332/2,724 | $0.2715 | $0.2715 |

## Pricing used for modeled cost (USD per MTok, in/out)

| tier | input | output |
|---|---|---|
| fable | $10.00 | $50.00 |
| opus | $5.00 | $25.00 |
| sonnet | $3.00 | $15.00 |
| haiku | $1.00 | $5.00 |

Modeled cost applies the table above to captured token counts. Reported cost is the claude CLI's own total_cost_usd / modelUsage[*].costUSD, unmodified. They can differ (e.g. cache discounts, pricing changes since this table was last updated); both are shown so neither is mistaken for the other.

