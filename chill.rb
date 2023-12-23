require 'rspotify'
require 'debug'
require 'csv'

class Chill
  NUM_PAGE = 50
  MAX_PLAYLISTS = 1000
  NUM_RESULTS = 20
  QUERY = 'chill'
  PLAYLISTS_FILE = 'playlists.dump'
  PLAYLISTS_CSV = 'playlists.csv'
  TRACKS_FILE = 'tracks.dump'
  COMMON_FILE = 'common.dump'
  COMMON_CSV = 'common_tracks.csv'

  Track = Struct.new(:id, :name, :album, :artists, :playlist_id, :url)

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
  end

  def dump(file, data)
    File.open(file, 'wb') { |f| f.write(Marshal.dump(data)) }
  end

  def load(file)
    Marshal.load(File.binread(file))
  end
end

Chill.new.export
