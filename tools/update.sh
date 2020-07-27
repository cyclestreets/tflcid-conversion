# Pull down latest data
cd /path/to/tfl/tflcid-conversion
git pull

# Get data
cd /path/to/tfl
rm greater-london-latest.osm.pbf
wget http://download.geofabrik.de/europe/great-britain/england/greater-london-latest.osm.pbf
osm2pgsql --proj 3857 -s --hstore-all -d osm_london greater-london-latest.osm.pbf
./read_versions/read_versions greater-london-latest.osm.pbf

# Create .geojson files
cd tflcid-conversion/
ruby preparation/cycle_parking_to_postgis.rb
ruby preparation/clt_to_postgis.rb
ruby readers/clt_footways.rb
ruby readers/clt_roads.rb
ruby readers/clt_tracks.rb
ruby readers/crossings.rb
ruby readers/parking.rb
ruby readers/restricted_routes.rb
ruby readers/traffic_calming_barriers.rb
ruby readers/traffic_calming_bumps.rb
ruby readers/traffic_calming_chicanes.rb
ruby readers/traffic_calming_sideroads.rb
ruby readers/traffic_calming_tables.rb

# Create .osm files
rm output/parking_osm_unique.geojson
rm output/parking_remapped.geojson
cd ..
ruby tflcid-conversion/tools/geojson_to_osm.rb tflcid-conversion/rejected/*.osm tflcid-conversion/output/*.geojson

# Zip
cd tflcid-conversion/
rm /srv/destination_site/osm/tfl_cid.zip
zip -r /srv/destination_site/osm/tfl_cid.zip output

# Git upload
git add output
git commit -m "Daily data update"
git push
