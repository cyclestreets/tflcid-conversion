
# Traffic calming
# Barrier processing

# Outputs:
# - new
# - already mapped with cycleways
# - to check

# - First, look for existing features
# - If there's _only_ cycleways and nothing else nearby, then add it
# - If there's a short cycleway/path (and no existing barrier) within 6m, find a nearby node or (for 2-node ways) a midpoint
#	 (same applies to highway=pedestrian)
#    (if the cycleway is still <10m, add to to_check)
#    (if it's a longer cycleway, snap nearby)
# - If there's an island, choose the non-cycleway 
# - Don't use junctions between 3+ roads, but _do_ use junctions between 2 roads if one is limited access or a path
# - Don't use major roads (anything other than unclassified, residential, service, cycleway should probably go into to_check)

require 'json'
require 'pg'
require 'colorize'
require_relative './tfl_common.rb'

data = JSON.parse(File.read("#{__dir__}/../tfl_data/traffic_calming.json"))
$conn = PG::Connection.new(dbname: "osm_london")
output = { new: [], cycleways: [], to_check: [] }
existing_count = 0

data['features'].each do |f|
	lon,lat = f['geometry']['coordinates'].map(&:to_f)
	next unless f['properties']['TRF_BARIER'] == 'TRUE'
	osm_tags = { "barrier"=> "yes", "access"=>"no", "bicycle"=>"yes", "foot"=>"yes", "tfl_id"=> f['properties']['FEATURE_ID'] }

	# Is there an existing barrier?
	barriers = collect_barriers(lat,lon,10)
	if barriers.any? { |b| ["block","yes","gate","swing_gate","bollard","lift_gate","sump_buster","cycle_barrier"].include?(b[:type]) }
		puts "Found a barrier".red
		existing_count += 1
		next
	end

	# Are there any ways at all in the area?
	ways = collect_ways(lat,lon,15,true) #.reject { |w| w[:tags]['highway']=='footway' }
	if ways.empty?
		puts "No road found".red
		output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		next
	end

	# Is it a simple situation with just a minor road needing a barrier, and no paths?
	has_paths = ways.any? { |w| ["cycleway","path","pedestrian"].include?(w[:tags]['highway']) }
	if !has_paths && VMINOR_ROADS.include?(ways[0][:tags]['highway'])
		puts "Create on first road".green
		add_at_new_location(ways,lat,lon,VMINOR_ROADS,output,osm_tags)
		next
	end
	
	# Is it just cycleways/paths?
	if ways.all? { |w| ["cycleway","path","pedestrian"].include?(w[:tags]['highway']) }
		if (ways.count { |w| ["cycleway","path","pedestrian"].include?(w[:tags]['highway']) && w[:dist]<3 })>1
			# yes, but more than one within 3m, so unclear which to add to
			output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		else
			puts "Create on first cycleway".green
			add_at_new_location(ways,lat,lon,["cycleway","path","pedestrian"],output,osm_tags)
		end
		next
	end
	
	# Is there a cycleway within 10m, or a path at all within 5m?
	if ways.any? { |w| (w[:tags]['highway']=='cycleway' && w[:dist]<10) || (["path","pedestrian","footway"].include?(w[:tags]['highway']) && w[:dist]<5) }
		puts "Existing cycleway".blue
		nearest = ways.find { |w| ["cycleway","path","pedestrian","footway"].include?(w[:tags]['highway']) }
		lat,lon,prop = snap(lat,lon,nearest[:id])
		output[:cycleways] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		next
	end

	puts "More complex situation".red
	output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
end


puts "Totals: #{output[:new].count} new objects, #{output[:cycleways].count} with cycleways nearby, #{output[:to_check].count} to check"
puts "(Matched with #{existing_count} existing OSM nodes)"

write_output(output, new: "barriers_new.geojson", cycleways: "barriers_cycleways.geojson", to_check: "barriers_to_check.geojson")

BEGIN {

	def add_at_new_location(ways,lat,lon,road_types,output,osm_tags)
		# look for a node, on a way of specified type, within 3m
		selected_way_ids = ways.select { |w| road_types.include?(w[:tags]['highway']) }.collect { |w| w[:id] }
		nodes = nearest_nodes(lat,lon,selected_way_ids)
		# find junctions so we can reject them
		junctions = find_junctions(lat,lon,ways.collect { |w| w[:id] })
		# reject any nodes which are at a junction
		nodes.reject! { |n| junctions.any? { |j| j[:id]==n[:id] } }
		# if there's a node within 3m, use it; otherwise create new one
		# (but if we're beyond the start/end, we can't create a new one, so we snap to start/end)
		n = nodes.find { |n| n[:dist]<3 }
		new_lat,new_lon,prop = snap(lat,lon,selected_way_ids[0])
		if !n && (prop==0 || prop==1) then n=nodes[0] end
		if n
			puts "Reuse node".blue
			output[:new] << { type: "Feature",
				properties: node_tags(n[:id]).merge(osm_tags).merge(osm_id: n[:id]),
				geometry: { type: "Point", coordinates: [lon,lat] } }
		else
			puts "Create new node".blue
			new_index = way_subscript(new_lat,new_lon,selected_way_ids[0],prop)
			output[:new] << { type: "Feature", 
				properties: osm_tags.merge(osm_way_id: selected_way_ids[0], osm_insert_after: new_index), 
				geometry: { type: "Point", coordinates: [new_lon,new_lat] } }
		end
	end

}
