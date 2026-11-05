# Logs of the validation run

One complete run of `vertica-k8s-lab.sh` 1.1.0 on 2026-11-05, on a single Ubuntu
26.04.1 workstation, starting from a clean machine:

| Order | Command | Time | Result |
|---|---|---|---|
| 1 | `--cleanup --yes` | 00:12:58 | removed the previous lab |
| 2 | `--verify-clean` | 00:13:19 | nothing left |
| 3 | `--install` | 00:13:20 – 00:18:37 | 13/13 steps, server 26.2.0-4, operator 26.2.2 |
| 4 | `--test` | 00:32:19 – 00:42:26 | **15 PASS, 0 FAIL, 0 WARN** |
| 5 | `--demo` | 00:42:55 – 00:43:02 | 9/9 steps, including the JWT login |

## Folders

| Folder | Content |
|---|---|
| [console/](console/) | What the terminal showed, recorded with `script`, one file per command, numbered in the order above |
| [run/](run/) | The script's own run logs: every command it ran and its full output, with timestamps |
| [report/](report/) | The test report: [summary.txt](report/summary.txt), [results.csv](report/results.csv) (one row per test), [perf.csv](report/perf.csv) (every metric), `results/T*.res` (every check), `load-*.log` (the client load samples during T10–T12) and the host Vertica snapshot before and after the tests |

`load-*.log` lines are `epoch-seconds OK|FAIL latency-ms`: one query per second through
the primary Service.

## Sanitizing

The files are the original output with these changes only:

- Terminal colour codes and progress-bar redraws are removed.
- IP addresses (except `0.0.0.0` and `127.0.0.1`) are shown as `<ip>`, UUIDs as `<uuid>`,
  image digests as `sha256:<digest>`, and some internal IDs as `<id>`.
- The machine's host name is shown as `workstation`, and the administrator account as
  `<admin>`.

Passwords, client secrets and tokens never reached the logs: the script masks every
secret value it handles (`********`) and never prints tokens.
