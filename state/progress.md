# Progress

| Milestone | Status | Notes |
| --- | --- | --- |
| M0 skeleton + CI | done | run 34935551068 green, 6 screenshots |
| M1 real reads | done | run 34938088166 green; setup/settings/threads-error/detail inspected |
| M2 hub plugin + writes | done | run 34938964112 green; toolbar glyph fix, Stop under header, picker as navigationLink pending CI |
| M3 pushes | done | run 34940416257 green; detail (Stop under header) and new-thread (Mode picker row) inspected |
| M4 approvals | done | run 34942528647 green; approval / approval-destructive / approval-deferred inspected; bridge round trip (approve, reject, timeout) verified in this orb |
| M5 offline | in progress | AmpKit 85 green; run 34944265965 pending |
| M6 polish | pending | |

## Log

- 2026-09-15 Plan written; starting M1 F1.1.
- 2026-09-15 M1 done (run 34938088166). Ownership experiment with thread B done.
- 2026-09-15 M2 done (run 34938964112). Milestone order swapped: M3 pushes, M4 approvals.
- 2026-09-15 M3: register+announce round trip through the real webhook in this orb;
  fake-key probe against api.sandbox.push.apple.com → 403 InvalidProviderToken.
- 2026-09-15 M3 done (run 34940416257). M4 bridge round trip in this orb: `arm risky` →
  forwarded to `approve-<threadID>` webhook; `echo … curl …` held; watcher script POSTed
  `decide approve` → ran; `decide reject` → tool rejected; no decision → rejected after 4 min.
- 2026-09-15 M4 done (run 34942528647). Amp's own tool.call ceiling still being probed by thread B.
- 2026-09-15 Thread B: tool.call handler held 2/5/10/20 min, all fine; no ceiling. Timeout raised to 10 min both sides. M5 pushed (c241b49).
