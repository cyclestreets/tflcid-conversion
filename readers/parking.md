## Cycle parking

Output categories:

* New: locations that are in the TfL CID but not in OSM
* Remapped (for information only): locations that have been matched between the CID and OSM
* OSM unique (for information only): locations that are in OSM but not the CID

remapped.geojson shows the matches as lines between the OSM location and the CID location, to demonstrate what matches have been made. In the mid-March 2020 run, 5277 TfL locations have been matched to existing OSM locations.

With around 24,000 locations, an accurate and efficient algorithm can save a lot of manual editing work. The matching logic is consequently significantly more complex than a simple proximity match. It is cluster-based (using recent PostGIS cluster functions) to improve matching. It tries not to match points across roads, since the side of the road will have been accurately surveyed by both OSM and TfL surveyors. 
