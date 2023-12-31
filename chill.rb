require 'rspotify'
require 'debug'
require 'csv'

class Chill
  NUM_PAGE = 50
  MAX_PLAYLISTS = 1000
  NUM_RESULTS = 20

  QUERY = 'chill'
  SOFOLOFO_PLAYLIST = '0LEDGhTTunLvL5PnjinBAz'

  PLAYLISTS_CSV = 'playlists.csv'
  COMMON_CSV = 'common_tracks.csv'
  SOFOLOFO_CSV = 'sofolofo.csv'
  THOUSAND_CSV = 'thousand.csv'

  SOFOLOFO_SUMMARY = 'sofolofo_summary.txt'
  THOUSAND_SUMMARY = 'thousand_summary.txt'

  PLAYLISTS_FILE = 'playlists.dump'
  TRACKS_FILE = 'tracks.dump'
  COMMON_FILE = 'common.dump'
  SOFOLOFO_FILE = 'sofolofo.dump'
  THOUSAND_FILE = 'thousand.dump'

  FEATURES_KEYS = %w(acousticness danceability energy instrumentalness speechiness valence)
  ANALYSIS_KEYS = %w(duration loudness tempo time_signature key mode)
  MODE_KEYS = %(time_signature key mode)
  ALL_KEYS = FEATURES_KEYS + ANALYSIS_KEYS

  Track = Struct.new(:id, :name, :album, :artists, :playlist_id, :url)

  TrackWithFeatures = Struct.new(:id, :name, :album, :artists, :playlist_id, :url, :features) do
    def fetch_analysis!
      feats = RSpotify.get("audio-features/#{id}").slice(*FEATURES_KEYS)
      analysis = RSpotify.get("audio-analysis/#{id}")['track'].slice(*ANALYSIS_KEYS)
      self.features = feats.merge(analysis)
    end
  end

  def initialize
    raise 'pls export CLIENT_ID AND CLIENT_SECRET to env' unless ENV['CLIENT_ID'] && ENV['CLIENT_SECRET']
    RSpotify.authenticate(ENV['CLIENT_ID'], ENV['CLIENT_SECRET'])
  end

  def fetch_playlists
    20.times.map do |i|
      puts "Fetching playlists... #{i * NUM_PAGE} / 1000"
      RSpotify::Playlist.search(QUERY, limit: NUM_PAGE, offset: i * NUM_PAGE)
    end.flatten.uniq(&:id)
  end

  def playlists
    dump(PLAYLISTS_FILE, fetch_playlists) unless File.exist?(PLAYLISTS_FILE)
    @playlists ||= load(PLAYLISTS_FILE)
  end

  def fetch_tracks
    playlists.map.with_index do |playlist, i|
      puts "Fetching tracks for #{playlist.id}... #{i} / #{playlists.size}"
      playlist.tracks.map do |track|
        Track.new(
          track.id,
          track.name,
          track.album.name,
          track.artists.map(&:name).join(', '),
          playlist.id,
          track.external_urls['spotify']
        )
      end
    end.flatten
  end

  def tracks
    dump(TRACKS_FILE, fetch_tracks) unless File.exist?(TRACKS_FILE)
    @tracks ||= load(TRACKS_FILE)
  end

  def process_common
    tracks.group_by(&:id).
      select { |_, v| v.size > 1 }.
      sort_by { |_, v| -v.size }.
      take(NUM_RESULTS)
  end

  def common
    dump(COMMON_FILE, process_common) unless File.exist?(COMMON_FILE)
    @common ||= load(COMMON_FILE)
  end

  def export_playlists
    CSV.open(PLAYLISTS_CSV, 'w') do |csv|
      csv << %w(playlist_id name description url)

      playlists.map do |p|
        csv << [p.id, p.name, p.description, p.external_urls['spotify']] unless p.name.empty?
      end
    end
  end

  def export_common
    CSV.open(COMMON_CSV, 'w') do |csv|
      csv << %w(track_id name album artists num_playlists url)

      common.map do |id, ts|
        t = ts.first
        csv << [id, t.name, t.album, t.artists, ts.size, t.url]
      end
    end
  end

  def export
    export_playlists
    export_common
    export_analysis(sofolofo_tracks, SOFOLOFO_CSV, SOFOLOFO_SUMMARY)
    export_analysis(thousand_tracks, THOUSAND_CSV, THOUSAND_SUMMARY)
  end

  def dump(file, data)
    File.open(file, 'wb') { |f| f.write(Marshal.dump(data)) }
  end

  def load(file)
    Marshal.load(File.binread(file))
  end

  def process_sofolofo_tracks
    RSpotify::Playlist.find_by_id(SOFOLOFO_PLAYLIST).tracks.map.with_index do |track, i|
      t = TrackWithFeatures.new(
        track.id,
        track.name,
        track.album.name,
        track.artists.map(&:name).join(', '),
        SOFOLOFO_PLAYLIST,
        track.external_urls['spotify']
      )

      puts "Processing sofolofo track #{i}"
      t.fetch_analysis!
      t
    end
  end

  def sofolofo_tracks
    dump(SOFOLOFO_FILE, process_sofolofo_tracks) unless File.exist?(SOFOLOFO_FILE)
    @sofolofo_tracks ||= load(SOFOLOFO_FILE)
  end

  def process_thousand_tracks
    tracks.group_by(&:id).
      select { |_, v| v.size > 1 }.
      sort_by { |_, v| -v.size }.
      take(1000).map(&:last).map(&:first).map.with_index do |track, i|
        t = TrackWithFeatures.new(
          track.id,
          track.name,
          track.album,
          track.artists,
          track.playlist_id,
          track.url
        )

        begin
          puts "Processing thousand track #{i}"
          t.fetch_analysis!
        rescue
          puts "analysis fetch failed for track #{i}"
        end

        t
      end
  end

  def thousand_tracks
    dump(THOUSAND_FILE, process_thousand_tracks) unless File.exist?(THOUSAND_FILE)
    @thousand_tracks ||= load(THOUSAND_FILE)
  end

  def mean(arr)
    arr.sum / arr.size.to_f
  end

  def mode(arr)
    arr.tally.sort_by { |_, v| v }.last.first
  end

  def export_analysis(tracks, csv_file, summary_file)
    CSV.open(csv_file, 'w') do |csv|
      csv << %w(track_id name album artists url) + ALL_KEYS

      tracks = tracks.reject { |t| t.features.nil? }

      tracks.map do |t|
        row = [t.id, t.name, t.album, t.artists, t.url]
        ALL_KEYS.each { |k| row << t.features[k] }
        csv << row
      end
    end

    File.open(summary_file, 'w') do |f|
      f.puts "Statistics for #{tracks.size} tracks"
      f.puts ""

      ALL_KEYS.each do |k|
        vals = tracks.map { |t| t.features[k] }
        stat = MODE_KEYS.include?(k) ? mode(vals) : mean(vals)
        f.puts "#{k}: #{stat}"
      end
    end
  end
end

c = Chill.new
c.export
