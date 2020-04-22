
	require 'json'
	require 'pg'
	
	data = JSON.parse(File.read("#{__dir__}/../tfl_data/cycle_parking.json"))
    conn = PG::Connection.new(dbname: "osm_london")

	# Create table
	sql = <<-SQL
	 CREATE TABLE tfl_parking (feature_id VARCHAR(16), svdate VARCHAR(16),
	 carr BOOLEAN, cover BOOLEAN, secure BOOLEAN, locker BOOLEAN, sheff BOOLEAN,
	 mstand BOOLEAN, pstand BOOLEAN, hoop BOOLEAN, post BOOLEAN, buterf BOOLEAN,
	 wheel BOOLEAN, hangar BOOLEAN, tier BOOLEAN, other BOOLEAN, provis INT, cpt INT,
	 borough TEXT, photo1_url TEXT, photo2_url TEXT, geom GEOMETRY(Point,3857))
	SQL
	conn.exec(sql)
	
	# Populate with TfL data
	data['features'].each do |f|
		lon,lat = f['geometry']['coordinates']
		o = f['properties']
		sql = <<-SQL
		INSERT INTO tfl_parking
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,
			ST_Transform(ST_SetSRID(ST_MakePoint($22,$23),4326),3857) )
		SQL
		conn.exec_params(sql, [
			o['FEATURE_ID'],
			o['SVDATE'],
			o['PRK_CARR'  ]=='TRUE',
			o['PRK_COVER' ]=='TRUE',
			o['PRK_SECURE']=='TRUE',
			o['PRK_LOCKER']=='TRUE',
			o['PRK_SHEFF' ]=='TRUE',
			o['PRK_MSTAND']=='TRUE',
			o['PRK_PSTAND']=='TRUE',
			o['PRK_HOOP'  ]=='TRUE',
			o['PRK_POST'  ]=='TRUE',
			o['PRK_BUTERF']=='TRUE',
			o['PRK_WHEEL' ]=='TRUE',
			o['PRK_HANGAR']=='TRUE',
			o['PRK_TIER'  ]=='TRUE',
			o['PRK_OTHER' ]=='TRUE',
			o['PRK_PROVIS'].to_i,
			o['PRK_CPT'].to_i,
			o['BOROUGH'],
			o['PHOTO1_URL'],
			o['PHOTO2_URL'],
			lon, lat])
	end

	# Create OSM table and populate it with all the parking from the planet_osm_ tables
	# Then cluster both TfL and OSM tables
	statements = [
		"CREATE TABLE osm_parking (osm_id BIGINT, is_node BOOLEAN DEFAULT TRUE, geom GEOMETRY(Point,3857), tags HSTORE)",
		"CREATE INDEX osm_parking_geom_index on osm_parking USING GIST(geom)",
		"INSERT INTO osm_parking (osm_id, is_node, geom, tags) SELECT osm_id, TRUE, way, tags FROM planet_osm_point WHERE amenity='bicycle_parking'",
		"INSERT INTO osm_parking (osm_id, is_node, geom, tags) SELECT osm_id, FALSE, ST_Centroid(way), tags FROM planet_osm_polygon WHERE amenity='bicycle_parking'",
		"ALTER TABLE tfl_parking ADD COLUMN cluster_id integer",
		"ALTER TABLE osm_parking ADD COLUMN cluster_id integer",
		<<-SQL ,
		UPDATE tfl_parking
		SET cluster_id = subquery.cluster_id
		FROM (SELECT feature_id, st_clusterdbscan(geom, eps := 50, minPoints := 2) over() as cluster_id 
		   FROM tfl_parking) AS subquery
		WHERE tfl_parking.feature_id = subquery.feature_id;
		SQL
		<<-SQL ,
		UPDATE osm_parking
		SET cluster_id = subquery.cluster_id
		FROM (SELECT osm_id, st_clusterdbscan(geom, eps := 50, minPoints := 2) over() as cluster_id 
		   FROM osm_parking) AS subquery
		WHERE osm_parking.osm_id = subquery.osm_id;
		SQL
		"CREATE INDEX tfl_parking_geom_index ON tfl_parking USING GIST(geom)",
		"CREATE INDEX tfl_cluster_index ON tfl_parking (cluster_id)" ]

	statements.each { |sql| conn.exec(sql) }
	puts "Finished"
