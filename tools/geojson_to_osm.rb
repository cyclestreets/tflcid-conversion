
	require 'csv'
	require 'json'
	require 'nokogiri'
	require 'colorize'

	require 'pg'
	require 'pg_array_parser'
	include PgArrayParser

	# Note that these had MultiLineStrings:
	# restricted_routes_new, clt_tracks_new [new]
	# clt_roads_contra, clt_roads_separate, restricted_routes_cycleways, clt_footways_partial, clt_roads_partial, clt_roads_unmatched, crossings_rail [all require manual work anyway]

	$conn = PG::Connection.new(dbname: "osm_london")
	next_negative_node = -1
	next_negative_way  = -1

	puts "Reading node versions"
	node_versions= {}
	CSV.read("node_versions.csv").each { |row| node_versions[row[0].to_i]=row[1].to_i }

	puts "Reading way versions"
	way_versions = {}
	CSV.read("way_versions.csv").each { |row| way_versions[row[0].to_i]=row[1].to_i }

	rejected = {}
	ARGV.each do |fn|
		if fn=~/\.osm$/
			puts "Reading rejected from #{fn}"
			doc = Nokogiri::XML(File.open(fn))
			doc.css("tag[k='tfl_id']"           ).each { |tag| rejected[tag.attributes['v'].value] = true }
			doc.css("tag[k='tiger:upload_uuid']").each { |tag| rejected[tag.attributes['v'].value] = true }

		elsif fn=~/\.geojson$/
			puts "Converting data from #{fn}"

			node_dependencies = {}
			doc = Nokogiri::XML("<osm version='0.6' generator='TfL CID Conversion' />")
			JSON.parse(File.read(fn))['features'].each do |feature|
				geom_type = feature['geometry']['type']
				co = feature['geometry']['coordinates']
				pr = feature['properties']
				next if rejected[pr['tfl_id']]
				feature['properties']['tiger:upload_uuid'] = pr['tfl_id']
				tags = feature['properties'].reject { |k,v| ["osm_id","osm_way_id","osm_insert_after","osm_current","tfl_id"].include?(k) }
			
				if geom_type=='LineString' && pr['osm_id']
					#  LineString, osm_id, tags								- modify existing way
					id = pr['osm_id'].to_i
					orig = get_way(id)
					way = doc.create_element("way", id: id, visible: true, version: way_versions[id])
					add_tags(doc, way, tags)
					add_waynodes(doc, way, orig[:nodes], node_dependencies)
					doc.root.add_child(way)
				
				elsif geom_type=='LineString'
					#  LineString, tags										- create new way
					# Create <node> elements
					nodelist = []
					co.each do |ll|
						lon,lat = ll
						node = doc.create_element("node", id: next_negative_node, lat: lat, lon: lon, visible: true)
						add_tags(doc, node, {})
						doc.root.prepend_child(node)
						nodelist << next_negative_node
						next_negative_node -= 1
					end
					way = doc.create_element("way", id: next_negative_way, visible: true)
					add_tags(doc, way, tags)
					add_waynodes(doc, way, nodelist, node_dependencies)
					doc.root.add_child(way)
					next_negative_way -= 1

				elsif geom_type=='MultiLineString'
					raise "Encountered MultiLineString - shouldn't happen"
				
				elsif pr['osm_id']
					#  Point, osm_id, tags									- modify existing node
					id = pr['osm_id'].to_i
					node = doc.create_element("node", id: id, lat: co[1], lon: co[0], visible: true, version: node_versions[id])
					add_tags(doc, node, tags)
					doc.root.prepend_child(node)
					node_dependencies[id] = false

				elsif pr['osm_way_id']
					#  Point, osm_way_id, osm_insert_after, tags			- create new node within way
					# Create <node> element
					node = doc.create_element("node", id: next_negative_node, lat: co[1], lon: co[0], visible: true)
					add_tags(doc, node, tags)
					doc.root.prepend_child(node)
					# Get way list and insert node
					orig = get_way(pr['osm_way_id'].to_i)
					orig[:nodes].insert(pr['osm_insert_after'].to_i+1, next_negative_node)
					# Create <way> element
					way_id = pr['osm_way_id']
					way = doc.create_element("way", id: way_id, visible: true, version: way_versions[way_id])
					add_tags(doc, way, orig[:tags])
					add_waynodes(doc, way, orig[:nodes], node_dependencies)
					doc.root.add_child(way)
					next_negative_node -= 1

				else
					#  Point, tags											- create new node
					node = doc.create_element("node", id: next_negative_node, lat: co[1], lon: co[0], visible: true)
					add_tags(doc, node, tags)
					doc.root.prepend_child(node)
					next_negative_node -= 1

				end
			end
		
			# Add dependent nodes
			node_dependencies.reject! { |k,v| v==false }
			unless node_dependencies.empty?
				sql = <<-SQL
				SELECT id,lat,lon,hstore_to_json(tags) AS tags
				FROM planet_osm_nodes
				LEFT JOIN planet_osm_point ON id=osm_id
				WHERE id IN (#{node_dependencies.keys.join(',')})
				SQL
				$conn.exec(sql).each do |res|
					id = res['id'].to_i
					node = doc.create_element("node", 
						id: id,
						lat: res['lat'].to_f/10000000.0,
						lon: res['lon'].to_f/10000000.0,
						version: node_versions[id],
						visible: true)
					add_tags(doc, node, JSON.parse(res['tags'])) unless res['tags'].nil?
					doc.root.prepend_child(node)
				end
			end
		
			# Write to file
			outfn = fn.gsub('.geojson','.osm.xml')
			puts outfn
			File.write(outfn, doc.to_xml)
		
		else
			puts "Didn't recognise file #{fn}"
		end
	end

BEGIN {
	def add_tags(doc, xml_node, tags)
		tags.each do |k,v|
			tag = doc.create_element("tag", k: k, v: v)
			xml_node.add_child(tag)
		end
	end
	
	def add_waynodes(doc, xml_node, nodes, node_dependencies)
		nodes.each do |id|
			nd = doc.create_element("nd", ref: id)
			xml_node.add_child(nd)
			unless node_dependencies.key?(id) || id<0 then node_dependencies[id]=true end
		end
	end

	def get_way(way_id)
		res = $conn.exec("SELECT nodes,tags FROM planet_osm_ways WHERE id=#{way_id}")[0]
		{ tags:  Hash[*parse_pg_array(res['tags'] || '{}')],
		  nodes: parse_pg_array(res['nodes']).map(&:to_i) }
	end
}