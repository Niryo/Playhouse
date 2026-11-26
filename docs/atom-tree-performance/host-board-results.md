Results in /tmp/atom-report/host-board

### board-500 (median of 3 runs, worst in parentheses)

| Metric | native | tree | tree-dynamic |
| --- | ---: | ---: | ---: |
| Open: first frame (ms) | 2572.11 (2682.69) | 2694.05 (2733.02) | 2883.78 (2957.77) |
| Open: main-thread CPU (ms) | 2570.73 (2672.09) | 2688.13 (2728.19) | 2882.13 (2947.40) |
| Open: memory added (MB) | 567.48 (569.59) | 594.06 (594.39) | 594.02 (594.03) |
| Open: atom view bodies | 5311.00 (5311.00) | 5311.00 (5311.00) | 5311.00 (5311.00) |
| Open: tree node bodies | 0.00 (0.00) | 5772.00 (5772.00) | 5272.00 (5272.00) |
| Open: prop decodes | 0.00 (0.00) | 0.00 (0.00) | 10544.00 (10544.00) |
| Scroll: frame work median (ms) | 32.92 (33.89) | 40.19 (46.49) | 38.44 (44.56) |
| Scroll: frame work p95 (ms) | 36.32 (37.63) | 52.00 (60.61) | 52.55 (55.93) |
| Scroll: longest frame (ms) | 132.79 (148.50) | 65.74 (75.41) | 66.43 (66.53) |
| Scroll: hitches (>16.7 ms) | 330.00 (330.00) | 330.00 (330.00) | 330.00 (330.00) |
| Scroll: main-thread CPU (ms) | 25478.80 (33277.41) | 19771.95 (20065.98) | 21087.11 (21860.84) |
| Memory after scroll (MB) | 642.97 (661.47) | 685.17 (696.69) | 682.10 (699.47) |
| Peak memory (MB) | 687.03 (687.44) | 712.41 (714.28) | 708.49 (713.10) |

### board-2000-noclocks (median of 3 runs, worst in parentheses)

| Metric | native | tree | tree-dynamic |
| --- | ---: | ---: | ---: |
| Open: first frame (ms) | 13088.07 (13957.98) | 14873.28 (16107.30) | 15180.90 (15487.62) |
| Open: main-thread CPU (ms) | 13082.63 (13887.39) | 14856.14 (15973.94) | 15162.72 (15460.10) |
| Open: memory added (MB) | 2225.30 (2228.56) | 2352.61 (2355.36) | 2360.14 (2362.36) |
| Open: atom view bodies | 21128.00 (21128.00) | 21128.00 (21128.00) | 21128.00 (21128.00) |
| Open: tree node bodies | 0.00 (0.00) | 23089.00 (23089.00) | 21089.00 (21089.00) |
| Open: prop decodes | 0.00 (0.00) | 0.00 (0.00) | 42178.00 (42178.00) |
| Scroll: frame work median (ms) | 168.95 (514.73) | 389.03 (549.53) | 362.99 (516.19) |
| Scroll: frame work p95 (ms) | 296.73 (1240.35) | 807.18 (854.66) | 525.03 (774.80) |
| Scroll: longest frame (ms) | 332.57 (3550.02) | 3037.28 (4492.33) | 1303.87 (2255.18) |
| Scroll: hitches (>16.7 ms) | 600.00 (600.00) | 600.00 (600.00) | 600.00 (600.00) |
| Scroll: main-thread CPU (ms) | 146426.23 (326526.17) | 221179.13 (305619.40) | 201667.15 (234549.42) |
| Memory after scroll (MB) | 2299.82 (2308.52) | 2426.24 (2437.08) | 2435.98 (2438.16) |
| Peak memory (MB) | 2333.33 (2337.49) | 2465.14 (2474.69) | 2467.12 (2467.71) |

### interaction-noclocks (median of 3 runs, worst in parentheses)

| Metric | native | tree | tree-dynamic |
| --- | ---: | ---: | ---: |
| Idle: main-thread CPU (%) | 0.03 (0.03) | 0.09 (0.21) | 0.10 (0.36) |
| Idle: atom view bodies per second | 0.00 (0.00) | 0.00 (0.00) | 0.00 (0.00) |
| Press to open action, median (ms) | 47.71 (48.49) | 50.01 (51.68) | 49.42 (50.83) |
| Presses registered (of 36) | 12.00 (12.00) | 12.00 (12.00) | 12.00 (12.00) |
| Hover move + frame, median (ms) | 0.39 (0.40) | 0.40 (10.64) | 0.40 (10.77) |
| Hover move + frame, max (ms) | 1.11 (1.12) | 5.32 (75.23) | 7.79 (65.93) |
| Press to open action + frame, median (ms) | 48.30 (49.22) | 50.70 (52.38) | 50.17 (51.71) |
| Press, max (ms) | 248.03 (261.21) | 83.12 (274.04) | 81.31 (300.30) |
| Right-click to menu shown, median (ms) | 20.07 (20.10) | 18.56 (19.47) | 18.44 (19.39) |
| Right-click to menu shown, max (ms) | 218.40 (322.91) | 158.95 (174.98) | 51.06 (223.11) |
| Drag preview render, median (ms) | 6.22 (7.23) | 6.48 (9.38) | 7.14 (10.96) |
| Drag preview render, max (ms) | 10.38 (11.58) | 11.04 (18.28) | 11.37 (14.85) |

### live-100 (median of 3 runs, worst in parentheses)

| Metric | native | tree | tree-dynamic |
| --- | ---: | ---: | ---: |
| Update work median (ms) | 120.17 (120.45) | 124.72 (126.50) | 145.06 (147.78) |
| Update work p95 (ms) | 134.69 (135.24) | 138.21 (143.84) | 157.09 (157.71) |
| Update work max (ms) | 142.77 (144.70) | 148.47 (150.14) | 169.84 (169.89) |
| Main-thread busy per update, median (ms) | 355.88 (365.73) | 363.32 (365.41) | 378.97 (384.18) |
| Frame work p95 (ms) | 123.18 (125.79) | 128.46 (129.84) | 147.82 (151.96) |
| Hitches in 30 s (>16.7 ms) | 84.00 (128.00) | 83.00 (83.00) | 80.00 (85.00) |
| Main-thread CPU (%) | 99.24 (99.34) | 99.43 (99.49) | 99.41 (99.48) |
| Atom view bodies per update | 657.44 (657.59) | 321.30 (321.51) | 321.57 (321.59) |
| Prop decodes per update | 0.00 (0.00) | 0.00 (0.00) | 641.64 (641.66) |
| Spec build total (ms) | – | 25.69 (26.27) | 26.70 (26.74) |
| Reconcile total (ms) | – | 198.09 (203.90) | 2294.54 (2325.80) |
| Memory after (MB) | 279.41 (279.59) | 285.25 (301.31) | 285.39 (290.92) |

Runs that did not finish (no numbers; they are left out of the medians above):

- board-2000-noclocks, tree-dynamic, run 2: still running after 600 s
exit 0
