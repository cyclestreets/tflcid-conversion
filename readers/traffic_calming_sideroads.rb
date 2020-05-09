
# Traffic calming
# Side-road processing

# - look for traffic_calming=table if that's there already
# - look for a crossing node if there is one
# - look for a junction between highway and cycleway/footway (<3m away) if there is one
#   _unless_ it involves a busy road
# - note that the vast majority _aren't_ on existing cycleways

# output:
# - existing

require 'json'
require 'pg'
require 'colorize'
require_relative './tfl_common.rb'

data = JSON.parse(File.read("#{__dir__}/../tfl_data/traffic_calming.json"))
$conn = PG::Connection.new(dbname: "osm_london")
output = { existing: [], at_junctions: [], new: [], to_check: [] }

data['features'].each do |f|
	lon,lat = f['geometry']['coordinates'].map(&:to_f)
	next unless f['properties']['TRF_ENTRY'] == 'TRUE'
	osm_tags = { "sidewalk"=> "yes", "continuous"=>"yes", "tfl_id"=> f['properties']['FEATURE_ID'] }

	ways = collect_ways(lat,lon,15,true)
	# debug_ways(ways,lat,lon)

	# Are there any traffic_calming=table nodes?

	calming = collect_calming(lat,lon,10)
	calming = calming.select { |c| c[:tags]['traffic_calming']=='table' }
	unless calming.empty?
		c = calming[0]
		output[:existing] << { type: "Feature", 
			properties: node_tags(c[:id]).merge(osm_tags).merge(osm_id: c[:id]), 
			geometry: { type: "Point", coordinates: [c[:lon],c[:lat]] } }
		next
	end

	# Are there any existing junctions between a highway and a cycleway/footway (<5m away)?

	juncs = find_junctions(lat,lon,ways.collect {|w| w[:id]})
	ct = 0
	juncs.select {|j| j[:dist]<5 }.each do |j|
		# check they involve a minor road and a cycleway/footway, and no major roads
		next unless j[:highways].any? { |h| MINOR_ROADS.include?(h) }
		next unless j[:highways].any? { |h| ["cycleway","footway"].include?(h) }
		next if j[:highways].any? {|h| ["trunk","primary","secondary","trunk_link","primary_link","secondary_link"].include?(h) }
		output[:at_junctions] << { type: "Feature", 
			properties: node_tags(j[:id]).merge(osm_tags).merge(osm_id: j[:id]), 
			geometry: { type: "Point", coordinates: [j[:lon],j[:lat]] } }
		ct += 1
	end
	next if ct>0

	# Are there any existing crossings?

	crossings = collect_crossings(lat,lon,10)
	ct = 0
	crossings.select {|c| c[:dist]<8 }.each do |c|
		# note that kerb=* or sloped_curb=yes are probably ok already
		output[:existing] << { type: "Feature", 
			properties: node_tags(c[:id]).merge(osm_tags).merge(osm_id: c[:id]), 
			geometry: { type: "Point", coordinates: [c[:lon],c[:lat]] } }
		ct += 1
	end
	next if ct>0

	# No, so create a new node
	# needs to be only on side-roads, not the major roads
	minor = ways.select { |w| MINOR_ROADS.include?(w[:tags]['highway']) }
	if minor.empty?
		# No minor road nearby, so add to to_check
		output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
	else
		# Look on nearest minor road
		ct = 0
		nearby = nearest_nodes(lat,lon,minor.collect { |r| r[:id] })
		nearby.each do |n|
			next if n[:dist]>3
			next if juncs.any? {|j| j[:id]==n[:id] }
			output[:new] << { type: "Feature", 
				properties: node_tags(n[:id]).merge(osm_tags).merge(osm_id: n[:id]), 
				geometry: { type: "Point", coordinates: [n[:lon],n[:lat]] } }
			ct += 1
		end
		if ct==0
			# Create a new snapped node
			new_lat, new_lon, prop = snap(lat,lon,minor[0][:id])
			if prop==0 || prop==1
				output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
			else
				new_index = way_subscript(new_lat,new_lon,minor[0][:id],prop)
				output[:new] << { type: "Feature",  
					properties: osm_tags.merge(osm_way_id: minor[0][:id], osm_insert_after: new_index), 
					geometry: { type: "Point", coordinates: [new_lon,new_lat] } }
			end
		end
	end
	
end

puts "Totals: #{output[:existing].count} existing crossings"
puts "  #{output[:at_junctions].count} at cycleway/footway junctions"
puts "  #{output[:new].count} entirely new"
puts "  #{output[:to_check].count} to check"

write_output(output,
	existing:     "sideroads_existing.geojson",
	at_junctions: "sideroads_at_junctions.geojson",
	new:          "sideroads_new.geojson",
	to_check:     "sideroads_to_check.geojson" )
