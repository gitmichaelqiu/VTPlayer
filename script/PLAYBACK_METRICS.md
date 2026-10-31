# Playback metrics

Launch a Debug build with its console redirected, then open a video, select the desired enhancements, and play it:

```sh
/path/to/VTPlayer.app/Contents/MacOS/VTPlayer > /tmp/vtplayer-playback.log 2>&1
```

In another terminal, collect new diagnostics for at least 10 seconds:

```sh
python3 script/playback_metrics.py --log-file /tmp/vtplayer-playback.log --seconds 20 > /tmp/vtplayer-metrics.json
```

The JSON includes each captured diagnostic record and min, median, max, and count for numeric fields. `submitHz` counts frame submissions; `actualHz` and interval statistics require presentation callbacks and can be zero when those callbacks are unavailable. The display-link callback rate is not a direct measurement of the physical display refresh rate. The collector does not measure audible output latency or lip sync.

`--pid PID` can capture unified logs when the process emits them there, but Xcode may redirect its diagnostics elsewhere. A capture with no diagnostic records exits with status 2.
