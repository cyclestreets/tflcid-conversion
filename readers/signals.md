## Signals

This script parses bicycle early release signals (only) from the TfL signals dataset.

Where the signals exist in OSM already (within 20m of the TfL lat/lon), the tag `traffic_signals:bicycle_early_release=yes` is added, and the data written to the "existing signals" output.

Where no signals were found within 20m, the data is written to a "new signals" output as a point only. In reality, most traffic signals are already mapped in OSM so this is more likely to be the result of a matching failure. Consequently there is no attempt to create a node in the way, as the signal node almost certainly exists but requires manual attention.

This is a small dataset with c. 60 existing signals and c. 20 not matched.
