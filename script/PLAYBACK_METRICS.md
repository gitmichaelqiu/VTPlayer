# Playback metrics

Launch a Debug build with its output redirected. Open a video, select enhancements, and begin playback:

```sh
/path/to/VTPlayer.app/Contents/MacOS/VTPlayer > /tmp/vtplayer-playback.log 2>&1 &
VTPLAYER_PID=$!
python3 script/playback_metrics.py --pid "$VTPLAYER_PID" --log-file /tmp/vtplayer-playback.log \
  --seconds 30 --label '4K 30 fps, HDR' > /tmp/vtplayer-baseline.json
```

Capture the same scene and settings after a change, adding `--compare /tmp/vtplayer-baseline.json`. JSON contains raw diagnostic records, one-second process samples, min/median/p95/max, differences from the reference, and validity checks. Repeat runs and compare equivalent scenes, window sizes, cache state, power, and display configuration. The script does not change the playback settings or seek automatically.

The playback clock offset compares the enhanced audio transport time to the most recently submitted video frame. It is not a measurement of speaker output, the visible drawable, or lip sync. A missing audio clock is excluded, rather than treated as zero. Actual presentation rate and interval statistics can be zero when presentation callbacks are unavailable. Screen display-link callbacks are not a direct physical refresh measurement. CPU is percent of one core, RSS omits some GPU allocation, and reported cache size is in-memory frame cache rather than disk usage. The capture cannot prove visual correctness or audio sync by itself.

`--pid` without `--log-file` captures unified logs where available. Xcode may redirect NSLog, so use a redirected log file when no records appear. A capture without diagnostics exits with status 2; inspect `checks` for missing measurements even on successful captures.
