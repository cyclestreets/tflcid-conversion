## Restricted routes

"Restricted routes" are non-vehicle ways which are restricted for cycling - usually pedestrian paths.

This is a difficult dataset to match up and I’d envisage that edits will need to be done entirely manually rather than with any automated process.

Output categories:

* New - restricted routes that aren’t in OSM at all (within 5m tolerance). This has caught a good number of short pedestrian paths and other cut-throughs that could usefully be added to OSM. It also includes some pavement paths where the road is already mapped in OSM (but wider than 5m!) - there’s no great urgency to add these. There are also some cases where the route is in OSM but offset by more than 5m - a good reason for manual review. 500.
* Cycleways - i.e. restricted routes which are currently tagged as cycleable in OSM (again within 5m tolerance, and with a minimum of 20m). In many cases this would suggest that the cycleway in OSM should be downgraded to (say) highway=footway, bicycle=dismount. But there are a lot of judgement calls in here and also several cases where the TfL data is intended to refer to a pavement, but it’s picked up (say) the park road which the pavement is alongside. 170.
