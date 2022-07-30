# tflcid-conversion

## Overview

These scripts compare Transport for London's Cycle Infrastructure Database with existing OpenStreetMap data, and output the differences in variously categorised files.

The [TfL_Cycling_Infrastructure_Database OSM Wiki page](https://wiki.openstreetmap.org/wiki/TfL_Cycling_Infrastructure_Database) has full details about the CID and the conversion project.

The readers work by comparing against existing OSM data, as loaded into a PostGIS database. There is a separate Ruby script for each type of data. In turn, most scripts write out several files, organised by the type of editing work that needs doing.

Currently all output is in GeoJSON format, for easy visualisation in packages like QGIS. It's envisaged that this may change depending on the choice of conflation/editing tool.

Individual documentation files within readers/ explain in more depth the approach taken, and how the output is broken down. Where these files list an illustrative number of matches, that's when compared against OSM data from mid-March 2020.

## Populating a PostGIS database

Download OSM data from Geofabrik at http://download.geofabrik.de/europe/great-britain/england/greater-london-latest.osm.pbf, then import it into a PostGIS database:

    osm2pgsql --proj 3857 -s --hstore-all -d osm_london greater-london-latest.osm.pbf

The data must be imported in slim mode (so we can inspect topology) and with full hstore (so we can inspect all tags).

Most readers read the TfL data directly from file, but some require it to be in the PostGIS database so that we can apply PostGIS's smart spatial functions. Run these two importers:

	ruby preparation/cycle_parking_to_postgis.rb
	ruby preparation/clt_to_postgis.rb

## Data readers

All the Ruby scripts are in readers/ and can be run individually. They will save their output (often several files) to output/ . GeoJSON properties are generally tfl_id for the TfL feature ID, osm_id for the OSM object ID, plus the (modified) OSM tags for the object.

You will need the 'pg', 'colorize', 'faster_haversine' and 'pg_array_parser' gems.

Comments in the scripts give more details about the approach taken by each reader.

## Cycle lanes/tracks tileset

For additional help when mapping, the original (unconflated) TfL cycle lanes & tracks data is available in a map that can be used as a background tileset in your favourite OSM editor. See https://osm.cycle.travel/ for key and links.

## Copyright

All scripts are by Richard Fairhurst (@systemed github, @richardf Twitter) and may be redistributed under the terms of the MIT licence.
