# Delay

Paradise Audio stereo tempo-sync delay AUv3. Independent L/R times, feedback
loop with one-pole low-pass filter in the feedback path, ping-pong mode,
parallel mix.

| Param     | Range           | Default |
|-----------|-----------------|---------|
| Time L    | 1 .. 2000 ms    | 250 ms  |
| Time R    | 1 .. 2000 ms    | 375 ms  |
| Feedback  | 0 .. 0.95       | 0.42    |
| Filter    | 200 .. 18 kHz   | 3.2 kHz |
| Mix       | 0 .. 1          | 0.28    |
| Ping-Pong | on / off        | on      |

Build: `./Installer/build_installer.sh`. Logic: **Paradise Audio ▸ Delay**.
