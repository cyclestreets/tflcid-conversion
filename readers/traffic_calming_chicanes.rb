
# Traffic calming
# Chicane processing

# Three output files:
# - easy on-road changes
# - "islands"
# - chicanes that need checking (there's other traffic calming here)

require 'json'
require 'pg'
require 'colorize'
require_relative './tfl_common.rb'

data = JSON.parse(File.read("#{__dir__}/../tfl_data/traffic_calming.json"))
$conn = PG::Connection.new(dbname: "osm_london")
output = { new: [], islands: [], to_check: [] }
existing_count = 0

data['features'].each do |f|
	lon,lat = f['geometry']['coordinates'].map(&:to_f)
	next unless f['properties']['TRF_NAROW'] == 'TRUE'
	osm_tags = { "traffic_calming"=> "choker", "tfl_id"=> f['properties']['FEATURE_ID'] }

	# Look for existing calming

	calming = collect_calming(lat,lon,15)
	if calming.any? { |c| ["choker","chicane"].include?(c[:tags]['traffic_calming']) }
		existing_count += 1
		next
	end
	if !calming.empty?
		# Add to 'to_check' because there's something else here
		output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		next
	end

	# Look for one-way/cycleway bypass islands

	ways = collect_ways(lat,lon,15)
	if island(ways)
		puts "Found island"
		output[:islands] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		next
	end

	# Nothing there, so add a new one on the nearest road
	unless ways.empty?
		roads = ways.select { |w| ROADS.include?(w[:tags]['highway']) }
		nearby = nearest_nodes(lat,lon,roads.collect { |r| r[:id] })
		n = nearby[0]
		if n[:dist]<5
			puts "Use existing node #{n[:id]}".green
			output[:new] << { type: "Feature", 
				properties: node_tags(n[:id]).merge(osm_tags).merge(osm_id: n[:id]),
				geometry: { type: "Point", coordinates: [n[:lon],n[:lat]] } }
		else
			puts "New #{osm_tags['tfl_id']}".green
			new_lat, new_lon, prop = snap(lat,lon,roads[0][:id])
			new_index = way_subscript(new_lat,new_lon,roads[0][:id],prop)
			output[:new] << { type: "Feature", 
				properties: osm_tags.merge(osm_way_id: roads[0][:id], osm_insert_after: new_index), 
				geometry: { type: "Point", coordinates: [new_lon,new_lat] } }
		end
		
	# No nearby ways
	else
		puts "No ways".red
		output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
	end

end

puts "Totals: #{output[:new].count} new objects, #{output[:islands].count} islands, #{output[:to_check].count} to check"
puts "(Matched with #{existing_count} existing OSM nodes)"

write_output(output, 
	new:      "chicanes_new.geojson",
	islands:  "chicanes_islands.geojson",
	to_check: "chicanes_to_check.geojson" )
