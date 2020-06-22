## Cycle parking

Output categories:

* New, nearby: locations that are in the TfL CID, not in OSM, but have OSM parking nearby
* New, isolated: locations that are in the TfL CID, not in OSM, and have no OSM parking nearby
* Remapped (for information only): locations that have been matched between the CID and OSM
* OSM unique (for information only): locations that are in OSM but not the CID

To output the "remapped" and "OSM unique" categories, pass `--existing` as an argument to the Ruby script. remapped.geojson shows the matches as lines between the OSM location and the CID location, to demonstrate what matches have been made. In the mid-March 2020 run, 5277 TfL locations have been matched to existing OSM locations.

With around 24,000 locations, an accurate and efficient algorithm can save a lot of manual editing work. The matching logic is consequently significantly more complex than a simple proximity match. It is cluster-based (using recent PostGIS cluster functions) to improve matching. It tries not to match points across roads, since the side of the road will have been accurately surveyed by both OSM and TfL surveyors. 
