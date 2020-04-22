## Crossings

Output categories:

* Not previously in OSM: all snapped to existing OSM nodes at an existing cycleway/road interface. 419.
* Tag changes: usually either adding crossing=traffic_signals to a bare highway=crossing, or segregated=yes to a more fully mapped one. 296.
* To check: where there was a tag clash (generally where OSM has the crossing as signalised and the CID doesn’t, or vice versa); or where there was no identifiable cycleway/road interface in OSM for a crossing. The low number of these should be easy to check. The “no cycleway” cases probably suggest that there’s a missing cycleway in OSM! 81.
* Railways: so few of these it wasn't worth conflating them. 20.

(1396 crossings were already fully mapped in OSM)

Note that the TfL geometries are linestrings rather than points, potentially crossing more than one road. This means that one CID record could potentially result in two or more OSM crossing nodes.
