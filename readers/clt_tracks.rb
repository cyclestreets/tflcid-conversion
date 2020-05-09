
	# Read cycle tracks

	require 'json'
	require 'pg'
	require 'colorize'
	require_relative './tfl_common.rb'

	data = JSON.parse(File.read("#{__dir__}/../tfl_data/cycle_lane_track.json"))
	$conn = PG::Connection.new(dbname: "osm_london")
	skipped = 0
	TOLERANCE = 10
	output = { new: [] }
	
	# New tracks (no existing geometry)
	
	data['features'].each_with_index do |f,id|
		pr = f['properties']
		next unless pr['CLT_CARR']=='FALSE'
		next if pr['CLT_PARKR']=='TRUE'

		# Remove anything within n metres of an existing OSM cycleway
		sql = <<-SQL
		SELECT ST_AsGeoJSON(ST_Transform(ST_Difference(geom, COALESCE(ST_Union(ARRAY(
			SELECT ST_Buffer(way,
				CASE WHEN (highway IS NOT NULL AND (tags->'cycleway'='track' OR tags->'cycleway:left'='track' OR tags->'cycleway:right'='track')) THEN #{TOLERANCE*2}
				ELSE #{TOLERANCE} END
			) FROM planet_osm_line 
			WHERE osm_id>0 AND ST_DWithin(geom,way,#{TOLERANCE*2}) AND (area IS NULL OR area != 'yes') AND (
				(highway IN ('cycleway','path','track','bridleway','footway','steps','service')) OR
				(highway IS NOT NULL AND (tags->'motor_vehicle'='no')) OR
				(highway IS NOT NULL AND (tags->'cycleway'='track' OR tags->'cycleway:left'='track' OR tags->'cycleway:right'='track'))
			)
		))
		,ST_GeomFromText('GEOMETRYCOLLECTION EMPTY',3857) )
	    ),4326)) AS geo,
		ST_Length(ST_Transform(geom,27700)) AS orig_length
		FROM cycle_lane_track WHERE cycle_lane_track.id=$1
		SQL
		$conn.exec_params(sql, [id]).each do |res|
			if res['geo'].nil? then skipped+=1; next end
			geo = JSON.parse(res['geo'])
			if geo['geometries']==[] then skipped+=1; next end

			# Select the original geometry within a buffer of the returned one
			# This fixes breaks where we were crossing roads
			is_multi = geo['type']=='MultiLineString'
			sql = <<-SQL
			SELECT ST_AsGeoJSON(ST_Transform(
				ST_Intersection(
					ST_Buffer(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON($1),4326),3857),#{is_multi ? TOLERANCE*2.1 : TOLERANCE}),
				geom), 4326)) AS geo
			FROM cycle_lane_track WHERE id=$2
			SQL
			geo = JSON.parse($conn.exec_params(sql, [geo.to_json, id])[0]['geo'])
			next if geojson_length(geo)<10

			output[:new] << { type: "Feature", 
				properties: clt_osm_tags(pr).merge( tfl_id: pr['FEATURE_ID'] ), 
				geometry: geo }
		end
	end

	puts "Totals: #{output[:new].count} new objects"
	puts "(#{skipped} were matched with OSM)"
	write_output(output, new: "clt_tracks_new.geojson")
