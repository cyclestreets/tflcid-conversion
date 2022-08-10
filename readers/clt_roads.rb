
	# Cycle lanes on roads

	require 'json'
	require 'pg'
	require 'colorize'
	require_relative './tfl_common.rb'
	require 'pp'

	data = JSON.parse(File.read("#{__dir__}/../tfl_data/cycle_lane_track.json"))
	$conn = PG::Connection.new(dbname: "osm_london")
	skipped = 0
	TOLERANCE = 10	# tolerance (in spherical Mercator metres) for searching around the TfL data, ie. buffer radius

	osm_ways = {}	# store of all OSM ways we encounter
	osm_geoms = {}	# original OSM way geometries
	osm_tags = {}	# original OSM tags
	output = { full: [], partial: [], contra: [], separate: [], unmatched: [] }	# GeoJSON output

	sql = <<-SQL
CREATE OR REPLACE FUNCTION _Azimuth(geom Geometry(MultiLineString)) RETURNS double precision
AS
$$
BEGIN
RETURN degrees(ST_Azimuth( ST_StartPoint(ST_GeometryN(geom,1)),ST_EndPoint(ST_GeometryN(geom,ST_NumGeometries(geom))) ));
END;
$$
LANGUAGE 'plpgsql';
	SQL
	$conn.exec(sql)

	data['features'].each_with_index do |f,id|
		pr = f['properties']
		next unless pr['CLT_CARR']=='TRUE'

		# --------
		# For each TfL feature, find matching OSM ways

		attrs = pr.reject { |k,v| v=='FALSE' || v.nil? }

		# look for all roads within buffer
		sql = <<-SQL
		SELECT ST_Length(geom) AS tfl, ST_Length(way) AS osm,
			   _Azimuth(ST_Multi(geom)) AS tfl_azimuth,
		       ST_Length(ST_Intersection(way,ST_Buffer(geom,#{TOLERANCE},'endcap=butt'))) AS overlap,
			   _Azimuth(ST_Intersection(way,ST_Buffer(geom,#{TOLERANCE}))) AS overlap_azimuth,
			   ST_AsGeoJSON(ST_Transform(ST_Intersection(way,ST_Buffer(geom,#{TOLERANCE},'endcap=butt')),4326)) AS geo,
			   ST_AsGeoJSON(ST_Transform(way,4326)) AS osm_geom,
			   highway,name,osm_id,hstore_to_json(tags) AS tags
		  FROM cycle_lane_track
		  JOIN planet_osm_line
		    ON ST_DWithin(geom,way,#{TOLERANCE})
		 WHERE cycle_lane_track.id=$1
		   AND highway IN ('trunk','trunk_link','primary','primary_link','secondary','secondary_link',
			   'tertiary','tertiary_link','unclassified','residential','cycleway')
		SQL
		puts "-------------------------------".blue
		puts pr['FEATURE_ID']
		lon,lat = f['geometry']['coordinates'].flatten

		pile = []; tfl_length = 0; ct = 0; cycleway_length = 0
		$conn.exec_params(sql,[id]).each do |res|
			length    = res['overlap'].to_i; next if length==0
			highway   = res['highway']; if highway=='cycleway' then cycleway_length+=length; next end
			tfl_length= res['tfl'].to_i
			tags    = JSON.parse(res['tags'])
			ct += 1
			
			# Store OSM geometry/tags for future use
			osm_id = res['osm_id'].to_i
			osm_geoms[osm_id] = JSON.parse(res['osm_geom'])
			osm_tags[osm_id]  = JSON.parse(res['tags'])

			# Are they going in the same direction? (i.e. not a side-road)
			a1 = res['tfl_azimuth'].to_i
			a2 = res['overlap_azimuth'].to_i
			diff  = a1-a2
			bdiff = a1+360-a2
			next unless (diff>-15 && diff<15) || (diff>165 && diff<195) || (diff>-195 && diff<-165) || (bdiff>-15 && bdiff<15)
			next if length<2
			res['same_way'] = (diff>-15 && diff<15) || (bdiff>-15 && bdiff<15)
			puts "#{length} of TfL #{tfl_length}"

			# Find the start point of the overlap on the OSM way, expressed as a percentage
			# (we could in theory do this as part of the main SQL query above, but this is simpler!)
			start_lon,start_lat = JSON.parse(res['geo'])['coordinates'].flatten
			sql2 = <<-SQL
			SELECT ST_LineLocatePoint(way,ST_Transform(ST_SetSRID(ST_MakePoint($1,$2),4326),3857)) AS pr
			FROM planet_osm_line
			WHERE osm_id=$3
			SQL
			prop = ($conn.exec_params(sql2,[start_lon,start_lat,res['osm_id'].to_i])[0]['pr'].to_f*100).to_i
			res['starts_at'] = prop
			res['tfl_id'] = attrs['FEATURE_ID']

			pile << res
		end

		if cycleway_length>0
			# stepped/partial probably already mapped as a separate cycleway
			if (attrs['CLT_PARSEG'] || attrs['CLT_STEPP']) && cycleway_length>tfl_length*0.8
				pile.each do |res|
					tags = JSON.parse(res['tags'])
					tags.merge!(tfl_id: attrs['FEATURE_ID'], osm_id: res['osm_id'].to_i)
					output[:separate] << { type: "Feature",
						properties: tags, 
						geometry: JSON.parse(res['geo']) }
				end
				next
			end
		end

		if pile.empty? && cycleway_length<tfl_length*0.8
			# no matching geometries found (and not enough cycleway to make up the gap)
			tags = { tfl_id: attrs['FEATURE_ID'] }
			if attrs['CLT_CONTRA']
				tags['cycleway'] = 'opposite_lane'
				tags['oneway'] = 'yes'
				tags['oneway:bicycle'] = 'no'
			else
				cl = (tags['CLT_PARSEG'] || tags['CLT_STEPP']) ? 'track' : 'lane'
				if attrs['CLT_BIDIRE']
					tags['cycleway']=cl
					if cl=='track' then tags['cycleway:track']='hybrid' end
				else
					tags['cycleway:left']=cl
					if cl=='track' then tags['cycleway:left:track']='hybrid' end
				end
			end
			output[:unmatched] << { type: "Feature",
				properties: tags, 
				geometry: data['features'][id]['geometry'] }
			next
		end
		if tfl_length==0 then puts "#{pr['FEATURE_ID']} blank".red; next end

		# don't consider cycleways for matching
		pile.reject! { |res| res['highway']=='cycleway' } 

		# --------
		# Then record each matched OSM way, and what we're missing from it (if anything)

		pile.each do |way|
			tags = JSON.parse(way['tags']).reject { |k,v| (v=='no' || v=='none') && k!='oneway:bicycle' }
			osm_id = way['osm_id'].to_i
			osm_ways[osm_id] ||= []
			pc = (way['overlap'].to_f/way['osm'].to_f*100).to_i

			# Tags
			bus    = pr['CLT_SHARED']=='TRUE'	# cycleway=share_busway
			light  = pr['CLT_PARSEG']=='TRUE'	# cycleway=track, cycleway:track=hybrid
			contra = pr['CLT_CONTRA']=='TRUE'	# cycleway=opposite|opposite_lane, oneway=yes
			stepped= pr['CLT_STEPP' ]=='TRUE'	# cycleway=track, cycleway:track=hybrid

			cw = 'lane'; additional = {}
			if    bus then cw='share_busway'
			elsif light || stepped then cw='track'; additional={':track'=>'hybrid'}
			end
			if pr['CLT_COLOUR']!='NONE' then additional[':surface:colour']=pr['CLT_COLOUR'].downcase end
			if pr['CLT_ADVIS' ]=='TRUE' then additional[':lane']='advisory' end
			if pr['CLT_MANDAT']=='TRUE' then additional[':lane']='exclusive' end
			if pr['CLT_ACCESS']
				v, found = hours_tag(pr['CLT_ACCESS'])
				if found then additional[':conditional']=v else additional['!:conditional']=v end # tidied later
			end

			# Do we have anything in that direction at all?
			one_way = pr['CLT_BIDIRE']=='FALSE'
			forward = tags['cycleway'] || tags['cycleway:left']
			reverse = tags['cycleway'] || tags['cycleway:right']
			rec = { dir: :forward, starts_at: way['starts_at'], covers: pc,
					osm_id: osm_id, tfl_id: way['tfl_id'],
					overlap_geom: JSON.parse(way['geo']),
					tag: cw, additional: additional, contra: false }
			puts "#{osm_id}: https://osm.org/way/#{osm_id}"
			
			# Special handling for contraflows
			if contra
				if tags['oneway'] &&
				   ([tags['cycleway'],tags['cycleway:left'],tags['cycleway:right']].compact.join(',').include?('opposite') ||
				   tags['oneway:bicycle']=='no')
					# already in the data, so don't add
					next
				else
					rec[:contra] = true
				end
			end

			# Add for each direction
			if !one_way || way['same_way']
				if forward
					# forward already set, compare
					if forward!=cw
						puts " - forward: change #{forward} to #{cw}"
						osm_ways[osm_id] << rec
					else
						puts " - forward already tagged"
						unless additional.empty? then osm_ways[osm_id] << rec.merge(tag: nil) end
					end
				else
					# forward not set, add
					puts " - forward: add #{cw}"
					osm_ways[osm_id] << rec
				end
			end
			if !one_way || !way['same_way']
				# reverse
				if reverse
					# reverse already set, compare
					if reverse!=cw
						puts " - reverse: change #{reverse} to #{cw}"
						osm_ways[osm_id] << rec.merge(dir: :reverse)
					else
						puts " - reverse already tagged"
						unless additional.empty? then osm_ways[osm_id] << rec.merge(dir: :reverse, tag: nil) end
					end
				else
					# reverse not set, add
					puts " - reverse: add #{cw}"
					osm_ways[osm_id] << rec.merge(dir: :reverse)
				end
			end
			unless additional.empty?
				p additional
			end
		end
	end

	osm_ways.transform_values!(&:uniq)
	osm_ways.reject! {|k,v| v.empty? }

	# --------
	# Sort into output categories

	osm_ways.each do |id,segments|
		# group by forward/reverse
		forwards = segments.select { |w| w[:dir]==:forward }
		reverses = segments.select { |w| w[:dir]==:reverse }
		# calculate the percentage coverage for each direction (and skip short ones)
		forward_pc = forwards.inject(0) { |sum,w| sum+=w[:covers] }
		reverse_pc = reverses.inject(0) { |sum,w| sum+=w[:covers] }
		next if forward_pc<5 && reverse_pc<5
		contra = segments.any? { |w| w[:contra] }
		
		# ------
		# can we do a simple change for the entire way (with only one type for forward/reverse)?

		if (forward_pc>85 && (reverse_pc>85 || reverse_pc<5)) ||
		   (reverse_pc>85 && (forward_pc>85 || forward_pc<5))
			if forwards.collect { |w| w[:tag] }.compact.uniq.length<2 &&
			   reverses.collect { |w| w[:tag] }.compact.uniq.length<2 && !contra

				tags = osm_tags[id].dup
				tags.merge!(osm_id: id, tfl_id: segments.collect { |seg| seg[:tfl_id] }.uniq.join(','))
				geom = osm_geoms[id]
				# **** check in case cycleway tag exists
				if forward_pc>85 && reverse_pc>85 && forwards[0][:tag]==reverses[0][:tag]
					# apply same tag to each
					tags['cycleway'] = forwards[0][:tag]
					forwards[0][:additional].each { |k,v| apply_additional(tags,"cycleway#{k}",v) }
				else
					if forward_pc>85 # apply tag to forward
						prefix = tags['oneway']=='yes' ? 'cycleway' : 'cycleway:left'
						tags[prefix] = forwards[0][:tag]
						forwards[0][:additional].each { |k,v| apply_additional(tags,"#{prefix}#{k}",v) }
					end
					if reverse_pc>85 # apply tag to reverse
						tags['cycleway:right'] = reverses[0][:tag]
						reverses[0][:additional].each { |k,v| apply_additional(tags,"cycleway:right#{k}",v) }
					end
				end

				output[:full] << { type: "Feature", properties: tags, geometry: geom }
				next
			end
		end

		# ------
		# more complex than a simple change, so we output every bit of overlap
		segments.each do |seg|
			tags = osm_tags[id].dup
			tags.merge!(osm_id: id, tfl_id: seg[:tfl_id])
			if seg[:dir]==:forward
				prefix = tags['oneway']=='yes' ? 'cycleway' : 'cycleway:left'
				tags[prefix] = seg[:tag]
				seg[:additional].each { |k,v| apply_additional(tags,"#{prefix}#{k}",v) }
			else
				tags['cycleway:right'] = seg[:tag]
				seg[:additional].each { |k,v| apply_additional(tags,"cycleway:right#{k}",v) }
			end
			target = seg[:contra] ? :contra : :partial
			output[target] << { type: "Feature", properties: tags, geometry: seg[:overlap_geom] }
		end
	end

	# ------
	# Write to file

	write_output(output,
		full:      "clt_roads_full.geojson",    
		partial:   "clt_roads_partial.geojson", 
		contra:    "clt_roads_contra.geojson",  
		separate:  "clt_roads_separate.geojson",
		unmatched: "clt_roads_unmatched.geojson")
