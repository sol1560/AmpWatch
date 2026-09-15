# Progress

| Milestone | Status | Notes |
| --- | --- | --- |
| M0 skeleton + CI | done | run 34935551068 green, 6 screenshots |
| M1 real reads | done | run 34938088166 green; setup/settings/threads-error/detail inspected |
| M2 hub plugin + writes | done | run 34938964112 green; toolbar glyph fix, Stop under header, picker as navigationLink pending CI |
| M3 pushes | in progress | apns.ts + bridge announce/register verified in this orb; watch registration + PUSH.md written, CI pending |
| M4 approvals | pending | |
| M5 offline | pending | |
| M6 polish | pending | |

## Log

- 2026-09-15 Plan written; starting M1 F1.1.
- 2026-09-15 M1 done (run 34938088166). Ownership experiment with thread B done.
- 2026-09-15 M2 done (run 34938964112). Milestone order swapped: M3 pushes, M4 approvals.
- 2026-09-15 M3: register+announce round trip through the real webhook in this orb;
  fake-key probe against api.sandbox.push.apple.com → 403 InvalidProviderToken.
