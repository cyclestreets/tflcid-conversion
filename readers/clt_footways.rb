
	# Find footways which should be retagged as cycleways

	require 'json'
	require 'pg'
	require 'colorize'
	require_relative './tfl_common.rb'

	data = JSON.parse(File.read("#{__dir__}/../tfl_data/cycle_lane_track.json"))
	$conn = PG::Connection.new(dbname: "osm_london")
	skipped = 0
	TOLERANCE = 5
	output = { full: [], partial: [] }

	data['features'].each_with_index do |f,id|
		pr = f['properties']
		next unless pr['CLT_CARR']=='FALSE'
		next if pr['CLT_PARKR']=='TRUE'
		next if f['geometry']['type']=='MultiLineString' && f['geometry']['coordinates'].length>100

		# look for all footways within buffer
		sql = <<-SQL
		SELECT ST_Length(geom) AS tfl, ST_Length(way) AS osm,
		       ST_Length(ST_Intersection(way,ST_Buffer(geom,#{TOLERANCE}))) AS overlap,
			   ST_AsGeoJSON(ST_Transform(ST_Intersection(way,ST_Buffer(geom,#{TOLERANCE},'endcap=butt')),4326)) AS geo,
			   highway,osm_id,hstore_to_json(tags) AS tags
		  FROM cycle_lane_track
		  JOIN planet_osm_line
		    ON ST_DWithin(geom,way,#{TOLERANCE})
		 WHERE cycle_lane_track.id=$1 AND ((highway='footway' OR highway='path' OR highway='steps') AND (bicycle IS NULL OR bicycle='no'))
		SQL
		$conn.exec_params(sql, [id]).each do |res|
			next if res['geo'].nil?
			geo = JSON.parse(res['geo'])
			next if geo['geometries']==[]

			# skip if there's only a slight overlap
			prop = res['overlap'].to_f/res['osm'].to_f # 0.5=half of OSM way is affected, 1.0=all of OSM way affected
			next if prop<0.2 || res['overlap'].to_f<10

			# skip if there's a parallel cycleway
			sql = <<-SQL
			WITH buffer AS (
				SELECT ST_Buffer(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON($1),4326),3857),#{TOLERANCE*2}) AS g
			)
			SELECT ST_Length(ST_Intersection(buffer.g,way)) AS l
			FROM planet_osm_line
			JOIN buffer ON ST_Intersects(buffer.g,way)
			WHERE highway='cycleway' OR (highway IS NOT NULL AND (bicycle='yes' OR bicycle='designated'))
			SQL
			total = $conn.exec_params(sql,[geo.to_json]).inject(0) { |sum,res| sum+res['l'].to_f }
			next if total/res['overlap'].to_f > 0.8

			# write out
			tags = clt_osm_tags(pr,JSON.parse(res['tags'])).merge(tfl_id: pr['FEATURE_ID'], osm_id: res['osm_id'].to_i)
			if prop>0.8
				puts "#{pr['FEATURE_ID']} - https://osm.org/way/#{res['osm_id']} should be bikeable"
				output[:full] << { type: "Feature", properties: tags, geometry: geo }
			else
				puts "#{pr['FEATURE_ID']} - #{(prop*100).to_i}% of https://osm.org/way/#{res['osm_id']} should be bikeable"
				output[:partial] << { type: "Feature",  properties: tags, geometry: geo }
			end
		end
	end

	puts "Totals: #{output[:full].count} full changes, #{output[:partial].count} partial changes"
	write_output(output, full: "clt_footways_full.geojson", partial: "clt_footways_partial.geojson")
