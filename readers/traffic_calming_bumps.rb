
	# Traffic calming
	# Speed bumps processing

	# Three output files:
	# - easy on-road changes
	# - cycleway bumps
	# - bumps that need checking (either because further away, or because they clash)

	# Import with: osm2pgsql -s --hstore-all -d osm_london greater-london-latest.osm.pbf

	require 'json'
	require 'pg'
	require 'colorize'
	require_relative './tfl_common.rb'

	data = JSON.parse(File.read("#{__dir__}/../tfl_data/traffic_calming.json"))
	$conn = PG::Connection.new(dbname: "osm_london")
	output = { road: [], cycleway: [], to_check: [] }
	nodes_created = 0
	new_features = 0

	data['features'].each do |f|
		lon,lat = f['geometry']['coordinates'].map(&:to_f)
		attrs = f['properties'].reject { |k,v| v=='FALSE' }
		type = (attrs.find { |k,v| v=='TRUE' })
		next if type.nil?
		type = type[0]
		next unless ["TRF_CUSHI","TRF_HUMP","TRF_CALM"].include?(type)
		osm_tags =	type=='TRF_CUSHI' ? { traffic_calming: 'cushion' } :
					type=='TRF_HUMP'  ? { traffic_calming: 'hump' } : { traffic_calming: 'yes' }
		if attrs['TRF_SINUSO'] then osm_tags[:sinusoidal]='yes' end
		osm_tags[:tfl_id] = attrs['FEATURE_ID']
		
		ways = collect_ways(lat,lon,100)
		calming = collect_calming(lat,lon,10)
		crossings = collect_crossings(lat,lon,20)
		if ways.empty?
			puts "Couldn't find any nearby ways".red
			output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
			next
		end

		puts "#{type} / #{calming.count} calming / #{crossings.count} crossings"

		if !calming.empty? && calming[0][:dist]<10
			# Existing traffic calming
			c = calming[0]
			puts "Calming within 10m; #{c}".blue
			if ["bump","hump","table","cushion"].include?(c[:tags]['traffic_calming'])
				# if it's bump/hump/table/cushion, we're fine
				# (could consider adding sinusoidal tag but really not significant!)
				puts "Already mapped"
				output[:road] << { type: "Feature", 
					properties: c[:tags].merge(osm_id: c[:id], tfl_id: attrs['FEATURE_ID']),
					geometry: { type: "Point", coordinates: [c[:lon],c[:lat]] } }
			elsif c[:tags]['traffic_calming']=='yes'
				# if it's "yes", promote to correct type
				puts "Currently tc=yes, set type"
				output[:road] << { type: "Feature", 
					properties: c[:tags].merge(osm_tags).merge(osm_id: c[:id]),
					geometry: { type: "Point", coordinates: [c[:lon],c[:lat]] } }
			else
				# if it's anything else, output to manual review file
				puts "Potentially clashing tag (#{c[:tags]['traffic_calming']}), review"
				output[:to_check] << { type: "Feature", 
					properties: c[:tags].merge(osm_tags).merge(osm_id: c[:id], osm_current: c[:tags][:traffic_calming]),
					geometry: { type: "Point", coordinates: [lon,lat] } }
			end

		elsif !crossings.empty? && crossings[0][:dist]<10
			# Existing crossing
			puts "Crossing within 10m; #{crossings[0]}".blue
			output[:road] << { type: "Feature", 
				properties: crossings[0][:tags].merge(osm_tags).merge(osm_id: crossings[0][:id]),
				geometry: { type: "Point", coordinates: [crossings[0][:lon],crossings[0][:lat]] } }
			new_features += 1

		elsif ways[0][:dist]<10
			# Existing roadway within 10m
			# (look at all roadways of the same class within 20m to help find the nearest node)
			puts "Road within 10m; #{ways[0]}".blue
			way_candidates = [ways[0][:id]]
			ways[1..-1].each do |w|
				if w[:dist]<20 && w[:tags]['highway']==ways[0][:tags]['highway'] then way_candidates << w[:id] end
			end
			nearby = nearest_nodes(lat,lon,way_candidates)
			n = nearby[0]
			if n[:dist]<10
				puts "Use existing node #{n[:id]}"
				highway = ways.find { |w| w[:id]==n[:way_id] }[:tags]['highway']
				feature = { type: "Feature", 
					properties: node_tags(n[:id]).merge(osm_tags).merge(osm_id: n[:id]),
					geometry: { type: "Point", coordinates: [n[:lon],n[:lat]] } }

			else
				puts "Create new node"
				highway = ways[0][:tags]['highway']
				new_lat, new_lon, prop = snap(lat,lon,ways[0][:id])
				puts "Snapping to #{new_lat},#{new_lon}"
				new_index = way_subscript(new_lat,new_lon,ways[0][:id],prop)
				feature = { type: "Feature", 
					properties: osm_tags.merge(osm_way_id: ways[0][:id], osm_insert_after: new_index),
					geometry: { type: "Point", coordinates: [new_lon,new_lat] } }
				nodes_created += 1
			end
			if highway=='cycleway' then
				puts "On cycleway".green
				output[:cycleway] << feature
			else
				output[:road] << feature
			end
			new_features += 1
		
		else
			puts "No match within 10m".red
			output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		end

		puts

	end

	puts "Totals: #{output[:road].count} on roads, #{output[:cycleway].count} on cycleways, #{output[:to_check].count} to check"
	puts "New: any features #{new_features}, OSM nodes #{nodes_created}"
	write_output(output,
		road: "bumps_road.geojson",
		cycleway: "bumps_cycleway.geojson",
		to_check: "bumps_to_check.geojson" )
