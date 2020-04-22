## On-carriageway cycle lanes

This is the most complex dataset of all. The TfL data is very granular, often broken up into very small sections of cycle lane - stopping and starting at pedestrian crossings, junctions and so on.

The roads are, of course, all mapped in OSM, but each way has a different start/end point. An automated edit which split and recreated ways would be exceptionally error-prone, so this conversion focuses on identifying those changes which _can_ be made easily, and then preparing the other data for semi-manual integration.

The script does the following:

1. match each TfL object to (one or more) OSM ways;
2. filter out those where the TfL lane is already mapped in OSM;
3. remap the attributes to OSM tags;
4. write out in one of several categories, based on the mapping tasks that will need doing.

Other complications include the TfL geometries being unidirectional (i.e. one per side of the road) whereas OSM is usually bidirectional (one for the whole road); multiple tagging schemes in OSM; lanes in the TfL data mapped as tracks in OSM; and so on.

Output categories (with mid-March 2020 counts) are:

* Full (824): This is where a full OSM way can be retagged with cycle track data for its entire length (i.e. no splitting required). _Mapping required: Generally just transfer the new tags onto the existing way._
* Partial (7626): This is where the OSM way will need to be split (often several times) because the TfL lane data varies during the length of the way. _Mapping required: Split the way as appropriate and transfer the new tags. Mappers may decide to be less granular than in the TfL data (e.g. continue lanes across junctions)._
* Separate (271): This is where a stepped or partially/lightly-segregated track is marked in the TfL data, and a separately mapped cycleway exists in OSM (i.e. a discrete highway=cycleway rather than an attribute on the road). CS3 on Cable Street is a good example of this. _Mapping required: In most cases, this will just require review rather than editing._
* Contra (696): Contraflow cycle lanes that are not already mapped in OSM. _Mapping required: This will often require the OSM way to be tagged as oneway=yes (if not already), and then a new tag such as oneway:bicycle=no, or cycleway=opposite_lane._
* Unmatched (824): TfL geometries that couldn’t be matched to OSM ways. Generally this is because they were too far apart (>10m). _Mapping required: Manually identify appropriate geometry and transfer tags._

All the geometries have been snapped to the OSM centrelines, rather than one geometry per side of the road as in the TfL data.

There is a lot of room for manoeuvre in this. For example, Queen’s Circus roundabout on CS8 (https://osm.org/go/euutNJzsN--?layers=C) has a continuous cycle route around the roundabout. Some of it is segregated in reality, some isn’t. In OSM it has been mapped as a single discrete cycleway. In the TfL data it is a series of geometries with differing attributes and some duplication. It will require some judgement to choose what to do - my instinct in this case would be to leave it as is in OSM.

The tileset of TfL cycle lane/track data at https://osm.cycle.travel/ is intended to help integrate this dataset.