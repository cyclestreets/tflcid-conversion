
	require 'faster_haversine'
	require 'pg_array_parser'
	include PgArrayParser

	ROADS = ['trunk','trunk_link','primary','primary_link','secondary','secondary_link','tertiary','tertiary_link',
		'unclassified','residential','service','living_street','pedestrian']
	MINOR_ROADS = ['tertiary','unclassified','residential','service','living_street','pedestrian']
	VMINOR_ROADS= ['unclassified','residential','service','living_street','track']
	PATHS = ['cycleway','footway','path']

	# ==============================================================================================================
	# Fetch geometries from database
	# ==============================================================================================================

	# Fetch OSM objects near a lat/lon

	def collect_ways(lat,lon,radius,include_foot=false)
		sql = <<-SQL
		SELECT ST_Distance( way, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857) ) AS dist,
			   ST_Length(way) AS length,
			   ST_Azimuth(ST_StartPoint(way),ST_EndPoint(way)) AS angle,
			   hstore_to_json(tags) AS tags, osm_id
		  FROM planet_osm_line
		 WHERE highway IN (#{ROADS.collect {|r| "'"+r+"'"}.join(',') },
			 'cycleway' #{ include_foot ? ",'footway','path','track'" : "" })
		   AND ST_DWithin( way, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857), $3 ) AND osm_id>0
	  ORDER BY dist
		SQL
		$conn.exec_params(sql,[lon,lat,radius]).collect { |res| { 
			id: res['osm_id'].to_i, tags: JSON.parse(res['tags'] || '{}'), dist: res['dist'].to_f,
			angle: res['angle'].to_f, length: res['length'].to_f
		} }
	end
	
	def debug_ways(ways,lat,lon)
		puts "https://www.openstreetmap.org/?mlat=#{lat}&mlon=#{lon}#map=19/#{lat}/#{lon}&layers=C"
		ways.each_with_index do |w,i|
			puts "  #{w[:tags]['highway']} - #{w[:id]} - #{w[:dist]}"
		end
	end

	def collect_barriers(lat,lon,radius)
		sql = <<-SQL
		SELECT ST_Distance( way, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857) ) AS dist, 
			   barrier, hstore_to_json(tags) AS tags, osm_id,
			   ST_X(ST_Transform(way,4326)) AS lon,
			   ST_Y(ST_Transform(way,4326)) AS lat
		  FROM planet_osm_point
		 WHERE barrier IS NOT NULL
		   AND ST_DWithin( way, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857), $3 )
	  ORDER BY dist
		SQL
		$conn.exec_params(sql,[lon,lat,radius]).collect { |res| { id: res['osm_id'].to_i, type: res['barrier'], tags: JSON.parse(res['tags'] || '{}'), dist: res['dist'].to_f, lat: res['lat'].to_f, lon: res['lon'].to_f } }
	end
	
	def collect_calming(lat,lon,radius)
		sql = <<-SQL
		SELECT ST_Distance( way, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857) ) AS dist,
			   hstore_to_json(tags) AS tags, osm_id,
			   ST_X(ST_Transform(way,4326)) AS lon,
			   ST_Y(ST_Transform(way,4326)) AS lat
		  FROM planet_osm_point
		 WHERE tags->'traffic_calming' IS NOT NULL
		   AND ST_DWithin( way, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857), $3 )
	  ORDER BY dist
		SQL
		$conn.exec_params(sql,[lon,lat,radius]).collect { |res| { id: res['osm_id'].to_i, tags: JSON.parse(res['tags'] || '{}'), dist: res['dist'].to_f, lat: res['lat'].to_f, lon: res['lon'].to_f } }

	end
	
	def collect_crossings(lat,lon,radius)
		sql = <<-SQL
		SELECT ST_Distance( way, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857) ) AS dist, hstore_to_json(tags) AS tags, osm_id,
			   ST_X(ST_Transform(way,4326)) AS lon,
			   ST_Y(ST_Transform(way,4326)) AS lat
		  FROM planet_osm_point
		 WHERE highway='crossing'
		   AND ST_DWithin( way, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857), $3 ) AND osm_id>0
	  ORDER BY dist
		SQL
		$conn.exec_params(sql,[lon,lat,radius]).collect { |res| { id: res['osm_id'].to_i, tags: JSON.parse(res['tags'] || '{}'), dist: res['dist'].to_f, lat: res['lat'].to_f, lon: res['lon'].to_f } }
	end

	# Find the nearest nodes on a given set of ways
	
	def nearest_nodes(lat,lon,way_ids)
		sql = "SELECT n.id AS node_id, lat, lon, w.id AS way_id FROM planet_osm_nodes n JOIN planet_osm_ways w ON n.id=ANY(w.nodes) WHERE w.id IN (#{way_ids.join(',')})"
		nodes = $conn.exec(sql).collect { |res| { id: res['node_id'].to_i, lat: res['lat'].to_f/10000000.0, lon: res['lon'].to_f/10000000.0, way_id: res['way_id'].to_i } }
		# could potentially get tags here too (from planet_osm_point) - though we'd need version to be able to write back to the database (and does it preserve everything like 'source'?)
		nodes.map! { |n| n.merge(dist: FasterHaversine.distance(n[:lat],n[:lon],lat,lon)*1000) }
		nodes.sort_by { |n| n[:dist] }
	end

	# Snap to the nearest point on the given way
	
	def snap(lat,lon,way_id)
		sql = <<-SQL
		SELECT ST_X(ST_ClosestPoint(ST_Transform(way,4326),ST_SetSRID(ST_MakePoint($1,$2),4326))) AS lon,
		       ST_Y(ST_ClosestPoint(ST_Transform(way,4326),ST_SetSRID(ST_MakePoint($1,$2),4326))) AS lat,
			   ST_LineLocatePoint(ST_Transform(way,4326),ST_SetSRID(ST_MakePoint($1,$2),4326)) AS prop
	    FROM planet_osm_line WHERE osm_id=$3
		SQL
		res = $conn.exec_params(sql,[lon,lat,way_id])[0]
		[res['lat'].to_f, res['lon'].to_f, res['prop'].to_f]
	end
	
	# Find subscript for a new node in a given way
	
	def way_subscript(lat,lon,way_id,prop=-1)
		# First, calculate the 0-1 proportion along the way if we don't already have it
		pr = prop
		if pr==-1 then _,_,pr=snap(lat,lon,way_id) end
		if pr==0 || pr==1 then raise "Found proportion of #{pr} in way #{way_id}, at #{lat},#{lon}" end

		# Then find this for each node
		sql = <<-SQL
		SELECT n.id,n.lat,n.lon,
		       ST_LineLocatePoint(ST_Transform(l.way,4326),ST_SetSRID(ST_MakePoint(n.lon/10000000.0,n.lat/10000000.0),4326)) AS prop
		  FROM planet_osm_nodes n 
		  JOIN planet_osm_ways w ON n.id=any(w.nodes) AND w.id=#{way_id}
		  JOIN planet_osm_line l ON l.osm_id=w.id
	  ORDER BY array_position(w.nodes,n.id);
		SQL
		results = $conn.exec(sql).to_a

		# Finally, return the index after which we insert the new node
		# note edge case for self-intersecting ways like 578030062 (because array_position finds the first one)
		results.each_with_index do |res,i|
			return i if i==results.length-1
			return i if pr>=res['prop'].to_f && pr<=results[i+1]['prop'].to_f
		end
		raise "Couldn't find index for node in way"
	end

	# Find junctions between a set of ways
	
	def find_junctions(lat,lon,way_ids)
		return [] if way_ids.empty?
		node_count    = {}
		node_highways = {}
		node_ways     = {}
		sql = "SELECT id,nodes,tags FROM planet_osm_ways WHERE id IN (#{way_ids.join(',')})"
		$conn.exec(sql).each do |res|
			tag_list = parse_pg_array(res['tags'] || '{}')
			highway  = Hash[*tag_list]['highway']
			nids     = parse_pg_array(res['nodes']).map(&:to_i)
			#nids = res['nodes'].delete('{}').split(',').map(&:to_i)
			nids.each_with_index do |nid,i|
				end_point = (i==0 || i==nids.length-1)
				node_count[nid] = (node_count[nid] || 0) + (end_point ? 1 : 2)
				node_highways[nid] = {} unless node_highways[nid]
				node_highways[nid][highway] = true
				node_ways[nid] = {} unless node_ways[nid]
				node_ways[nid][res['id'].to_i] = true
			end
		end
		junction_nids = node_count.keys.select { |nid| node_count[nid]>2 }
		return [] if junction_nids.empty?
		sql = "SELECT id,lat,lon FROM planet_osm_nodes WHERE id IN (#{junction_nids.join(',')})"
		$conn.exec(sql).collect { |res|
			nlat = res['lat'].to_f/10000000.0
			nlon = res['lon'].to_f/10000000.0
			id  = res['id'].to_i
			{ id: id, lat: nlat, lon: nlon,
			  highways: node_highways[id].keys,
			  way_ids: node_ways[id].keys,
			  dist: FasterHaversine.distance(lat,lon,nlat,nlon)*1000
			}
		}.sort_by { |n| n[:dist] }
	end

	# Get existing tags for a node
	
	def node_tags(id)
		sql = "SELECT hstore_to_json(tags) AS tags FROM planet_osm_point WHERE osm_id=$1"
		tags= {}
		$conn.exec_params(sql, [id]).each { |res| tags = JSON.parse(res['tags'] || "{}") }
		tags
	end
	
	# Assess whether a location is an 'island' (two short one-way streets in opposite directions, or similar)

	# Put in a generic 'identify island' routine:
	#	- length should be similar
	#	- length should be short (<60)
	#	- either one cycleway and 1+ oneway, or 2+ oneways
	#	- oneway shouldn't be the same angle (i.e. 2x oneway with same angle don't count)

	def island(ways)
		# for each oneway road way of <60m:
		# - can we find another oneway road way of similar length/direction?
		# - or can we find a cycleway of similar length/direction?
		ways.each do |w|
			next unless ROADS.include?(w[:tags]['highway'])
			next unless w[:tags]['oneway']=='yes'
			next unless w[:length]<60
			puts "i2"
			ways.each do |v|
				next if v==w
				next unless v[:length]<90
				if v[:tags]['highway']=='cycleway' then return true end
				next unless ROADS.include?(v[:tags]['highway'])
				next unless v[:tags]['oneway']=='yes'
				dir = [v[:angle],w[:angle]].max - [v[:angle],w[:angle]].min
				if dir>2.8 && dir<3.5 then return true end
				if dir<0.4 || dir>5.9 then return true end
			end
		end
		# for each cycleway of <90m, can we find another road way (of any length) with oneway in the opposite direction?
		ways.each do |w|
			next unless w[:tags]['highway']=='cycleway'
			next unless w[:length]<90
			ways.each do |v|
				next if v==w
				next unless ROADS.include?(v[:tags]['highway'])
				dir = [v[:angle],w[:angle]].max - [v[:angle],w[:angle]].min
				if dir>2.8 && dir<3.5 then return true end
				if dir<0.4 || dir>5.9 then return true end
			end
		end
		false
	end



	# ==============================================================================================================
	# Tag mangling
	# ==============================================================================================================

	# Do new tags clash?
	
	def tags_clash(new_tags,old_tags)
		ot = _tags_adapt(old_tags)
		new_tags.each do |k,v|
			next if !ot[k]
			next if ot[k]==v
			case "#{ot[k]}->#{v}"
				when "unmarked->uncontrolled";		next
				when "pelican->traffic_signals";	next
			end
			return true
		end
		false
	end
	
	# Are there any extra tags in the new ones?
	
	def tags_additional(new_tags,old_tags)
		ot = _tags_adapt(old_tags)
		nt = new_tags.dup
		nt.delete('tfl_id')
		nt.any? { |k,v| !ot.key?(k) }
	end

	# Adapt old tags for comparison purposes (to avoid needless changes)
	# Do not use this for actually changing real-world tags!
	
	def _tags_adapt(old_tags)
		o = old_tags.dup
		if o['crossing_ref']=='tiger' then o.delete('crossing_ref'); o['segregated']='yes' end
		o
	end

	# Convert tags from CLT

	def clt_osm_tags(pr,existing={})
		tags = existing.dup
		if tags.empty?
			tags['highway'] = 'cycleway'
		else
			tags['bicycle'] = 'yes'
			if ['service','track'].include?(tags['highway'])
				tags['fixme:access'] = "check motor vehicle access"
			end
		end
		# common tags
		tags['oneway'] = pr['CLT_BIDIRE']=='TRUE' ? 'no' : 'yes'
		tags['segregated'] = pr['CLT_SEGREG']=='TRUE' ? 'yes' : 'no'
		if pr['CLT_SHARED']=='TRUE' then tags.merge!("foot"=>"yes", "bicycle"=>"yes") end
		if pr['CLT_PARSEG']=='TRUE' then tags.merge!("foot"=>"yes", "bicycle"=>"yes") end
		if pr['CLT_ACCESS'] then tags["fixme:opening_hours"]=pr['CLT_ACCESS'] end
		# rare tags
		if pr['CLT_STEPP' ]=='TRUE' then puts "#{pr['FEATURE_ID']} stepped track"; tags['cycleway:track']='hybrid' end # only 4
		if pr['CLT_PRIORI']=='TRUE' then puts "#{pr['FEATURE_ID']} priority track"; tags['cycleway:sideroad_continuity']='yes' end # [none]
		if pr['CLT_CONTRA']=='TRUE' then puts "#{pr['FEATURE_ID']} contraflow track"; tags['fixme']='contraflow track' end # only 8
		if pr['CLT_CBYPAS']=='TRUE' then puts "#{pr['FEATURE_ID']} cycle bypass"; tags['fixme']='signal bypass' end # only 12
		if pr['CLT_BBYPAS']=='TRUE' then puts "#{pr['FEATURE_ID']} bus bypass"; tags['note']='bus stop bypass' end # only 8
		tags
	end



	# ==============================================================================================================
	# Utility methods
	# ==============================================================================================================

	# Find the length of a GeoJSON geometry
	
	def geojson_length(geo)
		if geo['type']=='LineString'
			_ls_length(geo['coordinates'])
		else
			geo['coordinates'].inject(0) { |sum,ls| sum+_ls_length(ls) }
		end
	end
	def _ls_length(coords)
		len = 0
		coords.each_with_index do |coord,i|
			next if i==0
			len+=FasterHaversine.distance(coord[1],coord[0],coords[i-1][1],coords[i-1][0])*1000
		end
		len
	end

	# Write output files, converting MultiLineStrings to separate LineString records
	
	def write_output(output, targets)
		# Write to file
		targets.each do |k,v|
			puts "#{k}: #{output[k].count} features"
			data = []
			output[k].each do |feature|
				if feature[:geometry]['type']=='MultiLineString'
					feature[:geometry]['coordinates'].each do |linestring|
						data.push({ properties: feature[:properties], geometry: { 'type'=>'LineString', 'coordinates'=>linestring } }) 
					end
				else
					data.push(feature)
				end
			end
			File.write("#{__dir__}/../output/#{v}", { type: "FeatureCollection", features: data }.to_json)
		end
	end
