
	# Cycle parking matching

	# Run with --existing to additionally output matches to existing data

	require 'json'
	require 'pg'
	require 'faster_haversine'
	require_relative './tfl_common.rb'
	
    $conn = PG::Connection.new(dbname: "osm_london")
	$output = { isolated: [], nearby: [], osm_unique: [], linked: [] }
	
	$tfl_debug = nil
	$osm_debug = nil
	
	clustered = []; cluster_id = nil
	osm_used = {}

	output_existing = (!ARGV.empty? && ARGV[0]=='--existing')

	$conn.exec("SELECT *,ST_X(ST_Transform(geom,4326)) AS lon,ST_Y(ST_Transform(geom,4326)) AS lat FROM tfl_parking ORDER BY cluster_id").each do |res|
		attrs = res.to_h.dup
		res.to_h.each { |k,v| if v=='t' then attrs[k]=true end }
		res.to_h.each { |k,v| if v=='f' then attrs[k]=false end }

		if attrs['cluster_id']==nil
			if !clustered.empty?
				rewrite(clustered, osm_used)
				clustered=[]
			end
			rewrite([attrs], osm_used)
		elsif attrs['cluster_id']==cluster_id
			clustered << attrs
			cluster_id = attrs['cluster_id']
		else
			if !clustered.empty?
				rewrite(clustered, osm_used)
			end
			clustered = [attrs]
			cluster_id = attrs['cluster_id']
		end
	end
	
	$conn.exec("SELECT osm_id,hstore_to_json(tags),ST_X(ST_Transform(geom,4326)) AS lon,ST_Y(ST_Transform(geom,4326)) AS lat FROM osm_parking").each do |res|
		next if osm_used[res['osm_id']]
		$output[:osm_unique] << {
			type: "Feature", properties: JSON.parse(res['tags'] || "{}"),
			geometry: { type: "Point", coordinates: [res['lon'].to_f,res['lat'].to_f] }
		}
	end

	puts "Matched #{osm_used.size} OSM"
	puts "(nearby: #{$output[:nearby].count}, isolated: #{$output[:isolated].count})"
	write_output($output, nearby: "parking_new_nearby.geojson", isolated: "parking_new_isolated.geojson" )
	if output_existing
		write_output($output,
			linked: "parking_remapped.geojson",
			osm_unique: "parking_osm_unique.geojson")
	end

	# To get OSM only:
	# - read everything from db
	# - don't include those that are in osm_used
	
	# Debug GeoJSON output:
	# - for remapped, have lines from TfL to OSM
	# - for TfL new, have points
	# - for OSM only, have points

BEGIN {

	# Rewrite all tags
	
	def rewrite(cluster, osm_used)
		matches = resolve(cluster,osm_used)
		matches.each do |tfl_id, osm|
			tfl = cluster.find { |c| c['feature_id']==tfl_id }
			tfl['osm'] = osm
		end
		cluster.each do |tfl|
			tags = {}
			if tfl['carr']   then tags['on_carriageway']='yes' end
			if tfl['cover']  then tags['covered']='yes' end
			if tfl['secure'] then tags['bicycle_parking']='lockers'; tags['note']='Shared lock' end
			if tfl['locker'] then tags['bicycle_parking']='lockers'; tags['note']='Own lock' end
			if tfl['sheff']  then tags['bicycle_parking']='stands' end
			if tfl['mstand'] then tags['bicycle_parking']='stands' end
			if tfl['pstand'] then tags['bicycle_parking']='stands' end
			if tfl['hoop']   then tags['bicycle_parking']='hoop' end
			if tfl['post']   then tags['bicycle_parking']='bollard' end
			if tfl['buterf'] then tags['bicycle_parking']='wall_loops' end
			if tfl['wheel']  then tags['bicycle_parking']='upright_stands' end
			if tfl['hangar'] then tags['bicycle_parking']='lockers' end
			if tfl['tier']   then tags['bicycle_parking']='two_tier' end
			if tfl['other']  then tags['fixme']='Check bike parking type' end
			if tfl['cpt']    then tags['capacity']=tfl['cpt'] end
			tags['tfl_id'] = tfl['feature_id']

			if tfl['osm']
				osm = tfl['osm']
				tags['osm_id'] = osm['osm_id']
				$output[:linked] << { 
					type: "Feature", properties: tags, 
					geometry: {
						type: "LineString",
						coordinates: [ [tfl['lon'].to_f,tfl['lat'].to_f], 
									   [osm['lon'].to_f,osm['lat'].to_f] ]
				   }
			   }
			else
				tags['amenity'] = 'bicycle_parking'
				target = matches.empty? ? :isolated : :nearby
				$output[target] << {
					type: "Feature", properties: tags,
					geometry: {
						type: "Point",
						coordinates: [tfl['lon'].to_f,tfl['lat'].to_f]
					}
				}
			end
		end
	end

	# Match a TFL cluster against OSM data
	# Returns a hash of { TfL ID => OSM candidate }

	def resolve(cluster, osm_used)
		cid = cluster[0]['cluster_id']

		# No cluster, so anything near this point
		if cid.nil?
			lon = cluster[0]['lon'].to_f
			lat = cluster[0]['lat'].to_f

			sql = <<-SQL
			SELECT 
				ST_X(ST_Transform(geom,4326)) AS lon,
				ST_Y(ST_Transform(geom,4326)) AS lat,
				ST_Distance( geom, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857) ) AS dist,
				tags, osm_id, is_node, cluster_id
			FROM osm_parking
			WHERE ST_DWithin( geom, ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857), 50 )
			ORDER BY dist
			SQL
			candidates = $conn.exec(sql, [lon,lat]).to_a

		# Cluster, so anything near any point
		else
			sql = <<-SQL
			SELECT 
				ST_X(ST_Transform(osm.geom,4326)) AS lon,
				ST_Y(ST_Transform(osm.geom,4326)) AS lat,
				ST_Distance( osm.geom, tfl.geom ) AS dist,
				osm.tags, osm.osm_id, osm.is_node, osm.cluster_id
			FROM osm_parking osm
			JOIN tfl_parking tfl ON ST_DWithin( osm.geom, tfl.geom, 50 )
			WHERE tfl.cluster_id = $1
			ORDER BY dist
			SQL
			candidates = $conn.exec_params(sql, [cid]).to_a
		end
