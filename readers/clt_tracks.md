## Off-carriageway cycle tracks

The majority of cycle tracks (aka cycleways, off-carriageway) are already in OSM. Once those are taken out of consideration, the remaining TfL data falls into two categories: tracks that aren't in OSM at all, and tracks that are in OSM but are tagged as foot access only.

There are significant data issues with TfL tracks in parks, and consequently those have been discarded. One or two parkland paths do merit inclusion (such as TfL ID RWG235734, part of the Thames Path in Richmond). These are best reviewed manually with the aid of the background tileset.

### Tracks which aren't in OSM

Comparing against OSM for mid-March 2020, there are 1297 objects of 10m or longer (vs 5472 already in OSM). These will, of course, all need to be manually edited for connectivity purposes - i.e. creating junctions to nearby highways.

Some are long new roadside cycleways that were missing from OSM, whereas others are short cut-throughs. There are, inevitably, also a few where the cycleway is currently in OSM, but sufficiently divergent from the CID geometry that the matching hasn’t picked them up.

### Tracks currently mapped as footways

The mid-March run found 160 entire OSM ways which can be upgraded to bicycle=yes, and 256 OSM ways where a section of the way can be upgraded.

This is quite prone to false positives because there’s often a cycleway in close proximity to a footway. I’ve done a lot of processing to cut this down, but inevitably it’s not caught all of them.

