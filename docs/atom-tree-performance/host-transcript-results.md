Results in /tmp/atom-report/host-transcript

### open-5000 (median of 3 runs, worst in parentheses)

| Metric | native | tree | tree-dynamic | tree-full |
| --- | ---: | ---: | ---: | ---: |
| Open: first screen (ms) | 63.80 (65.39) | 105.45 (124.90) | 987.23 (998.79) | 122.38 (123.42) |
| Open: main-thread CPU (ms) | 55.18 (60.26) | 104.21 (123.23) | 981.15 (995.64) | 119.46 (121.01) |
| Open: build tree / spec (ms) | 1.90 (2.02) | 45.30 (46.39) | 921.41 (923.34) | 45.97 (51.96) |
| Open: tree nodes | 0.00 (0.00) | 38001.00 (38001.00) | 38001.00 (38001.00) | 38001.00 (38001.00) |
| Open: memory added (MB) | 11.86 (12.38) | 58.98 (63.13) | 86.23 (89.52) | 50.05 (50.92) |
| Open: atom view bodies | 3.00 (3.00) | 47.00 (47.00) | 47.00 (47.00) | 47.00 (47.00) |
| Scroll to top: frame work median (ms) | 21.12 (21.37) | 46.73 (49.58) | 48.01 (52.10) | 48.01 (48.38) |
| Scroll to top: frame work p95 (ms) | 44.36 (46.89) | 115.91 (118.84) | 109.01 (117.81) | 113.51 (120.52) |
| Scroll to top: longest frame (ms) | 110.42 (113.60) | 302.74 (303.07) | 299.65 (309.20) | 296.96 (320.20) |
| Scroll to top: hitches | 125.00 (129.00) | 147.00 (147.00) | 145.00 (147.00) | 145.00 (148.00) |
| Scroll back down: frame work p95 (ms) | 49.21 (50.02) | 151.66 (179.39) | 168.11 (222.49) | 158.07 (164.79) |
| Scroll back down: hitches | 136.00 (139.00) | 159.00 (159.00) | 146.00 (158.00) | 146.00 (159.00) |
| Select all in a long message (ms) | 14.96 (15.13) | 7.23 (7.54) | 7.49 (17.34) | 8.56 (12.14) |
| Drag-select step, median (ms) | 0.55 (0.61) | 0.42 (0.42) | 0.42 (0.50) | 0.56 (0.56) |
| Drag-select step, max (ms) | 0.67 (0.77) | 0.61 (1.00) | 0.61 (0.62) | 0.73 (0.77) |
| Expand/collapse a tool call + frame, median (ms) | 0.49 (0.53) | 0.06 (0.06) | 0.38 (1.21) | 42.32 (45.53) |
| Expand/collapse, max (ms) | 10.23 (11.02) | 63.39 (91.40) | 60.34 (1158.30) | 98.30 (116.25) |
| Jump to bottom (ms) | 151.05 (151.09) | 1201.07 (1217.73) | 1234.21 (1234.39) | 1251.05 (1251.05) |
| Memory after scroll (MB) | 200.89 (201.33) | 466.47 (476.83) | 499.52 (505.52) | 483.05 (541.92) |
| Peak memory (MB) | 232.34 (232.56) | 514.49 (514.89) | 540.05 (541.36) | 518.94 (591.44) |

### stream-1000 (median of 3 runs, worst in parentheses)

| Metric | native | tree | tree-dynamic | tree-full |
| --- | ---: | ---: | ---: | ---: |
| Update work median (ms) | 5.16 (5.32) | 1.04 (1.08) | 1.49 (2.69) | 9.54 (9.61) |
| Update work p95 (ms) | 10.21 (35.33) | 3.64 (6.45) | 5.61 (8.39) | 33.67 (53.00) |
| Update work max (ms) | 16.66 (166.88) | 25.46 (46.16) | 47.92 (49.87) | 70.87 (518.21) |
| Main-thread busy per update, median (ms) | 5.22 (5.39) | 1.08 (1.11) | 1.56 (2.79) | 9.56 (9.62) |
| Hitches in 60 s (>16.7 ms) | 0.00 (679.00) | 2.00 (14.00) | 10.00 (16.00) | 234.00 (581.00) |
| Main-thread CPU (%) | 32.10 (39.03) | 7.96 (10.26) | 11.63 (16.26) | 59.58 (59.82) |
| Spec build per update, median (ms) | – | 0.00 (0.01) | 0.00 (0.01) | 1.46 (1.53) |
| Atom view bodies per update | 1.03 (1.03) | 0.02 (0.03) | 0.02 (0.03) | 0.03 (0.04) |
| Prop decodes per update | 0.00 (0.00) | 0.00 (0.00) | 2.00 (2.00) | 0.00 (0.00) |
| Peak memory (MB) | 193.42 (197.14) | 213.53 (221.42) | 215.02 (222.56) | 221.74 (222.81) |

### stream-5000 (median of 3 runs, worst in parentheses)

| Metric | native | tree | tree-dynamic | tree-full |
| --- | ---: | ---: | ---: | ---: |
| Update work median (ms) | 5.60 (5.61) | 1.22 (1.32) | 1.58 (2.90) | 41.17 (41.63) |
| Update work p95 (ms) | 9.97 (10.09) | 3.56 (3.65) | 4.41 (8.67) | 45.86 (269.27) |
| Update work max (ms) | 15.55 (139.53) | 19.40 (20.02) | 20.53 (495.38) | 64.84 (636.26) |
| Main-thread busy per update, median (ms) | 5.67 (5.69) | 1.30 (1.39) | 1.66 (2.99) | 41.21 (41.66) |
| Hitches in 60 s (>16.7 ms) | 0.00 (97.00) | 1.00 (1.00) | 1.00 (32.00) | 1196.00 (1198.00) |
| Main-thread CPU (%) | 33.13 (33.32) | 9.79 (9.86) | 12.99 (20.33) | 83.76 (84.70) |
| Spec build per update, median (ms) | – | 0.01 (0.01) | 0.01 (0.01) | 6.74 (6.78) |
| Atom view bodies per update | 1.02 (1.03) | 0.03 (0.03) | 0.03 (0.03) | 0.07 (0.12) |
| Prop decodes per update | 0.00 (0.00) | 0.00 (0.00) | 2.00 (2.00) | 0.00 (0.00) |
| Peak memory (MB) | 199.81 (219.38) | 481.89 (484.67) | 512.02 (547.83) | 475.91 (479.24) |

Errors:
stream-1000-tree-dynamic-run-3.json: the end of the streamed reply is not on screen
stream-1000-tree-full-run-1.json: the end of the streamed reply is not on screen
stream-1000-tree-full-run-2.json: the end of the streamed reply is not on screen
stream-1000-tree-full-run-3.json: the end of the streamed reply is not on screen
stream-1000-tree-run-2.json: the end of the streamed reply is not on screen
stream-1000-tree-run-3.json: the end of the streamed reply is not on screen
stream-5000-tree-dynamic-run-1.json: the end of the streamed reply is not on screen
stream-5000-tree-dynamic-run-2.json: the end of the streamed reply is not on screen
stream-5000-tree-full-run-1.json: the end of the streamed reply is not on screen
stream-5000-tree-full-run-2.json: the end of the streamed reply is not on screen
stream-5000-tree-full-run-3.json: the end of the streamed reply is not on screen
stream-5000-tree-run-1.json: the end of the streamed reply is not on screen
stream-5000-tree-run-2.json: the end of the streamed reply is not on screen
stream-5000-tree-run-3.json: the end of the streamed reply is not on screen
exit 1
