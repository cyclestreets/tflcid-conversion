# Advanced stop lines

# cycleway=asl
# asl:feeder=left|centre|right

require 'json'
require 'pg'
require 'colorize'
require_relative './tfl_common.rb'

data = JSON.parse(File.read("#{__dir__}/../tfl_data/advanced_stop_line.json"))
$conn = PG::Connection.new(dbname: "osm_london")
output = { new: [], new_tagged: [], add_feeder: [], to_check: [] }
skipped = 0

data['features'].each do |f|
	# Create OSM tags
	attrs = f['properties'].reject { |k,v| v=='FALSE' }
	osm_tags = { "cycleway"=>"asl", "tfl_id"=>f['properties']['FEATURE_ID'] }
	feeders = []
	feeders << "left"   if attrs['ASL_FDRLFT']
	feeders << "centre" if attrs['ASL_FDCENT']
	feeders << "right"  if attrs['ASL_FDRIGH']
	if !feeders.empty? then osm_tags['asl:feeder']=feeders.join(';') end
	print "TfL id #{osm_tags['tfl_id']} "
	
	# Get lat/lon centroid
	ls  = f['geometry']['coordinates']
	lon1,lat1,lon2,lat2 = ls.flatten
	lat = (lat1+lat2) / 2.0
	lon = (lon1+lon2) / 2.0

	# Does one exist already?
	existing_asls = collect_asls(lat1,lon1,lat2,lon2,10)
	if !existing_asls.empty?
		n = existing_asls[0] # :id, :tags, :dist, :lat, :lon
		if feeders.empty? || osm_tags['asl:feeder']==n[:tags]['asl:feeder']
			puts "- skipped".green
			skipped += 1
		else
			puts "- add feeder".blue
			output[:add_feeder] << { type: "Feature",
				properties: n[:tags].merge(osm_tags).merge(osm_id: n[:id]),
				geometry: { type: "Point", coordinates: [n[:lon],n[:lat]] } }
		end		
		
	# No, so find a new one
	else
		ways = collect_ways(lat,lon,20,false,false)
		obj  = { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }

		# If no ways nearby, skip
		if ways.empty? then puts "- no nearby ways, check".red; output[:to_check] << obj; next end

		# Is there an existing node somewhere nearby?
		way_ids = ways.collect {|w| w[:id]}
		existing_nodes = nearest_nodes(lat,lon,way_ids)
		existing_nodes.reject! { |n| is_junction?(n[:id],way_ids) }
		if existing_nodes.empty? then puts "- no nearby non-junction nodes, check".red; output[:to_check] << obj; next end
		
		# Is it near enough?
		en = existing_nodes[0] # :id, :lat, :lon, :way_id, :dist
		if en[:dist]>10
			# No, create a new one
			new_lat, new_lon, prop = snap(lat,lon,ways[0][:id])
			if prop==0 || prop==1 then puts "- couldn't snap".red; output[:to_check] << obj; next end
			new_index = way_subscript(new_lat,new_lon,ways[0][:id],prop)
			puts "- create new node".blue
			obj = { type: "Feature", 
				properties: osm_tags.merge(osm_way_id: ways[0][:id], osm_insert_after: new_index),
				geometry: { type: "Point", coordinates: [new_lon,new_lat] } }
			output[:new] << obj

		else
			# Yes, use the existing one
			et = node_tags(en[:id])
			layer = et.empty? ? :new : :new_tagged
			puts "- tag existing node".blue
			output[layer] << { type: "Feature", 
				properties: et.merge(osm_tags).merge(osm_id: en[:id]),
				geometry: { type: "Point", coordinates: [en[:lon],en[:lat]] } }
		end
	end

end

puts "Totals: #{output[:new].count} new ASLs, #{output[:new_tagged].count} on already-tagged nodes, #{output[:add_feeder].count} to add feeders only, #{output[:to_check].count} to check"
puts "#{skipped} skipped (existing ASL)"
write_output(output,
	new: "asl_new.geojson",
	new_tagged: "asl_new_tagged.geojson",
	add_feeder: "asl_add_feeder.geojson",
	to_check: "asl_to_check.geojson"
)
