
	# Read all CLT data into Postgres

	# CLT_CARR - on-carriageway [cycleway:left/right=lane] vs off- [cycleway=track]
	# CLT_SEGREG - fully segregated [segregated=yes/no]
	# CLT_STEPP - stepped lane/track [cycleway=track, cycleway:track=hybrid]
	# CLT_PARSEG - partial/light segregation [depends whether on/off carriageway]
	# CLT_SHARED - shared lane (bus lane) or footway
	# CLT_MANDAT - mandatory cycle lane?
	# CLT_ADVIS - advisory cycle lane?
	# CLT_PRIORI - cycles have priority?
	# CLT_CONTRA - contraflow?
	# CLT_BIDIRE - two-way flow?
	# CLT_CBYPAS - bypass allowing turn without stop?
	# CLT_BBYPAS - bus bypass?
	# CLT_PARKR - park route?
	# CLT_WATERR - waterside route?
	# CLT_PTIME - part-time?
	# CLT_ACCESS - access times
	# CLT_COLOUR - colour of lane/track

	data = JSON.parse(File.read("#{__dir__}/../tfl_data/cycle_lane_track.json"))
	$conn = PG::Connection.new(dbname: "osm_london")

	$conn.exec "DROP TABLE IF EXISTS cycle_lane_track"
	$conn.exec <<-SQL
	CREATE TABLE cycle_lane_track (
		id INT,
		feature_id VARCHAR(20),
		carr   BOOLEAN DEFAULT FALSE,
		segreg BOOLEAN DEFAULT FALSE,
		stepp  BOOLEAN DEFAULT FALSE,
		parseg BOOLEAN DEFAULT FALSE,
		shared BOOLEAN DEFAULT FALSE,
		mandat BOOLEAN DEFAULT FALSE,
		advis  BOOLEAN DEFAULT FALSE,
		priori BOOLEAN DEFAULT FALSE,
		contra BOOLEAN DEFAULT FALSE,
		bidire BOOLEAN DEFAULT FALSE,
		cbypas BOOLEAN DEFAULT FALSE,
		bbypas BOOLEAN DEFAULT FALSE,
		parkr  BOOLEAN DEFAULT FALSE,
		waterr BOOLEAN DEFAULT FALSE,
		ptime  BOOLEAN DEFAULT FALSE,
		access TEXT,
		geom GEOMETRY(MultiLineString, 3857))
	SQL
	# could do photos too

	puts "Reading data"
	data['features'].each_with_index do |f,id|
		pr = f['properties']
		sql = <<-SQL
		INSERT INTO cycle_lane_track
		VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,
			ST_Multi(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON($19),4326),3857)))
		SQL
		$conn.exec_params(sql,[ id, pr['FEATURE_ID'],
			pr['CLT_CARR'  ]=='TRUE',
			pr['CLT_SEGREG']=='TRUE',
			pr['CLT_STEPP' ]=='TRUE',
			pr['CLT_PARSEG']=='TRUE',
			pr['CLT_SHARED']=='TRUE',
			pr['CLT_MANDAT']=='TRUE',
			pr['CLT_ADVIS' ]=='TRUE',
			pr['CLT_PRIORI']=='TRUE',
			pr['CLT_CONTRA']=='TRUE',
			pr['CLT_BIDIRE']=='TRUE',
			pr['CLT_CBYPAS']=='TRUE',
			pr['CLT_BBYPAS']=='TRUE',
			pr['CLT_PARKR' ]=='TRUE',
			pr['CLT_WATERR']=='TRUE',
			pr['CLT_PTIME' ]=='TRUE',
			pr['CLT_ACCESS'], f['geometry'].to_json ])
	end
	$conn.exec "CREATE INDEX clt_geom_idx ON cycle_lane_track USING GIST(geom)"
