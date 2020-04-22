
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
output = { new: [], to_check: [], railways: [], tags_changed: [] }
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

	# Find road intersections
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

	# Find existing crossings
	fc = f['geometry']['coordinates'].flatten
	lon = (fc[0]+fc[-2])/2
	lat = (fc[1]+fc[-1])/2
	existing_crossings = collect_crossings(lat,lon,20)

	if !intersections.empty?
		# Use any/all intersections
		# (if any tally with an existing crossing, even better)
		intersections.each do |inter|
			nearest_existing = existing_crossings.min_by { |c| FasterHaversine.distance(c[:lon],c[:lat],inter[:lon],inter[:lat]) }
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
			else
				# Create a new crossing
				output[:new] << { type: "Feature", 
					properties: node_tags(inter[:id]).merge(osm_tags).merge(osm_id: inter[:id]), 
					geometry: { type: "Point", coordinates: [inter[:lon],inter[:lat]] } }
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
		ways = collect_ways(lat,lon,20)
		junctions = find_junctions(lat,lon,ways.collect {|w| w[:id]}).select { |j|
			j[:dist]<20 && 
			j[:highways].include?('cycleway') &&
			( ROADS.any? { |r| j[:highways].include?(r) } )
		}
		if junctions.empty?
			# Not found, so put in 'to_check'
			output[:to_check] << { type: "Feature", properties: osm_tags, geometry: { type: "Point", coordinates: [lon,lat] } }
		else
			# Recommend a new one at junctions
			junctions.each do |j|
				output[:new] << { type: "Feature", 
					properties: node_tags(j[:id]).merge(osm_tags).merge(osm_id: j[:id]), 
					geometry: { type: "Point", coordinates: [j[:lon],j[:lat]] } }
			end
		end

	end
end

puts "Total: #{output[:new].length} new, #{output[:tags_changed].length} tags changed, #{output[:railways].length} railway crossings, #{output[:to_check].length} to check"
puts "#{skipped} skipped (existing crossings with no tag conflict/change)"

File.write("#{__dir__}/../output/crossings_new.geojson",          { type: "FeatureCollection", features: output[:new         ] }.to_json)
File.write("#{__dir__}/../output/crossings_rail.geojson",         { type: "FeatureCollection", features: output[:railways    ] }.to_json)
File.write("#{__dir__}/../output/crossings_to_check.geojson",     { type: "FeatureCollection", features: output[:to_check    ] }.to_json)
File.write("#{__dir__}/../output/crossings_tags_changed.geojson", { type: "FeatureCollection", features: output[:tags_changed] }.to_json)
