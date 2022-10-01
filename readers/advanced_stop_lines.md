## Advanced stop lines

This script attempts to match advanced stop lines to nodes on OSM ways.

ASLs are mapped in the TfL dataset as short linestrings, but customarily in OSM as nodes. The TfL data also contains information on whether there is a feeder to the ASL. This is translated to an additional tag on the node. In theory it would be possible to map this as a short section of cycleway=lane, but splitting existing geometries to do this would be exceptionally complex (particularly in areas of existing micro-mapping), and risk damage to turn relations and other features often found around junctions.

The script looks for an existing node on a road (not cycleway) near the ASL, or creates a new one if none exists. Junction nodes are purposefully excluded, as otherwise the ASL would risk being placed on the junction itself.

Output categories (with October 2022 counts) are:

* New (1668): This is where a new ASL is added to OSM, either by creating a node or adding tags to an existing one.
* New, tagged (1219): This is where an ASL is added to an existing tagged node. Often this will be a highway=traffic_signals node.
* Add feeder (442): The ASL is already mapped in OSM, and the change is solely to add feeder information.
* To check (19): No nearby candidate way could be identified.

ASLs that are already mapped in OSM and require no further changes are skipped (427).
