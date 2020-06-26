
# Traffic calming
# Crossings processing

# highway=crossing plus...
#"CRS_SIGNAL"	signal-controlled		crossing=traffic_signals|uncontrolled
#"CRS_SEGREG"	cyclists segregated		segregated=yes|no
#"CRS_CYGAP"	includes gap in island	[discard]
#"CRS_PEDEST"	cyclists dismount		bicycle=dismount
#"CRS_LEVEL"	crosses a railway		railway=crossing

# Output files:
# - new crossings
# - existing crossings with conflict
# - railways

# Import with: osm2pgsql -s --hstore-all -d osm_london greater-london-latest.osm.pbf

require 'json'
require 'pg'
require 'colorize'
require_relative './tfl_common.rb'

data = JSON.parse(File.read("#{__dir__}/../tfl_data/crossing.json"))
$conn = PG::Connection.new(dbname: "osm_london")
output = { to_check: [], railways: [], junctions: [], tags_changed: [] }
skipped = 0

data['features'].each do |f|
	attrs = f['properties'].reject { |k,v| v=='FALSE' }
	osm_tags = { "highway"=> "crossing", "tfl_id"=>attrs['FEATURE_ID'] }
	osm_tags['crossing'] = attrs['CRS_SIGNAL'] ? "traffic_signals" : "uncontrolled"
	if attrs['CRS_SEGREG'] then osm_tags['segregated'] = "yes" end
	if attrs['CRS_PEDEST'] then osm_tags['bicycle']="dismount" end
	if attrs['CRS_LEVEL'] then 
		output[:railways] << { type: "Feature", properties: osm_tags, geometry: f['geometry'] }
		next
	end
	if attrs['CRS_CYGAP'] && !attrs['CRS_SIGNAL'] && !attrs['CRS_PEDEST'] && !attrs['CRS_SEGREG']
		next
	end

	# -------------------------------
	# Get OSM data points to consider

	# Find road intersections
	# intersections is an array of {:lat,:lon,:highway,:tags,:id} for all crossing roads
	geom = f['geometry'].to_json # suitable for ST_GeomFromGeoJSON
	sql = <<-SQL
	SELECT osm_id,highway,hstore_to_json(tags) AS tags,
		   st_astext(st_transform(st_centroid(st_intersection(way,ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON($1),4326),3857))),4326)) AS geom_text
	  FROM planet_osm_line
	 WHERE highway IN (#{ROADS.collect {|r| "'"+r+"'"}.join(',') })
	   AND ST_Intersects(way,ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON($1),4326),3857))
	SQL
	intersections = $conn.exec_params(sql, [geom]).collect do |res|
		lon,lat = res['geom_text'].delete('POINT()').split(' ').map(&:to_f)
		{ id: res['osm_id'].to_i, highway: res['highway'], tags: JSON.parse(res['tags']), lon: lon, lat: lat }
	end

	# Find existing crossing nodes nearby
	# existing_crossings is an array of {:lat,:lon,:dist,:tags,:id} for all crossing nodes within 20m
	fc = f['geometry']['coordinates'].flatten
	lon = (fc[0]+fc[-2])/2
	lat = (fc[1]+fc[-1])/2
	existing_crossings = collect_crossings(lat,lon,20)

	# Find all existing junctions
	# junctions is an array of {:lat,:lon,:dist,:highways,:id } for all junctions within 20m
	ways = collect_ways(lat,lon,20,true)
	junctions = find_junctions(lat,lon,ways.collect {|w| w[:id]}).select { |j|
		j[:dist]<20 && 
		( PATHS.any? { |r| j[:highways].include?(r) } ) &&
		( ROADS.any? { |r| j[:highways].include?(r) } )
	}

	# -------------------------------
	# Examine all OSM roads that the TfL line crosses

	if !intersections.empty?
		intersections.each do |inter|
			nearest_existing = existing_crossings.min_by { |c| FasterHaversine.distance(c[:lon],c[:lat],inter[:lon],inter[:lat]) }

			# --> Existing crossing, so use that
			if nearest_existing
				if tags_clash(osm_tags, nearest_existing[:tags])
					puts "Tag clash".red
					puts "Old: #{nearest_existing[:tags]}"
					puts "New: #{osm_tags}"
					output[:to_check] << { type: "Feature", 
						properties: nearest_existing[:tags].merge(osm_tags).merge(osm_id: nearest_existing[:id]),
						geometry: { type: "Point", coordinates: [nearest_existing[:lon],nearest_existing[:lat]] } 
					}
				elsif tags_additional(osm_tags, nearest_existing[:tags])
					puts "Tags changed".green
					puts "Old: #{nearest_existing[:tags]}"
					puts "New: #{osm_tags}"
					output[:tags_changed] << { type: "Feature", 
						properties: nearest_existing[:tags].merge(osm_tags).merge(osm_id: nearest_existing[:id]),
						geometry: { type: "Point", coordinates: [nearest_existing[:lon],nearest_existing[:lat]] } 
					}
				else
					skipped +=1
				end

			# --> No existing crossing, but there's a cycleway junction we can use
			elsif junctions.any? { |j| j[:way_ids].include?(inter[:id]) }
				n = junctions.find { |j| j[:way_ids].include?(inter[:id]) }
				puts "Use cycleway junction #{n[:id]}: https://osm.org/node/#{n[:id]}".green
				output[:junctions] << { type: "Feature", 
					properties: node_tags(n[:id]).merge(osm_tags).merge(osm_id: n[:id]), 
					geometry: { type: "Point", coordinates: [n[:lon],n[:lat]] } }

			# --> No obvious candidate, so create a new crossing, using an existing node if we can
			else
				nearby = nearest_nodes(lat,lon,[inter[:id]])
				n = nearby[0]
				if n[:dist]<10
					puts "Use existing node #{n[:id]}: https://osm.org/node/#{n[:id]}".blue
					output[:to_check] << { type: "Feature", 
						properties: node_tags(n[:id]).merge(osm_tags).merge(osm_id: n[:id]),
						geometry: { type: "Point", coordinates: [n[:lon],n[:lat]] } }
				else
					puts "New node".blue
					new_index = way_subscript(inter[:lat],inter[:lon],inter[:id])
					output[:to_check] << { type: "Feature", 
						properties: osm_tags.merge(osm_way_id: inter[:id], osm_insert_after: new_index), 
						geometry: { type: "Point", coordinates: [inter[:lon],inter[:lat]] } }
				end
			end
		end

	elsif !existing_crossings.empty?
		# No intersection, but there's an existing crossing anyway
		# (this code is C&P-ed from above, so sue me)
		nearest_existing = existing_crossings[0]
		if tags_clash(osm_tags, nearest_existing[:tags])
			puts "Tag clash".red
			puts "Old: #{nearest_existing[:tags]}"
			puts "New: #{osm_tags}"
			output[:to_check] << { type: "Feature", 
				properties: nearest_existing[:tags].merge(osm_tags).merge(osm_id: nearest_existing[:id]),
				geometry: { type: "Point", coordinates: [nearest_existing[:lon],nearest_existing[:lat]] } 
			}
		elsif tags_additional(osm_tags, nearest_existing[:tags])
			puts "Tags changed".green
			puts "Old: #{nearest_existing[:tags]}"
			puts "New: #{osm_tags}"
			output[:tags_changed] << { type: "Feature", 
				properties: nearest_existing[:tags].merge(osm_tags).merge(osm_id: nearest_existing[:id]),
				geometry: { type: "Point", coordinates: [nearest_existing[:lon],nearest_existing[:lat]] } 
			}
		else
			skipped+=1
		end

	else
		# Can't find any intersecting or existing crossings, so look for a cycleway crossing a road
		if junctions.empty?
			# Not found, so put in 'to_check'
			output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		else
			# Recommend a new one at junctions
			junctions.each do |j|
				output[:junctions] << { type: "Feature", 
					properties: node_tags(j[:id]).merge(osm_tags).merge(osm_id: j[:id]), 
					geometry: { type: "Point", coordinates: [j[:lon],j[:lat]] } }
			end
		end

	end
end

puts "Total: #{output[:junctions].length} at existing junctions, #{output[:tags_changed].length} tags changed, #{output[:railways].length} railway crossings, #{output[:to_check].length} to check"
puts "#{skipped} skipped (existing crossings with no tag conflict/change)"

write_output(output,
	junctions:    "crossings_junctions.geojson",  
	railways:     "crossings_rail.geojson",       
	to_check:     "crossings_to_check.geojson",   
	tags_changed: "crossings_tags_changed.geojson")
