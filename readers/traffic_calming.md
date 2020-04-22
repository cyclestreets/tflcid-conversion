## Traffic calming

Because the matching is subtly different for each type of traffic calming, there are several scripts for the one TfL dataset.

For example, humps and bumps are reasonably unlikely (but not impossible) to be on a cycleway; they quite often coincide with an already mapped crossing. Raised tables are always at junctions, where a junction might comprise more than one OSM node. And so on.


### Speed bumps, humps, cushions

This is a straightforward dataset, the vast majority of which could go into OSM almost automatically. This means that mappers can be able to spend their time on the 10% that requires more effort.

Output categories are:

* On-road or otherwise very easily matched: 45695
* On cycleways: 130
* Do not readily match to an existing OSM feature, either because there’s no suitable ways nearby, or because an existing OSM traffic calming feature has clashing tagging (these will also need to be manually checked): 790

New features have been snapped to existing OSM nodes where possible, but many require new nodes to be created within the way. 

### Raised tables

Output categories:

* Raised tables that can clearly be identified with road junction(s): 2909
* Not within 10m of a road junction and need manual checking: 135

Of the 135, inspection shows these to be a motley collection of elongated speed-humps; raised pedestrian crossings; raised turning circles; and large, almost shared-space streetscape that would probably be better mapped as areas in OSM (perhaps with surface=paving_stones, or similar, on the highway ways).

### Chicanes/chokers

Output categories:

* New chicanes/chokers (snapped to nearest OSM node within 5m if possible: I’d used 10m elsewhere, but in this case, often the chicanes are immediately next to a junction, so the greater precision reduces the likelihood of them being snapped to the junction node): 557
* Need checking as there’s a different type of traffic calming mapped in OSM: 8
* "Islands": 37

The islands/bypasses are a reasonably common OSM mapping pattern that I thought was worth isolating. Here’s an example: https://www.openstreetmap.org/?mlat=51.545895699&mlon=-0.1339648409#map=19/51.545895699/-0.1339648409&layers=C

There’s either a cycleway either side of the choker, or two one-way highways with an island in the middle. These will require more careful mapping to make sure that the choker is positioned on the right way(s).

### Side-road entries

Output categories:

• Existing crossings, where the location is already tagged with traffic_calming=table or highway=crossing: 355
• Existing junctions, where the location is already a junction between the road and a cycleway/footway: 787
• New, where there is no tagging at all (snapped to an existing OSM node if possible): 6444
• To check, where no minor road was identified in the area - these are usually where a ‘mews’ or other small side-road hasn’t been mapped in OSM, but sometimes where the entry treatment is over a major road: 107

These are some of the more complex mapping situations - often in OSM there’ll already be moderately complex junction mapping, so the success rate here is less than some of the other subsets.

### Barriers

Output categories:

* New, to add to OSM (reusing existing nodes where possible): 231
* To check because there’s already a cycleway/road interface here: 182 
* To check for other reasons: 43

To explain the latter two categories:

Often a modal filter is mapped in OSM as a short section of cycleway between two (motor) roads. Sometimes it will be a variation on this, such as two cycleways (one either side of the barrier/blockage). This means that the 182 are essentially already mapped as barriers, just without a barrier tag. But the identification isn’t foolproof - there might be a cycleway in close proximity for another reason. For that reason, I’ve broken them out into a separate file for checking.

The "other reasons” for the last 43 include: there are two cycleways (or other paths) in close proximity, so it’s unclear which one the barrier is on; the barrier appears to be on a highway=tertiary, which would be unlikely to be closed to through traffic; or that there were no identifiable ways nearby.

From sanity-checking individual locations, my sense is that the variation in “build” between these is greater than the other datasets - it covers bollards, gates, stone/brick structures, and (on tertiary roads) a few cases which are essentially width restrictions rather than modal filters. For this reason, I suggest using barrier=yes rather than barrier=bollard. It could be a useful fixme for the OSM community to go through these at a later date, using the TfL photos, and refine them into barrier=bollard/gate.
