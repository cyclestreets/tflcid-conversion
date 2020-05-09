
	# Traffic calming
	# Speed bumps processing

	# Two output files:
	# - easy on-road changes
	# - bumps that need checking (either because further away, or because they clash)

	# To find junctions, we:
	# - look for all _road_ ways nearby
	# - find all nodes in those ways
	# - count the number of ways per node
	# - return all nodes with 3+ ways near the supplied lat/lon

	# Import with: osm2pgsql -s --hstore-all -d osm_london greater-london-latest.osm.pbf

	require 'json'
	require 'pg'
	require 'colorize'
	require_relative './tfl_common.rb'

	data = JSON.parse(File.read("#{__dir__}/../tfl_data/traffic_calming.json"))
	$conn = PG::Connection.new(dbname: "osm_london")
	output = { table: [], to_check: [] }
	existing_count = 0

	data['features'].each do |f|
		lon,lat = f['geometry']['coordinates'].map(&:to_f)
		attrs = f['properties'].reject { |k,v| v=='FALSE' }
		type = (attrs.find { |k,v| v=='TRUE' })
		next if type.nil?
		type = type[0]
		next unless type=="TRF_RAISED"
		osm_tags = { "traffic_calming"=> "table", "tfl_id"=> attrs['FEATURE_ID'] }

		ways = collect_ways(lat,lon,100)
		junction_nodes = find_junctions(lat, lon, ways.collect { |w| w[:id] }).select { |j| j[:dist]<10 }
		if junction_nodes.empty?
			puts "Couldn't identify #{attrs['FEATURE_ID']}"
			debug_ways(ways,lat,lon)
			if !ways.empty? && ways[0][:dist]<10
				lat, lon, prop = snap(lat, lon, ways[0][:id])
				puts "(snapped)".red
			end
			output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		else
			# write features
			junction_nodes.each do |jn|
				existing = node_tags(jn[:id])
				if existing['traffic_calming']=='table' then existing_count+=1; next end
				target = existing['traffic_calming'] ? :to_check : :table
				output[target] << { type: "Feature", properties: existing.merge(osm_tags).merge(osm_id: jn[:id]), 
					geometry: { type: "Point", coordinates: [jn[:lon],jn[:lat]] } }
			end
		end
	end

	puts "Totals: #{output[:table].count} at junctions, #{output[:to_check].count} to check"
	puts "(Matched with #{existing_count} existing OSM nodes)"
	write_output(output, table: "tables.geojson", to_check: "tables_to_check.geojson")

