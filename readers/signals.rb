# Signals
# traffic_signals:bicycle_early_release=yes

require 'json'
require 'pg'
require 'colorize'
require_relative './tfl_common.rb'

data = JSON.parse(File.read("#{__dir__}/../tfl_data/signal.json"))
$conn = PG::Connection.new(dbname: "osm_london")
output = { signals: [], no_signals: [] }
skipped = 0

data['features'].each do |f|
	attrs = f['properties'].reject { |k,v| v=='FALSE' }
	next unless attrs['SIG_EARLY']
	print "TfL id #{attrs['FEATURE_ID']} "

	# Are there any traffic signals nearby?
	lon,lat = f['geometry']['coordinates']
	nearby = collect_signals(lat,lon,20)
	if nearby.empty?
		puts "- no signals found nearby".red
		output[:no_signals] << { type: "Feature",
			properties: { 'highway'=>'traffic_signals', 'traffic_signals:bicycle_early_release'=>'yes', 'tfl_id'=>attrs['FEATURE_ID'] },
			geometry: { type: "Point", coordinates: [lon,lat] } }
	else
		n = nearby[0]
		if n[:tags]['traffic_signals:bicycle_early_release'] then puts "- already mapped".green; skipped+=1; next end
		puts "- adding to existing signals".blue
		output[:signals] << { type: "Feature",
			properties: n[:tags].merge({ 'traffic_signals:bicycle_early_release'=>'yes', 'tfl_id'=>attrs['FEATURE_ID'] }).merge(osm_id: n[:id]),
			geometry: { type: "Point", coordinates: [n[:lon],n[:lat]] } }
	end
end

puts "Totals: #{output[:signals].count} on existing signal nodes, #{output[:no_signals].count} no existing node found"
puts "#{skipped} skipped (already tagged)"
write_output(output,
	signals: "signals_existing.geojson",
	no_signals: "signals_new.geojson"
)
