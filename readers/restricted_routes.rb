# Restricted routes
# - Create geometry from GeoJSON
# - Buffer by n metres
# - Get total ST_Length of the intersection of all ways with it
# - If significantly less, then we need to add it

# Output:
# - new paths
# - paths where the attributes differ

# Import with: osm2pgsql -s --hstore-all -d osm_london greater-london-latest.osm.pbf

require 'json'
require 'pg'
require 'colorize'
require_relative './tfl_common.rb'

data = JSON.parse(File.read("#{__dir__}/../tfl_data/restricted_route.json"))
$conn = PG::Connection.new(dbname: "osm_london")
output = { new: [], cycleways: [] }
skipped = 0
OVERLAP_TOLERANCE = 8
EXISTING_TOLERANCE = 5

$conn.exec "DROP TABLE IF EXISTS restricted_routes"
$conn.exec "CREATE TEMPORARY TABLE restricted_routes (id INT, feature_id VARCHAR(20), geom GEOMETRY(MultiLineString, 3857) )"
$conn.exec "CREATE INDEX rr_geom_idx ON restricted_routes USING GIST(geom)"

# Read into database

puts "Reading into database"
data['features'].each_with_index do |f,id|
	if f['geometry']['type']=='MultiLineString'
		l = f['geometry']['coordinates'].length
	end
	$conn.exec_params("INSERT INTO restricted_routes VALUES($1,$2,ST_Multi(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON($3),4326),3857)))",
		[id,f['properties']['FEATURE_ID'], f['geometry'].to_json])
end

# Eliminate overlapping parts
# This identifies paths that are currently missing from OSM

puts "Eliminating overlapping parts"
data['features'].each_with_index do |f,id|
	sql = <<-SQL
	SELECT ST_AsGeoJSON(ST_Transform(ST_Difference(geom, COALESCE(ST_Union(ARRAY(
		SELECT ST_Buffer(way,#{OVERLAP_TOLERANCE}) FROM planet_osm_line 
		WHERE highway IN ('footway','path','steps','service','track','cycleway','bridleway','pedestrian')
		AND ST_DWithin(geom,way,#{OVERLAP_TOLERANCE})
	))
	,ST_GeomFromText('GEOMETRYCOLLECTION EMPTY',3857) )
	),4326))
	FROM restricted_routes WHERE restricted_routes.id=$1
	SQL
	res = $conn.exec_params(sql, [id]).values[0]
	if res.nil? || res[0].nil? then skipped+=1; next end
	geo = JSON.parse(res[0])
	if geo['geometries']==[] then skipped+=1; next end
	output[:new] << { type: "Feature", properties: { tfl_id: f['properties']['FEATURE_ID'] }, geometry: geo }
end

# Look for existing paths currently tagged as cycle-accessible, where the tagging may need changing
# This is a bit unreliable because:
# - the geometry might represent a footpath beside a service road (e.g. Endymion Road entrance to Finsbury Park)
# - because we're buffering, we'll catch the footpath within the buffer of the service road
# - but we need to buffer, because otherwise we wouldn't catch paths which have been divergently mapped in OSM and TfL

puts "Looking for existing cycleways"
data['features'].each_with_index do |f,id|
	# Skip really long ones as the SQL bogs out
	next if f['geometry']['type']=='MultiLineString' && f['geometry']['coordinates'].length>100

	sql = <<-SQL
	SELECT ST_Length(geom) AS tfl, ST_Length(way) AS osm,
	       ST_Length(ST_Intersection(way,ST_Buffer(geom,#{EXISTING_TOLERANCE}))) AS overlap,
		   ST_AsGeoJSON(ST_Transform(ST_Intersection(way,ST_Buffer(geom,#{EXISTING_TOLERANCE})),4326)) AS geo,
		   highway,osm_id
	  FROM restricted_routes
	  JOIN planet_osm_line
	    ON ST_DWithin(geom,way,#{EXISTING_TOLERANCE})
	 WHERE restricted_routes.id=$1 AND osm_id>0 AND highway IN ('service','track','cycleway')
	SQL
	osm = 0; tfl = 0; geoms = []
	$conn.exec_params(sql, [id]).each do |res|
		next if res['overlap'].to_f<20
		output[:cycleways] << { type: "Feature",
			properties: { tfl_id: f['properties']['FEATURE_ID'], osm_id: res['osm_id'].to_i },
			geometry: JSON.parse(res['geo']) }
	end
end

puts "Totals: #{output[:new].count} new objects, #{output[:cycleways].count} cycleways to revise"
puts "(#{skipped} were matched with OSM)"

File.write("#{__dir__}/../output/restricted_routes_new.geojson"      , { type: "FeatureCollection", features: output[:new      ] }.to_json)
File.write("#{__dir__}/../output/restricted_routes_cycleways.geojson", { type: "FeatureCollection", features: output[:cycleways] }.to_json)