#		puts "Cluster #{cid} [#{cluster.length}] at #{lat},#{lon}"

		# Find all OSM parking within the radius

		# Get everything from the clusters even if they're outside the radius
		osm_clusters = candidates.collect { |c| c['cluster_id'] }.compact.uniq.map(&:to_i)
		unless osm_clusters.empty?
			sql = <<-SQL
			SELECT 
				ST_X(ST_Transform(geom,4326)) AS lon,
				ST_Y(ST_Transform(geom,4326)) AS lat,
				tags, osm_id, is_node, cluster_id
			FROM osm_parking
			WHERE cluster_id IN (#{osm_clusters.join(',')})
			SQL
			$conn.exec(sql).each { |c| candidates << c.to_h }
		end
		candidates.uniq!
		candidates.reject! { |c| osm_used[c['osm_id']]==true }
		if candidates.empty? then return {} end
		
		# Calculate distance matrix
		dists = {}
		cluster.each do |tfl|
			tfl_id = tfl['feature_id']
			candidates.each do |osm|
				if tfl_id==$tfl_debug then puts "Considering #{osm}" end
				dist = FasterHaversine.distance(tfl['lat'].to_f, tfl['lon'].to_f, osm['lat'].to_f, osm['lon'].to_f)*1000
				next if dist>4 && crosses_road(tfl['lat'].to_f,tfl['lon'].to_f,osm['lat'].to_f,osm['lon'].to_f)
				next if dist>35
				osm_id = osm['osm_id']
				if tfl_id==$tfl_debug then puts "(adding #{osm_id})" end
				dists[osm_id] ||= {}
				dists[osm_id][tfl_id] = dist
			end
		end

		# Is there only one in the cluster? If so, just choose the nearest OSM
		# (unless it crosses a road)
		if cluster.size==1
			tfl_id = cluster[0]['feature_id']
			if tfl_id==$tfl_debug then puts "Only one in the cluster" end
			n = dists.min_by { |osm_id,h| h[tfl_id] }
			if n.nil? then return {} end
			osm_id = n[0]
			osm = candidates.find { |c| c['osm_id']==osm_id }
			dist = FasterHaversine.distance(cluster[0]['lat'].to_f,cluster[0]['lon'].to_f,osm['lat'].to_f,osm['lon'].to_f)*1000
			if dist>4 && crosses_road(cluster[0]['lat'].to_f,cluster[0]['lon'].to_f,osm['lat'].to_f,osm['lon'].to_f) then return {} end
#			puts "- only one, #{tfl_id} -> #{osm_id}"
			osm_used[osm_id] = true
			if tfl_id==$tfl_debug then puts "Single assigning #{n} to #{c}" end
			return { tfl_id => osm }
		end

		if cluster.any? {|cl| cl['feature_id']==$tfl_debug } then puts "Distances"; p dists; puts "Cluster"; p cluster; puts "Candidates"; p candidates end

		# For each OSM parking, find the nearest TfL parking
		# - do this in order of "biggest discrepancy between 1st and 2nd"
		# - then remove that TfL parking from consideration
		# - and also remove that OSM parking from future use
		results = {}
		if candidates.any? { |c| c['osm_id']==$osm_debug } then puts "In candidates"; p candidates; p dists end
		candidates.reject! { |c| !dists.key?(c['osm_id']) }
		if candidates.any? { |c| c['osm_id']==$osm_debug } then puts "Still in candidates" end
		if cluster.any? {|cl| cl['feature_id']==$tfl_debug } then puts "After reject"; p candidates end
		candidates.sort_by { |c| priority(dists[c['osm_id']]) }.each do |c| 
			# (was 2000-discrepancy(dists[c['osm_id']]) )
			osm_id = c['osm_id']
			next if osm_used[osm_id]
			next if dists[osm_id].empty?
			n,dist = nearest(dists[osm_id])
			# n is TFL ID, c is OSM candidate, dist is distance
			next if dist>35
			if n==$tfl_debug then puts "Assigning #{n} to #{c}" end
			results[n] = c
			results[n][:target_dist] = dist
			dists.each { |osm_id,list| list.delete(n) }
			osm_used[osm_id] = true
		end
		
		# **** maybe insert a "sort by lat or lon" step here?
		#      then we could try r2 being a bit to the side of r1, rather than just random
		
		# Try randomly swapping pairs 
		unless results.size<2
			total_dist = results.inject(0) { |sum,r| sum+r[1][:target_dist] }
			tfl_by_id = {}
			results.keys.each { |tfl_id| tfl_by_id[tfl_id]=cluster.find {|cl| cl['feature_id']==tfl_id } }
			tank = results.size*5
			while tank>0
				r1 = rand(results.length)
				r2 = rand(results.length)
				next if r1==r2
				tfl_id1 = results.keys[r1]; tfl1 = tfl_by_id[tfl_id1]
				tfl_id2 = results.keys[r2]; tfl2 = tfl_by_id[tfl_id2]
				new_dist1 = FasterHaversine.distance(tfl1['lat'].to_f,tfl1['lon'].to_f,results[tfl_id2]['lat'].to_f,results[tfl_id2]['lon'].to_f)*1000
				new_dist2 = FasterHaversine.distance(tfl2['lat'].to_f,tfl2['lon'].to_f,results[tfl_id1]['lat'].to_f,results[tfl_id1]['lon'].to_f)*1000
				new_total = total_dist - results[tfl_id1][:target_dist] - results[tfl_id2][:target_dist] + new_dist1 + new_dist2
				if (total_dist-new_total)>0.1 then
					puts "Swap #{tfl_id1} and #{tfl_id2} (save #{total_dist-new_total}) (tank #{tank} in #{results.size*5})"
					tank = results.size*5
#					puts " #{tfl_id1}->#{results[tfl_id1]['osm_id']}, #{results[tfl_id1][:target_dist]} vs #{new_dist1}"
#					puts " #{tfl_id2}->#{results[tfl_id2]['osm_id']}, #{results[tfl_id2][:target_dist]} vs #{new_dist2}"
					tmp = results[tfl_id1].dup
					results[tfl_id1] = results[tfl_id2].dup
					results[tfl_id2] = tmp
					results[tfl_id1][:target_dist] = new_dist1
					results[tfl_id2][:target_dist] = new_dist2
				end
				tank -= 1
			end
		end
		
		if results.key?($tfl_debug) then p results end
		results
	end

	def crosses_road(lat1,lon1,lat2,lon2)
		# Check to see if it crosses road
		sql = <<-SQL
		SELECT COUNT(*) AS ct
		FROM planet_osm_line
		WHERE highway IN ('trunk','trunk_link','primary','primary_link','secondary','secondary_link','tertiary','tertiary_link','unclassified','residential','pedestrian','living_street')
		AND ST_Intersects(way,ST_Transform(ST_SetSRID(ST_MakeLine(ST_MakePoint($1,$2),ST_MakePoint($3,$4)),4326),3857))
		SQL
		res = $conn.exec_params(sql,[lon1,lat1,lon2,lat2])
		ct  = res[0]['ct'].to_i
		if ct==0 then return false end
		if ct>1  then return true end
		
		# If either end is very close to the road, then that's a miss
		sql = <<-SQL
		SELECT COUNT(*) AS ct
		FROM planet_osm_line
		WHERE highway IN ('trunk','trunk_link','primary','primary_link','secondary','secondary_link','tertiary','tertiary_link','unclassified','residential','pedestrian','living_street')
		AND ( ST_DWithin(way,ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857),2) OR
			  ST_DWithin(way,ST_Transform(ST_SetSRID(ST_MakePoint($3,$4),4326),3857),2) )
		SQL
		res = $conn.exec_params(sql,[lon1,lat1,lon2,lat2])
		ct  = res[0]['ct'].to_i
		if ct==1 then return false end
		true
	end

	# Priority order for which OSM parking to consider first (smaller is better)
	# this is usually just distance, but we apply an extra weighting if the second-placed
	#   alternative is significantly worse (i.e. more than 10m away)
	def priority(h)
		dist = nearest(h)[1]
		if h.size>1
			v = h.values.sort
			if v[1]-v[0] > 10 then dist*=0.5 end
		end
		dist
	end

	def discrepancy(h)
		v = h.values.sort
		if v.length==1 then return -v[0] end
		v[1]-v[0]
	end

	def smallest_dist(h)
		h.min_by { |k,v| v }[1]
	end
	
	def nearest(h)
		# returns id, dist
		h.min_by { |k,v| v }
	end
}
