#!/usr/bin/ruby
# coding: utf-8

require 'getoptlong'
require 'set'
require 'digest'

def help_exit
  script_name = File.basename($0)
  print <<EOMSG
Usage: #{script_name} [ options ]

Recognised options:

--help (-h)
    This message

--full-scan-time <value> (-s)
    Number of hours over which to scan the filesystem (>= 1)
    defaults to 7 x 24 = 1 week

--target-extent-size <value> (-t)
    value passed to btrfs filesystem defrag « -t » parameter (32M)

--verbose (-v)
    prints defragmention as it happens

--debug (-d)
    prints internal processes information

--speed-multiplier <value> (-m)
    slows (<1.0) or speeds (>1.0) the defragmentation process (1.0)

--slow-start <value> (-l)
    wait for <value> seconds before scanning (600)

--drive-count <value> (-c)
    number of 7200rpm drives behind the filesystem (1)
EOMSG
  exit
end

opts = GetoptLong.new([ '--help', '-h', '-?', GetoptLong::NO_ARGUMENT ],
                      [ '--verbose', '-v', GetoptLong::NO_ARGUMENT ],
                      [ '--debug', '-d', GetoptLong::NO_ARGUMENT ],
                      [ '--full-scan-time', '-s',
                        GetoptLong::REQUIRED_ARGUMENT ],
                      [ '--target-extent-size', '-t',
                        GetoptLong::REQUIRED_ARGUMENT ],
                      [ '--speed-multiplier', '-m',
                        GetoptLong::REQUIRED_ARGUMENT ],
                      [ '--slow-start', '-l',
                        GetoptLong::REQUIRED_ARGUMENT ],
                      [ '--drive-count', '-c',
                        GetoptLong::REQUIRED_ARGUMENT ])

# Latest recommendation from BTRFS developpers as of 2016
$default_extent_size = '32M'
$verbose = false
$debug = false
$speed_multiplier = 1.0
$drive_count = 1
slow_start = 600
scan_time = nil
opts.each do |opt,arg|
  case opt
  when '--help'
    help_exit
  when '--verbose'
    $verbose = true
  when '--debug'
    $debug = true
  when '--full-scan-time'
    scan_time = arg.to_i
    help_exit if scan_time < 1
  when '--target-extent-size'
    $default_extent_size = arg
  when '--speed-multiplier'
    $speed_multiplier = arg.to_f
    $speed_multiplier = 1.0 if $speed_multiplier <= 0
  when '--slow-start'
    slow_start = arg.to_i
    slow_start = 600 if slow_start <= 0
  when '--drive-count'
    $drive_count = arg.to_f
    $drive_count = 1 if $drive_count < 1
  end
end


# This defragments Btrfs filesystem files
# the whole FS is scanned over SLOW_SCAN_PERIOD
# meanwhile fatrace is used to monitor written files
# if these are heavily fragmented, defragmentation is triggered early

# Used to remeber how low the cost is brought down
# higher values means more stable behaviour in the effort made
# to defragment
COST_HISTORY_SIZE = 2000
# Tune this to change the effort made to defragment (1.0: max effort)
MIN_EXPECTED_BENEFIT = 1.05
# Dangerous, can try to defragment many files that can't be
# defragmented if set too low
COST_THRESHOLD_PERCENTILE = 50
COST_COMPUTE_DELAY = 60
HISTORY_SERIALIZE_DELAY = 3600
RECENT_SERIALIZE_DELAY = 120

# How many files do we queue for defragmentation
MAX_QUEUE_LENGTH = 2000
# How much do we slow defragmentation frequency when the queue is empty
SPEED_FACTOR_WITH_EMPTY_QUEUE = 0.2
# How much device time the program is allowed to use
# (values when queue == MAX_QUEUE_LENGTH)
# time window => max_device_use_ratio
DEVICE_USE_LIMITS = {
  5 => 0.5 * $speed_multiplier,
  60 => 0.25 * $speed_multiplier,
}
EXPECTED_COMPRESS_RATIO = 0.5

# How many files do we track for writes, we pass these to the defragmentation
# queue when activity stops (this amount limits memory usage)
MAX_TRACKED_WRITTEN_FILES = 10_000
# Period over which to distribute defragmentation checks for files which
# were written at the same time, this avoids filefrag storms
DEFRAG_CHECK_DISTRIBUTION_PERIOD = 120
# How often do we check fragmentation of files written to
TRACKED_WRITTEN_FILES_CONSOLIDATION_PERIOD = 5
# Default Btrfs commit delay when none is specified
# it's otherwise parsed from /proc/mounts
DEFAULT_COMMIT_DELAY = 30
# Some files might be written constantly, don't delay passing them to filefrag
# more than that
MAX_WRITES_DELAY = 2 * 3600

# Full refresh of fragmentation information on files happens in
# (pass number of hours on commandline if the default is not wanted)
SLOW_SCAN_PERIOD = (scan_time || 7 * 24) * 3600 # 1 week
SLOW_SCAN_CATCHUP_WAIT = slow_start
# Sleep constraints between 2 filefrags call in full refresh thread
MIN_DELAY_BETWEEN_FILEFRAGS = 5 / $speed_multiplier
MAX_DELAY_BETWEEN_FILEFRAGS = 180
# Batch size constraints for full refresh thread
MAX_FILES_BATCH_SIZE = (250 * $speed_multiplier).to_i
MIN_FILES_BATCH_SIZE = 50

# We ignore files recently defragmented for 12 hours
IGNORE_AFTER_DEFRAG_DELAY = 12 * 3600

MIN_DELAY_BETWEEN_DEFRAGS = 0.1
MAX_DELAY_BETWEEN_DEFRAGS = 10

# How often do we dump a status update
STATUS_PERIOD = 120 # every 2 minutes
SLOW_STATUS_PERIOD = 900
# How often do we check for new filesystems or umounted filesystems
FS_DETECT_PERIOD = 60
# How often do we restart the fatrace thread ?
# there were bugs where fatrace would stop report modifications under
# some conditions (mounts or remounts, fatrace processes per mountpoint and
# old fatrace version), it might not apply anymore but this doesn't put any
# measurable strain on the system
FATRACE_TTL = 24 * 3600 # every day
# How often do we check the subvolumes list ?
# it can be costly but undetected subvolumes aren't traversed
SUBVOL_TTL = 3600

# System dependent (reserve 100 for cmd and 4096 for one path entry)
FILEFRAG_ARG_MAX = 131072 - 100 - 4096

# Where do we serialize our data
STORE_DIR        = "/root/.btrfs_defrag"
FILE_COUNT_STORE = "#{STORE_DIR}/filecounts.yml"
HISTORY_STORE    = "#{STORE_DIR}/costs.yml"
RECENT_STORE     = "#{STORE_DIR}/recent.yml"

$output_mutex = Mutex.new

# Synchronize mulithreaded outputs
module Outputs
  def short_tstamp
    Time.now.strftime("%Y%m%d %H%M%S")
  end
  def error(msg)
    $output_mutex.synchronize {
      STDERR.puts "#{short_tstamp}: ERROR, #{msg}"
    }
  end
  def info(msg)
    $output_mutex.synchronize {
      STDOUT.puts "#{short_tstamp}: #{msg}"
    }
  end
  def print(msg)
    $output_mutex.synchronize {
      STDOUT.print "#{short_tstamp}: #{msg}"
    }
  end
end

require 'find'
require 'pathname'
require 'yaml'
require 'fileutils'

Thread.abort_on_exception = true

# Shared code for classes needing a storage
# note: write isn't safe, so we protect reads with rescue
module HashEntrySerializer
  def serialize_entry(key, value, file)
    FileUtils.mkdir_p(File.dirname(file))
    File.open(file, File::RDWR|File::CREAT, 0644) { |f|
      f.flock(File::LOCK_EX)
      yaml = f.read
      hash = yaml.empty? ? {} : YAML.load(yaml) rescue {}
      hash[key] = value
      f.rewind
      f.write(YAML.dump(hash))
      f.flush
      f.truncate(f.pos)
    }
  end

  def unserialize_entry(key, file, op_id, default_value = nil)
    if File.file?(file)
      File.open(file, File::RDONLY) { |f|
        f.flock(File::LOCK_EX)
        yaml = f.read
        hash = yaml.empty? ? {} : YAML.load(yaml) rescue {}
        info("## #{key}, #{op_id}: %sloaded" %
             (hash[key] ? "" : "default "))
        hash[key] || default_value
      }
    else
      info "## #{key}, #{op_id}: default loaded"
      default_value
    end
  end
end

# Limit disk available bandwidth usage
class UsagePolicyChecker
  def initialize
    @device_uses = []
  end

  def add_usage(start, duration)
    @device_uses << [ start, duration ]
  end

  # If expected_time is passed, this tries to remain below the thresholds
  # until there isn't any tracked device_use left
  def available?(queue_fill_proportion, expected_time = 0)
    # We slow down defragmentation when there isn't much work
    # and speed it up when there is more work
    use_factor =
      SPEED_FACTOR_WITH_EMPTY_QUEUE + queue_fill_proportion *
      (1 - SPEED_FACTOR_WITH_EMPTY_QUEUE)
    largest_window = DEVICE_USE_LIMITS.keys.max
    this_start = Time.now
    # Cleanup the device uses
    while (first = @device_uses.first) &&
        (first[0] + first[1]) < (this_start - largest_window)
      @device_uses.shift
    end
    # Count usage in each time window
    usage_sums = Hash[ DEVICE_USE_LIMITS.keys.map { |window|
                         [ window, 0 ]
                       } ]
    # This is non-optimal but it should involve a very small amount of data
    @device_uses.each { |start,duration|
      stop = start + duration
      DEVICE_USE_LIMITS.each { |window, percent|
        window_start = this_start + expected_time - window
        # Count only overlapping time windows
        if stop > window_start
          if start > window_start
            usage_sums[window] += duration
          else
            usage_sums[window] = stop - window_start
          end
        end
        if ((usage_sums[window] + expected_time) / use_factor) >
            (window * DEVICE_USE_LIMITS[window])
          return false
        end
      }
    }
    return true
  end

end

# Model for impact on fragmentation performance
# this emulates a typical 7200tpm SATA/SAS disk
# TODO: autodetect or allow configuring other latencies
module FragmentationCost
  # Disk modelization for computing fragmentation cost
  # A track should be ~1.25MB with current hardware according to
  # surface density and estimated platter surface
  DEVICE_CAPACITY = 2 * 1000 ** 4
  TRACK_SIZE = 1.25 * 1024 ** 2
  # Total number for the device (not per plater)
  TRACK_COUNT = DEVICE_CAPACITY / TRACK_SIZE
  TRACK_READ_DELAY = 1.0 / 120 # 7200t/mn
  TRANSFER_RATE = TRACK_SIZE / TRACK_READ_DELAY
  # Typical seek times for 7200t/mn drives
  MIN_SEEK = 0.002 # Track to track
  MAX_SEEK = 0.016 # Whole disk seek (based on 0.009 average)
  # Average time wasted looking for another track
  SEEK_DELAY = (MIN_SEEK + MAX_SEEK) / 2
  # BTRFS parameters
  BTRFS_COMPRESSION_EXTENT_BLOCK_COUNT = 32
  DRIVE_COUNT = $drive_count

  def fragmentation_cost(size, seek_time)
    if (size == 0) || (seek_time == 0)
      1
    else
      # How much time needed to read data
      # initial seek, sequential read time, seek cost
      total = seek_delay + (size.to_f / transfer_rate) + seek_time
      ideal = seek_delay + (size.to_f / transfer_rate)
      total / ideal
    end
  end

  # Passed offsets are in 4096 blocks
  # We compute the time wasted either flying over unused data or
  # seeking looking for data on another track
  def seek_time(from, to)
    distance = (from - to).abs * 4096.to_f
    # Due to compression filefrag can return overlapping extents for
    # consecutive ones
    if (to < from) &&
        ((from - to) < BTRFS_COMPRESSION_EXTENT_BLOCK_COUNT)
      distance = 0
    end
    if distance < TRACK_SIZE
      # Assume we waste time flying over data from another extent in the
      # same track
      TRACK_READ_DELAY * (distance / TRACK_SIZE)
    else
      # Assume the drive has to seek with a cost proportional to the distance
      MIN_SEEK + (MAX_SEEK - MIN_SEEK) * distance /
                 (TRACK_COUNT * TRACK_SIZE * DRIVE_COUNT)
    end
  end

  def transfer_rate
    TRANSFER_RATE * DRIVE_COUNT
  end
  def seek_delay
    SEEK_DELAY
  end

end

class FilefragParser
  include Outputs
  include FragmentationCost

  def initialize
    reinit
  end

  # This handles the actual parsing
  def add_line(line)
    @buffer << line
    case line
    when /^Filesystem type is:/,
         /^ ext:     logical_offset:        physical_offset: length:   expected: flags:/
      # Headers, ignored
    when /^File size of (.+) is (\d+) /
      @filesize = Regexp.last_match(2).to_i
      @filename = Regexp.last_match(1)
    when /^(.+): \d+ extents? found$/
      if @filename != Regexp.last_match(1)
        error("Couldn't understand this part:\n" +
              @buffer.join("\n") +
              "\n** #{@filename} ** !=\n** #{Regexp.last_match(1)} **")
      else
        @eof = true
      end
    when /^\s*\d+:\s*\d+\.\.\s*\d+:\s*(\d+)\.\.\s*(\d+):\s*(\d+):\s*(\d+):\s?(\S*)$/
      # Example of such a line:
      #    1:      960..    1023:  193214976.. 193215039:     64:  193217920: last,eof
      @total_seek_time +=
        seek_time(Regexp.last_match(4).to_i, Regexp.last_match(1).to_i)
      @last_offset = Regexp.last_match(2).to_i
      flags = Regexp.last_match(5)
      length = Regexp.last_match(3).to_i
      if flags.split(",").include?("encoded")
        @compressed_blocks += length
      else
        @uncompressed_blocks += length
      end
    when /^\s*\d+:\s*\d+\.\.\s*\d+:\s*(\d+)\.\.\s*(\d+):\s*(\d+):\s*(\S*)$/
      # Either first line or continuation of previous extent
      unless @total_seek_time == 0 ||
          Regexp.last_match(1).to_i == (@last_offset + 1)
        error("** Last line looks like a first line **\n" +
              @buffer.join("\n"))
      end
      @last_offset = Regexp.last_match(2).to_i
      flags = Regexp.last_match(4)
      length = Regexp.last_match(3).to_i
      if flags.split(",").include?("encoded")
        @compressed_blocks += length
      else
        @uncompressed_blocks += length
      end
    else
      error("** unknown line **\n" + @buffer.join("\n"))
    end
  end

  # Prepare for a new file
  def reinit
    @filename = nil
    @total_seek_time = 0
    @last_offset = 0
    @filesize = 0
    @compressed_blocks = 0
    @uncompressed_blocks = 0
    @eof = false
    @buffer = [ ]
  end

  # Test if a file is completely parsed
  def eof?
    @eof
  end

  def file_fragmentation(btrfs)
    frag = FileFragmentation.new(@filename, btrfs, majority_compressed)
    frag.fragmentation_cost =
      fragmentation_cost(@filesize, @total_seek_time)
    return frag
  end

  def current_frag_cost
    fragmentation_cost(@filesize, @total_seek_time)
  end

  def size
    @filesize
  end

  def majority_compressed
    @compressed_blocks > @uncompressed_blocks
  end
end

# Store fragmentation cost and relevant information for a file
class FileFragmentation
  attr_reader(:short_filename, :size, :fragmentation_cost)

  def initialize(filename, btrfs, majority_compressed)
    @short_filename = btrfs.short_filename(filename)
    @btrfs = btrfs
    @fragmentation_cost = 1
    @majority_compressed = majority_compressed
    @size = 0
  end

  def filename
    @btrfs.full_filename(@short_filename)
  end

  def fragmentation_cost=(cost)
    @fragmentation_cost = cost
  end

  def size=(size)
    @size = size
  end
  def read_time
    ((@size / @btrfs.transfer_rate) * @fragmentation_cost) + @btrfs.seek_delay
  end
  def write_time
    (@size / @btrfs.transfer_rate) + @btrfs.seek_delay
  end
  def defrag_time
    time = read_time +
           (write_time *
            @btrfs.average_cost(compress_type))
    time *= EXPECTED_COMPRESS_RATIO if compress_type == :compressed
    time
  end
  def majority_compressed?
    @majority_compressed
  end
  def compress_type
    @majority_compressed ? :compressed : :uncompressed
  end
  def human_size
    suffixes = [ "B", "kiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB" ]
    prefix = @size.to_f
    while (prefix > 1024) && (suffixes.size > 1)
      prefix = prefix / 1024
      suffixes.shift
    end
    "%.4g%s" % [ prefix, suffixes.shift ]
  end

  def update_fragmentation
    unless File.file?(filename)
      @fragmentation_cost = 1
      return
    end

    IO.popen(["filefrag", "-v", filename]) do |io|
      parser = FilefragParser.new
      while line = io.gets do
        line.chomp!
        parser.add_line(line)
        if parser.eof?
          self.fragmentation_cost = parser.current_frag_cost
          @size = parser.size
          @majority_compressed = parser.majority_compressed
        end
      end
    end
  end

  class << self
    def batch_init(filelist, btrfs)
      frags = []
      return frags if filelist.empty?
      IO.popen([ "filefrag", "-v" ] + filelist) do |io|
        parser = FilefragParser.new
        while line = io.gets do
          line.chomp!
          parser.add_line(line)
          if parser.eof?
            frags << parser.file_fragmentation(btrfs)
            parser.reinit
          end
        end
      end
      btrfs.track_compress_type(frags.map(&:compress_type))
      frags
    end
  end
end

class WriteEvents
  attr :first, :last
  def initialize
    @first = @last = Time.now
  end
  def write!
    @last = Time.now
  end
  # We suppose a file which is recently modified has higher chances of a
  # near-future modification, so we delay its check for defragmentation
  # commit_delay is used to avoid triggering fragmentation checks too early
  # by experience the fragmentation information is only updated after commits,
  # not after writes
  def ready_for_frag_check?(commit_delay)
    now = Time.now
    # We add a small delay to account for unexpected latencies
    after_write_delay = commit_delay + 5
    (last < (now - after_write_delay - fuzzy_delay)) ||
      (first < (now - MAX_WRITES_DELAY))
  end
  # This avoids an avalanche of defragmentation checks, use most noisy
  # bits of first timestamp
  def fuzzy_delay
    first.usec % DEFRAG_CHECK_DISTRIBUTION_PERIOD
  end
end

# Maintain the status of all candidates for defragmentation for a given
# filesystem
class FilesState
  include Outputs
  include HashEntrySerializer

  TYPES = [ :compressed, :uncompressed ]
  attr_reader :last_queue_overflow_at

  # Track recent events using a compact bitarray indexed by hashes of objects
  # It isn't thread safe but in the event of a race condition
  # it can only create minor false recent positive/negative recent test results
  # This is considered acceptable and may be protected by caller if needed
  class FuzzyEventTracker
    # Must be 1, 2, 4 or 8 depending on the precision objective
    # higher value can avoid temporary high spikes of queued files
    BITS_PER_ENTRY = 4
    # Should be enough: we don't expect to defragment more than 1/s
    # there's an hardcoded limit of 24 in position_offset
    ENTRIES_INDEX_BITS = 18
    MAX_ENTRIES = 2 ** ENTRIES_INDEX_BITS
    ENTRIES_PER_BYTE = 8 / BITS_PER_ENTRY
    MAX_ENTRY_VALUE = (2 ** BITS_PER_ENTRY) - 1

    attr_reader :size

    def initialize(serialized_data = nil)
      @tick_interval = IGNORE_AFTER_DEFRAG_DELAY / ((2 ** BITS_PER_ENTRY) - 1)
      # Reset recent data if rules changed or invalid serialization format
      if !serialized_data ||
         (serialized_data["ttl"] > IGNORE_AFTER_DEFRAG_DELAY) ||
         (serialized_data["bits_per_entry"] != BITS_PER_ENTRY) ||
         ((serialized_data["bitarray"].size * ENTRIES_PER_BYTE) != MAX_ENTRIES)
        error "Invalid serialized data: \n#{serialized_data.inspect}"
        @bitarray = "\0" * (MAX_ENTRIES / ENTRIES_PER_BYTE)
        @last_tick = Time.now
        @size = 0
        return
      end
      @bitarray = serialized_data["bitarray"]
      @last_tick = serialized_data["last_tick"]
      @size = serialized_data["size"]
    end

    # Excpects a string
    # set value to max in the entry (0 will indicate entry has expired)
    def event(object_id)
      advance_clock_when_needed
      position, offset = position_offset(object_id)

      byte = @bitarray.getbyte(position)
      nibbles = []
      ENTRIES_PER_BYTE.times do
        nibbles << (byte & MAX_ENTRY_VALUE)
        byte = (byte >> BITS_PER_ENTRY)
      end
      previous_value = nibbles[offset]
      nibbles[offset] = MAX_ENTRY_VALUE
      nibbles.reverse.each do |value|
        byte = (byte << BITS_PER_ENTRY)
        byte += value
      end
      @bitarray.setbyte(position, byte)
      @size += 1 if previous_value == 0
    end

    def recent?(object_id)
      advance_clock_when_needed
      position, offset = position_offset(object_id)
      byte = @bitarray.getbyte(position)
      offset.times { byte = (byte >> BITS_PER_ENTRY) }
      data = (byte & MAX_ENTRY_VALUE)
      data != 0
    end

    def serialization_data
      {
        "bitarray" => @bitarray,
        "last_tick" => @last_tick,
        "size" => @size,
        "ttl" => IGNORE_AFTER_DEFRAG_DELAY,
        "bits_per_entry" => BITS_PER_ENTRY
      }
    end

    private

    def advance_clock_when_needed
      tick! while (@last_tick + @tick_interval) < Time.now
    end

    # Rewrite bitarray, decrementing each value and updating size
    def tick!
      info "FuzzyEventTracker size was: #{size}" if $debug
      @last_tick += @tick_interval
      return if @size == 0 # nothing to be done
      @size = 0
      @bitarray.size.times do |byte_idx|
        byte = @bitarray.getbyte(byte_idx)
        next if byte == 0 # should be common
        nibbles = []
        ENTRIES_PER_BYTE.times do
          entry = byte & MAX_ENTRY_VALUE
          entry = [ entry - 1, 0 ].max
          nibbles << entry
          byte = (byte >> BITS_PER_ENTRY)
        end
        nibbles.reverse.each do |value|
          @size += 1 if value > 0
          byte = (byte << BITS_PER_ENTRY)
          byte += value
        end
        @bitarray.setbyte(byte_idx, byte)
      end
      info "FuzzyEventTracker size is: #{size}" if $debug
    end

    def position_offset(object_id)
      # We get the integer value from the first bytes modulo the number of entries
      event_idx =
        ("\0" + Digest::MD5.digest(object_id)[0...3]).
        unpack("N")[0] % MAX_ENTRIES
      [ event_idx / ENTRIES_PER_BYTE, event_idx % ENTRIES_PER_BYTE ]
    end
  end

  def initialize(btrfs)
    @btrfs = btrfs
    # Queue of files to defragment, ordered by fragmentation cost
    @file_fragmentations = {
      compressed: [],
      uncompressed: [],
    }
    @last_queue_overflow_at = nil
    @fetch_accumulator = {
      compressed: 0.5,
      uncompressed: 0.5,
    }
    @fragmentation_info_mutex = Mutex.new
    @type_tracker = {
      compressed: 1.0,
      uncompressed: 1.0,
    }
    @tracker_mutex = Mutex.new
    load_recently_defragmented
    load_history

    @written_files = {}
    @writes_mutex = Mutex.new
    @last_writes_consolidated_at = Time.now
    @next_status_printed_at = Time.now
  end

  def any_interesting_file?
    @fragmentation_info_mutex.synchronize {
      TYPES.any? { |t| @file_fragmentations[t].any? }
    }
  end

  def queued
    @fragmentation_info_mutex.synchronize {
      @file_fragmentations.values.map(&:size).inject(&:+)
    }
  end

  def next_defrag_duration
    @fragmentation_info_mutex.synchronize {
      @file_fragmentations[next_available_type].last.defrag_time
    }
  end

  # Implement a weighted round-robin
  def pop_most_interesting
    @fragmentation_info_mutex.synchronize {
      # Choose type before updating the accumulators to avoid inadvertedly
      # switching to another type after calling next_defrag_duration
      current_type = next_available_type
      @fetch_accumulator[current_type] %= 1.0
      TYPES.each { |type| @fetch_accumulator[type] += type_share(type) }
      @file_fragmentations[current_type].pop
    }
  end

  def recently_defragmented?(shortname)
    @fragmentation_info_mutex.synchronize do
      @recently_defragmented.recent?(shortname)
    end
  end

  def defragmented!(shortname)
    @fragmentation_info_mutex.synchronize do
      @recently_defragmented.event(shortname)
      serialize_recently_defragmented if must_serialize_recent?
    end
    remove_tracking(shortname)
  end

  def remove_tracking(shortname)
    @writes_mutex.synchronize { @written_files.delete(shortname) }
  end

  def update_files(file_fragmentations, threshold_multiplier = nil)
    return 0 unless file_fragmentations.any?
    updated_names = file_fragmentations.map(&:short_filename)
    duplicate_names = []
    # Remove files we won't consider anyway
    file_fragmentations.reject! do |frag|
      below_threshold_cost(frag, threshold_multiplier)
    end
    @fragmentation_info_mutex.synchronize {
      # Remove duplicates and compute duplicate names
      TYPES.each { |type|
        @file_fragmentations[type].reject! { |frag|
          if updated_names.include?(frag.short_filename)
            duplicate_names << frag.short_filename
            true
          else
            false
          end
        }
      }
      # Insert new versions (if they are still above threshold) and new files
      file_fragmentations.each { |f| @file_fragmentations[f.compress_type] << f }
      sort_files
      # Remove old entries and fit in max queue length
      cleanup_files
      # Returns the number of new files queued
      updated_names -= duplicate_names
      # Verify we didn't cleanup some of them
      updated_names.select { |n|
        # Use uncompressed first as it seems the most common case
        @file_fragmentations[:uncompressed].any? { |f| f.short_filename == n } ||
        @file_fragmentations[:compressed].any? { |f| f.short_filename == n }
      }.size
    }
  end

  def file_written_to(filename)
    shortname = @btrfs.short_filename(filename)
    return if recently_defragmented?(shortname)
    interval = Time.now - @next_status_printed_at
    if interval > 0
      status
      # keep up if we stopped printing status for a while
      @next_status_printed_at +=
        (STATUS_PERIOD + (STATUS_PERIOD * (interval / STATUS_PERIOD)))
    end
    @writes_mutex.synchronize {
      if @written_files[shortname]
        @written_files[shortname].write!
      else
        @written_files[shortname] = WriteEvents.new
      end
    }
    if @last_writes_consolidated_at <
        (Time.now - TRACKED_WRITTEN_FILES_CONSOLIDATION_PERIOD)
      consolidate_writes
    end
  end

  def historize_cost_achievement(file_frag, initial_cost, final_cost, size)
    key = file_frag.majority_compressed? ? :compressed : :uncompressed
    @cost_achievement_history[key] << [ initial_cost, final_cost, size ]
    if @cost_achievement_history[key].size > COST_HISTORY_SIZE
      @cost_achievement_history[key].shift
    end
    compute_thresholds
    serialize_history
  end

  def average_cost(type)
    @average_costs[type]
  end

  def below_threshold_cost(frag, threshold_multiplier = nil)
    limit = threshold_cost(frag)
    limit = ((limit - 1) * threshold_multiplier) + 1 if threshold_multiplier
    frag.fragmentation_cost <= limit
  end

  def type_track(types)
    @tracker_mutex.synchronize {
      types.each { |type|
        @type_tracker[type] += 1.0
      }
      total = @type_tracker.values.inject(&:+)
      memory = 10_000.0 # TODO: tune/config
      if total > memory
        @type_tracker.each_key { |key|
          @type_tracker[key] *= (memory / total)
        }
      end
    }
  end

  def type_share(type)
    @tracker_mutex.synchronize {
      total = @type_tracker.values.inject(&:+)
      # Return a default value if there isn't enough data, assume equal shares
      (total < 10) ? 0.5 : @type_tracker[type] / total
    }
  end

  def queue_fill_proportion
    @fragmentation_info_mutex.synchronize {
      total_queue_size.to_f / MAX_QUEUE_LENGTH
    }
  end

  private
  # MUST be protected by @fragmentation_info_mutex
  def next_available_type
    next_type =
      @fetch_accumulator.keys.find { |type| @fetch_accumulator[type] >= 1.0 }
    # In case of Float rounding errors we might not have any available next_type
    case next_type
    when :compressed
      @file_fragmentations[:compressed].any? ? :compressed : :uncompressed
    else
      @file_fragmentations[:uncompressed].any? ? :uncompressed : :compressed
    end
  end

  def consolidate_writes
    batch = []
    to_check = []
    args_length = 0
    @writes_mutex.synchronize {
      @written_files.each { |shortname,value|
        if value.ready_for_frag_check?(@btrfs.commit_delay)
          batch << shortname
          fullname = @btrfs.full_filename(shortname)
          to_check << fullname if File.file?(fullname)
          args_length += fullname.size + 1
          # We must limit the argument length (the rest will be processed
          # during a future call)
          break if args_length >= FILEFRAG_ARG_MAX
        end
      }
    }
    # We remove them from @written_files because update_files filters
    # according to its content
    @writes_mutex.synchronize {
      batch.each { |shortname| @written_files.delete(shortname) }
    }
    update_files(FileFragmentation.batch_init(to_check, @btrfs),
                 fatrace_threshold_multiplier)
    to_check = []
    # Cleanup if overflow
    @writes_mutex.synchronize {
      if @written_files.size > MAX_TRACKED_WRITTEN_FILES
        to_remove = @written_files.size - MAX_TRACKED_WRITTEN_FILES
        @written_files.keys.sort_by { |short|
          @written_files[short].last
        }[0...to_remove].each { |short|
          fullname = @btrfs.full_filename(short)
          to_check << fullname if File.file?(fullname)
          @written_files.delete(short)
        }
        info "** %s writes tracking overflow: %d > %d" %
          [ @btrfs.dirname, to_remove + MAX_TRACKED_WRITTEN_FILES,
          MAX_TRACKED_WRITTEN_FILES ]
      end
    }
    update_files(FileFragmentation.batch_init(to_check, @btrfs),
                 fatrace_threshold_multiplier)
    @last_writes_consolidated_at = Time.now
  end

  def status
    info(("# #{@btrfs.dirname} c: %.1f%%; " \
           "(c/u) queued: %d/%d; " \
           "ini: %.2f/%.2f; " \
           "avg: %.2f/%.2f; " \
           "cur: %.3f/%.3f; " \
           "flw: %d; recent: %d") %
         [ type_share(:compressed) * 100,
           queue_size(:compressed), queue_size(:uncompressed),
           @initial_costs[:compressed], @initial_costs[:uncompressed],
           @average_costs[:compressed], @average_costs[:uncompressed],
           current_queue_threshold(:compressed),
           current_queue_threshold(:uncompressed),
           @written_files.size, @recently_defragmented.size ])
  end

  def thresholds_expired?
    @last_thresholds_at < (Time.now - COST_COMPUTE_DELAY)
  end
  def compute_thresholds
    return unless thresholds_expired?
    TYPES.each { |key|
      size = @cost_achievement_history[key].size
      # We want a weighted percentile, higher weight for more recent costs
      threshold_weight = 0
      # This is now weighted and can't be computed from the size
      @cost_achievement_history[key].each_with_index { |costs, index|
        threshold_weight = costs[2] * (index + 1)
      }
      threshold_weight *= (COST_THRESHOLD_PERCENTILE.to_f / 100)
      ordered_history =
      @cost_achievement_history[key].each_with_index.map { |costs,index|
        [ costs, index + 1 ]
      }.sort_by { |a| a[0][1] } # order by final cost
      total_weight = 0
      final_accu = 0
      initial_accu = 0
      result = [ 1, 1 ] # default if no cost found
      # This will stop as soon as we reach the percentile
      while total_weight < threshold_weight
        result, weight = ordered_history.shift
        initial_accu += result[0] * result[2] * weight
        final_accu += result[1] * result[2] * weight
        total_weight += result[2] * weight
      end
      # Percentile reached
      @cost_thresholds[key] = result[1] * MIN_EXPECTED_BENEFIT
      # Continue with the rest
      while ordered_history.any?
        result, weight = ordered_history.shift
        initial_accu += result[0] * result[2] * weight
        final_accu += result[1] * result[2] * weight
        total_weight += result[2] * weight
      end
      @average_costs[key] = final_accu / total_weight
      @initial_costs[key] = initial_accu / total_weight
    }
    @last_thresholds_at = Time.now
  end
  def fatrace_threshold_multiplier
    # fatrace is used to detect heavily fragmented files early
    # The longer we wait after defrag, the lower the multiplier:
    # each file defragmented because fatrace bring as much benefit than
    # a file defragmented because of the slow scan
    [ SLOW_SCAN_PERIOD.to_f / IGNORE_AFTER_DEFRAG_DELAY, 1 ].min
  end
  def must_serialize_history?
    @last_history_serialized_at < (Time.now - HISTORY_SERIALIZE_DELAY)
  end
  def serialize_history
    return unless must_serialize_history?
    serialize_entry(@btrfs.dir, @cost_achievement_history, HISTORY_STORE)
    @last_history_serialized_at = Time.now
  end
  def load_history
    # This is the result of experimentations with Ceph OSDs
    default_value = {
      compressed: [ [ 2.65, 2.65, 1_000_000 ] ] * (COST_HISTORY_SIZE / 100),
      uncompressed: [ [ 1.02, 1.02, 1_000_000 ] ] * (COST_HISTORY_SIZE / 100),
    }

    @cost_achievement_history =
      unserialize_entry(@btrfs.dir, HISTORY_STORE, "cost history", default_value)

    # Update previous versions without sizes
    TYPES.each do |key|
      @cost_achievement_history[key].map! do |cost|
        cost.size == 3 ? cost : cost << 1_000_000
      end
    end

    @last_history_serialized_at = Time.now
    # Force thresholds computation
    @last_thresholds_at = Time.at(0)
    @cost_thresholds = {}
    @average_costs = {}
    @initial_costs = {}
    compute_thresholds
  end
  def must_serialize_recent?
    @last_recent_serialized_at < (Time.now - RECENT_SERIALIZE_DELAY)
  end
  def load_recently_defragmented
    @recently_defragmented =
      FuzzyEventTracker.new(unserialize_entry(@btrfs.dir, RECENT_STORE,
                                              "recently defragmented"))
    @last_recent_serialized_at = Time.now
  end
  def serialize_recently_defragmented
    serialize_entry(@btrfs.dir, @recently_defragmented.serialization_data,
                    RECENT_STORE)
    @last_recent_serialized_at = Time.now
  end

  def sort_files
    TYPES.each { |t| @file_fragmentations[t].sort_by!(&:fragmentation_cost) }
  end
  # Must be called protected by @fragmentation_info_mutex and after sorting
  def cleanup_files
    if total_queue_size > MAX_QUEUE_LENGTH
      @last_queue_overflow_at = Time.now
      compressed_target_size = queue_reserve(:compressed)
      uncompressed_target_size = queue_reserve(:uncompressed)
      if queue_size(:compressed) < compressed_target_size
        # uncompressed has this size available
        uncompressed_target_size = MAX_QUEUE_LENGTH - queue_size(:compressed)
      end
      if queue_size(:uncompressed) < uncompressed_target_size
        # compressed has this size available
        compressed_target_size = MAX_QUEUE_LENGTH - queue_size(:uncompressed)
      end
      if queue_size(:compressed) > compressed_target_size
        start = queue_size(:compressed) - compressed_target_size
        @file_fragmentations[:compressed] =
          @file_fragmentations[:compressed][start..-1]
      end
      if queue_size(:uncompressed) > uncompressed_target_size
        start = queue_size(:uncompressed) - uncompressed_target_size
        @file_fragmentations[:uncompressed] =
          @file_fragmentations[:uncompressed][start..-1]
      end
    end
  end
  def queue_size(type)
    @file_fragmentations[type].size
  end
  def current_queue_threshold(type)
    size = queue_size(type)
    if size > 0
      @file_fragmentations[type][0].fragmentation_cost
    else
      @cost_thresholds[type]
    end
  end
  def queue_reserve(type)
    [ (MAX_QUEUE_LENGTH * type_share(type)).to_i, 2 ].max
  end
  def total_queue_size
    TYPES.map{ |t| queue_size(t) }.inject(&:+)
  end
  def threshold_cost(frag)
    if frag.majority_compressed?
      @cost_thresholds[:compressed]
    else
      @cost_thresholds[:uncompressed]
    end
  end
end

# Responsible for maintaining information about the filesystem itself
# and background threads
class BtrfsDev
  attr_reader :dir, :dirname, :commit_delay
  include FragmentationCost
  include Outputs
  include HashEntrySerializer

  # create the internal structures, including references to other mountpoints
  def initialize(dir, dev_fs_map)
    @dir = dir
    @dirname = File.basename(dir)
    detect_options(dev_fs_map)
    load_filecount
    @checker = UsagePolicyChecker.new
    @files_state = FilesState.new(self)

    # Tracking of file defragmentation
    @files_in_defragmentation = {}
    @stat_mutex = Mutex.new
    @stat_thread = Thread.new {
      loop do
        handle_stat_queue_progress
        sleep 5
      end
    }

    @slow_scan_thread = Thread.new {
      info("## Beginning files list updater thread for #{dir}")
      slow_files_state_update(first_pass: true)
      loop do
        slow_files_state_update
      end
    }

    @defrag_thread = Thread.new {
      loop do
        defrag!
        sleep delay_between_defrags
      end
    }
  end

  def detect_options(dev_fs_map)
    @my_dev_id = File.stat(dir).dev
    update_subvol_dirs(dev_fs_map)
    load_exceptions
    changed = false
    compressed = mounted_with_compress?
    if compressed.nil?
      info "## #{dir}: probably umounted"
      return
    end
    if @compressed != compressed
      changed = true
      @compressed = compressed
      info "## #{dir}: compressed mount is now #{@compressed ? 'on' : 'off'}"
    end
    commit_delay = parse_commit_delay
    if @commit_delay != commit_delay
      changed = true
      @commit_delay = commit_delay
      info "## #{dir}: commit_delay is now #{@commit_delay}"
    end
    # Reset defrag_cmd if something changed (will be computed on first access)
    @defrag_cmd = nil if changed
  end

  def stop_processing
    [ @slow_scan_thread, @stat_thread, @defrag_thread ].each do |thread|
      Thread.kill(thread) if thread
    end
  end

  def has_dev?(dev_id)
    @dev_list.include?(dev_id)
  end

  # Manage queue of asynchronously defragmented files
  def stat_queue(file_frag)
    # Initially queued_at and last_change must be equal
    queued_at = Time.now
    @stat_mutex.synchronize {
      @files_in_defragmentation[file_frag] = {
        queued_at: queued_at,
        last_change: queued_at,
        last_cost: file_frag.fragmentation_cost,
        start_cost: file_frag.fragmentation_cost,
        size: file_frag.size
      }
    }
  end

  def handle_stat_queue_progress
    to_remove = []
    @stat_mutex.synchronize {
      @files_in_defragmentation.each { |key,value|
        last_change = value[:last_change]
        start = value[:queued_at]
        if value[:last_cost] == 1.0 ||
            ((last_change != start) &&
            ((Time.now - last_change) > 6)) ||
            (Time.now - start) > 35
          to_remove << key
          @files_state.historize_cost_achievement(key, value[:start_cost],
                                                  value[:last_cost],
                                                  value[:size])
        else
          key.update_fragmentation
          # if it went up its because of concurrent activity, ignore
          if key.fragmentation_cost < value[:last_cost]
            value[:last_cost] = key.fragmentation_cost
            value[:last_change] = Time.now
          end
        end
      }
      to_remove.each { |frag| @files_in_defragmentation.delete(frag) }
    }
  end

  def claim_file_write(filename)
    local_name = position_on_fs(filename)
    return false unless local_name
    @files_state.file_written_to(local_name) unless skip_defrag?(local_name)
    true
  end

  def position_on_fs(filename)
    return filename if filename.index(dir) == 0
    subvol_fs = @fs_map.keys.find { |fs| filename.index(fs) == 0 }
    return nil unless subvol_fs
    # This is a local file, triggered from another subdir, move in our domain
    filename.gsub(subvol_fs, @fs_map[subvol_fs])
  end

  def defrag!
    file_frag = get_next_file_to_defrag
    return unless file_frag
    shortname = file_frag.short_filename

    # We declare it defragmented ASAP to avoid a double queue
    @files_state.defragmented!(shortname)
    run_with_device_usage(usage: file_frag.defrag_time) {
      cmd = defrag_cmd + [ file_frag.filename ]
      if $verbose
        msg = "-- %s: %s %s,%s,%.2f" %
              [ dir, shortname, (file_frag.majority_compressed? ? "C" : "U"),
                file_frag.human_size, file_frag.fragmentation_cost ]
        info(msg)
      end
      system(*cmd)
    }
    # Clear up any writes detected concurrently
    @files_state.remove_tracking(shortname)
    stat_queue(file_frag)
  end

  # recursively search for the next file to defrag
  def get_next_file_to_defrag
    return nil unless @files_state.any_interesting_file? && available_for_defrag?
    file_frag = @files_state.pop_most_interesting
    shortname = file_frag.short_filename
    # Check that file still exists
    unless file_frag && File.file?(file_frag.filename)
      @files_state.remove_tracking(shortname)
      return get_next_file_to_defrag
    end
    file_frag.update_fragmentation
    # Skip files that are already below target and reset tracking
    # to avoid future work if there aren't any more writes
    if @files_state.below_threshold_cost(file_frag)
      @files_state.remove_tracking(shortname)
      return get_next_file_to_defrag
    end

    if @files_state.recently_defragmented?(shortname)
      @files_state.remove_tracking(shortname)
      return get_next_file_to_defrag
    end

    file_frag
  end

  def available_for_defrag?
    @checker.available?(@files_state.queue_fill_proportion,
                        @files_state.next_defrag_duration)
  end

  # Only recompress if we are already compressing data
  def defrag_cmd
    return @defrag_cmd if @defrag_cmd
    cmd =
      if @compressed
        [ "btrfs", "filesystem", "defragment", "-czlib" ]
      else
        [ "btrfs", "filesystem", "defragment" ]
      end
    if $default_extent_size
      cmd += [ "-t", $default_extent_size ]
    end
    @defrag_cmd = cmd
  end

  # We prefer to store short filenames to free memory
  def short_filename(filename)
    filename.gsub("#{dir}/", "")
  end
  def full_filename(short_filename)
    "#{dir}/#{short_filename}"
  end
  def file_id(short_filename)
    "#{@dirname}: #{short_filename}"
  end
  def average_cost(type)
    @files_state.average_cost(type)
  end
  def track_compress_type(compress_types)
    @files_state.type_track(compress_types)
  end

  private
  # Slowly update files, targeting a SLOW_SCAN_PERIOD period for all updates
  def slow_files_state_update(first_pass: false)
    if first_pass && @last_processed > 0
      info("#{@dirname}: skipping #{@last_processed} files " \
           "in #{SLOW_SCAN_CATCHUP_WAIT}s")
      # Avoids hammering disk just after startup
      sleep SLOW_SCAN_CATCHUP_WAIT
    end
    count = 0; already_processed = 0; recent = 0; queued = 0
    filelist = []
    filelist_arg_length = 0
    start = @last_slow_scan_pause = Time.now
    # If we skip some files, we don't wait for the whole scan period either
    duration_factor =
      if first_pass && @filecount && @filecount > 0
        (@filecount - @last_processed).to_f / @filecount
      else
        1
      end
    @slow_scan_stop_time = start + duration_factor * SLOW_SCAN_PERIOD
    @next_slow_status_printed_at ||= Time.now
    # Target a batch size for MIN_DELAY_BETWEEN_FILEFRAGS interval between
    # filefrag calls
    @slow_batch_size =
      [ MIN_DELAY_BETWEEN_FILEFRAGS * filecount / SLOW_SCAN_PERIOD,
        MIN_FILES_BATCH_SIZE ].max
    begin
      Find.find(dir) do |path|
        if @next_slow_status_printed_at <= Time.now
          info "-- #{dir}: #{short_filename(path)}" if $debug
          print_slow_status(start, queued, count, already_processed, recent)
        end
        if prune?(path)
          Find.prune
        else
          # ignore files with unparsable names
          short_name = short_filename(path) rescue ""
          next if short_name == ""
          # Don't count as a file
          next if File.exists?(path) && !File.file?(path)
          count += 1
          # Ignore recently processed files
          next if first_pass && (count < @last_processed)
          if @files_state.recently_defragmented?(short_name)
            already_processed += 1
            next
          end
          stat = File.stat(path) rescue nil
          next unless stat
          last_modification =
            [ stat.mtime, stat.ctime ].max
          if last_modification > (Time.now - (commit_delay + 5))
            recent += 1
            next
          end
          # TODO: check minimum allocation size (16k according to btrfs-users@?)
          # File too small to be fragmented?
          next if stat.size <= 4096

          filelist << path
          filelist_arg_length += (path.size + 1) # count space

          # Stop and compute fragmentation for each completed batch
          if (filelist.size == @slow_batch_size) ||
             (filelist_arg_length >= FILEFRAG_ARG_MAX)
            queued += queue_slow_batch(count, filelist)
            filelist = []; filelist_arg_length = 0
            wait_before_next_slow_scan_pass(count)
          end
        end
      end
    rescue => ex
      error("Couldn't process #{dir}: " \
            "#{ex}\n#{ex.backtrace.join("\n")}")
      # Don't wait for a SLOW_SCAN_PERIOD
      @slow_scan_stop_time = Time.now + MIN_DELAY_BETWEEN_FILEFRAGS
    end
    # Process remaining files to update
    if filelist.any?
      frags = FileFragmentation.batch_init(filelist, self)
      queued += @files_state.update_files(frags)
    end
    info(("# %s %d/%ds: %d queued / %d found, " +
          "%d defragmented recently, %d changed recently, %d low cost") %
         [ @dirname, (Time.now - start).to_i, SLOW_SCAN_PERIOD, queued, count,
           already_processed, recent,
           count - already_processed - recent - queued ])
    was_guessed = @filecount.nil?
    update_filecount(processed: 0, total: count)
    wait_before_slow_scan_restart(was_guessed)
  end

  def prune?(entry)
    (File.directory?(entry) && (entry != dir) &&
     Pathname.new(entry).mountpoint? && !rw_subvol?(entry)) ||
      blacklisted?(entry)
  rescue
    # Pathname#mountpoint can't process some entries
    false
  end

  def skip_defrag?(filename)
    filename.end_with?(" (deleted)") || blacklisted?(filename)
  end

  def run_with_device_usage(usage: nil)
    start = Time.now
    result = yield
    duration = Time.now - start
    if usage && (duration > usage)
      # We have an estimation of the total usage cost
      # but it might be under-evaluated so we use actual time spent
      # (which doesn't count asynchronous disk usage) as a safeguard
      adjusted_duration = [ duration, usage * 2 ].min
      @checker.add_usage(start, adjusted_duration)
    else
      @checker.add_usage(start, duration)
    end
    return result
  end

  def mounted_with_compress?
    options = mount_options
    return nil unless options
    !options.split(',').detect { |option|
      [ "compress=lzo", "compress=zlib",
        "compress-force=lzo", "compress-force=zlib" ].include?(option)
    }.nil?
  end

  def parse_commit_delay
    delay = nil
    options = mount_options
    return unless options
    options.split(',').each { |option|
      if option.match(/^commit=(\d+)/)
        delay = Regexp.last_match[1].to_i
        break
      end
    }
    return delay || DEFAULT_COMMIT_DELAY
  end

  def mount_line
    File.read("/proc/mounts").lines.reverse.find { |line|
      line.match(/\S+\s#{dir}\s/)
    }
  end

  def mount_options
    mount_line && mount_line.match(/\S+\s\S+\sbtrfs\s(\S+)/)[1]
  end

  def update_filecount(processed: nil, total: nil)
    do_update = if (total != @filecount)
                  true
                else
                  (processed < @last_processed) ||
                    ((processed.to_f - @last_processed) / filecount) > 0.01
                end
    return unless do_update
    @filecount = total
    @last_processed = processed
    entry = { processed: processed, total: total }
    serialize_entry(@dir, entry, FILE_COUNT_STORE)
    info "# #{@dirname}, #{entry.inspect}" if total
  end

  def load_filecount
    default_value = { processed: 0, total: nil }
    entry =
      unserialize_entry(@dir, FILE_COUNT_STORE, "filecount", default_value)
    @last_processed = entry[:processed]
    @filecount = entry[:total]
  end

  # Get filecount or a default value
  def filecount
    @filecount ||
      SLOW_SCAN_PERIOD * MIN_FILES_BATCH_SIZE / MIN_DELAY_BETWEEN_FILEFRAGS
  end

  # Return number of items queued
  def queue_slow_batch(count, filelist)
    @slow_pass_expected_left = filecount - count
    # Use larger batch if we didn't finish in time
    if @slow_pass_expected_left < 0 || Time.now > @slow_scan_stop_time
      @slow_batch_size =
        [ (@slow_batch_size * 1.1).to_i, MAX_FILES_BATCH_SIZE ].min
    end
    frags = FileFragmentation.batch_init(filelist, self)
    @files_state.update_files(frags)
  end

  def wait_before_next_slow_scan_pass(count)
    update_filecount(processed: count, total: @filecount)
    if @filecount.nil?
      sleep MIN_DELAY_BETWEEN_FILEFRAGS
    elsif (Time.now < @slow_scan_stop_time) && (count < filecount)
      # Count time spent computing a batch to compensate for it
      batch_delay = Time.now - @last_slow_scan_pause
      interval =
        (@slow_scan_stop_time - Time.now) * @slow_batch_size /
        @slow_pass_expected_left
      sleep([ [ interval - batch_delay, MIN_DELAY_BETWEEN_FILEFRAGS ].max,
              MAX_DELAY_BETWEEN_FILEFRAGS ].min)
    else
      # We can't compute a good interval use MIN_DELAY
      sleep MIN_DELAY_BETWEEN_FILEFRAGS
    end
    @last_slow_scan_pause = Time.now
  end

  def wait_before_slow_scan_restart(guessed_filecount)
    sleep (if guessed_filecount
             MIN_DELAY_BETWEEN_FILEFRAGS
           elsif Time.now < @slow_scan_stop_time
             [ [ (@slow_scan_stop_time - Time.now),
                 MIN_DELAY_BETWEEN_FILEFRAGS ].max,
               MAX_DELAY_BETWEEN_FILEFRAGS ].min
           else
             MIN_DELAY_BETWEEN_FILEFRAGS
           end)
  end

  def print_slow_status(start, queued, count, already_processed, recent,
                        stopped = false)
    @next_slow_status_printed_at += SLOW_STATUS_PERIOD
    msg = ("#{stopped ? '#' : '-'} %s %d/%ds: %d queued / %d found, " +
           "%d defragmented recently, %d changed recently, %d low cost") %
          [ @dirname, (Time.now - start).to_i, SLOW_SCAN_PERIOD, queued, count,
            already_processed, recent,
            count - already_processed - recent - queued ]
    if @files_state.last_queue_overflow_at &&
       (@files_state.last_queue_overflow_at > (Time.now - SLOW_SCAN_PERIOD))
      msg += " ovf: #{(Time.now - @files_state.last_queue_overflow_at).to_i}s ago"
    end
    info msg
  end

  # Don't loop on defrag aggressively if there isn't much to be done
  def delay_between_defrags
    # 100 factor: At 1% queue fill (currently 20 files) we use the max speed
    proportional_delay =
      @files_state.queue_fill_proportion * 100 *
      (MAX_DELAY_BETWEEN_DEFRAGS - MIN_DELAY_BETWEEN_DEFRAGS)
    [ MAX_DELAY_BETWEEN_DEFRAGS - proportional_delay,
      MIN_DELAY_BETWEEN_DEFRAGS ].max
  end

  def load_exceptions
    no_defrag_list = []
    exceptions_file = "#{dir}/.no_defrag"
    if File.readable?(exceptions_file)
      no_defrag_list =
        File.read(exceptions_file).split("\n").map { |path| "#{dir}/#{path}" }
    end
    if no_defrag_list.any? && (@no_defrag_list != no_defrag_list)
      info "-- #{dir} blacklist: #{no_defrag_list.inspect}"
    end
    @no_defrag_list = no_defrag_list
  end

  def blacklisted?(filename)
    @no_defrag_list.any? { |blacklist| filename.index(blacklist) == 0 }
  end

  def rw_subvol?(dir)
    @rw_subvols.include?(dir)
  end

  def update_subvol_dirs(dev_fs_map)
    subvol_dirs_list = BtrfsDev.list_rw_subvolumes(dir)
    fs_map = {}
    dev_list = Set.new
    rw_subvols = Set.new
    subvol_dirs_list.each do |subvol|
      full_path = "#{dir}/#{subvol}"
      rw_subvols << full_path
      dev_id = File.stat(full_path).dev
      other_fs = dev_fs_map[dev_id]
      other_fs.each { |fs| fs_map[fs] = full_path }
      dev_list << dev_id
    end
    dev_list << File.stat(dir).dev
    if fs_map != @fs_map
      info "-- #{dir}: changed filesystem maps"
      info fs_map.inspect
      @fs_map = fs_map
    end
    @dev_list = dev_list
    @rw_subvols = rw_subvols
  end

  class << self
    def list_subvolumes(dir)
      new_subdirs = []
      IO.popen([ "btrfs", "subvolume", "list", dir ]) do |io|
        while line = io.gets do
          line.chomp!
          if match = line.match(/^.* path (.*)$/)
            new_subdirs << match[1]
          else
            error "can't parse #{line}"
          end
        end
      end
      new_subdirs
    end

    def list_rw_subvolumes(dir)
      list_subvolumes(dir).select do |subdir|
        File.writable?("#{dir}/#{subdir}")
      end
    end
  end
end

class BtrfsDevs
  def initialize
    @btrfs_devs = []
    @lock = Mutex.new
    @new_fs = false
  end

  def update!
    # Enumerate BTRFS filesystems, avoid autodefrag ones
    dirs = IO.popen("grep btrfs /proc/mounts | grep -v autodefrag | " +
                    "awk '{ print $2 }'") { |io| io.readlines.map(&:chomp) }
    dev_fs_map = Hash.new { |hash, key| hash[key] = Set.new }
    dirs.each { |dir| dev_fs_map[File.stat(dir).dev] << dir }
    @lock.synchronize do
      umounted = @btrfs_devs.select { |dev| !dirs.include?(dev.dir) }
      umounted.each do |dev|
        info "#{dev.dir} not mounted without autodefrag anymore"
        dev.stop_processing
      end
      @btrfs_devs.reject! { |dev| umounted.include?(dev) }
      # Detect remount -o compress=... events
      @btrfs_devs.each { |dev| dev.detect_options(dev_fs_map) }
      dirs.each { |dir|
        next unless top_volume?(dir)
        next if known?(dir)
        next if @btrfs_devs.map(&:dir).include?(dir)
        info "#{dir} mounted without autodefrag"
        @btrfs_devs << BtrfsDev.new(dir, dev_fs_map)
        @new_fs = true
      }
    end
  end

  def handle_file_write(file)
    @lock.synchronize { @btrfs_devs.find { |dev| dev.claim_file_write(file) } }
  end

  # To call to detect a new fs being added to the watch list
  def new_fs?
    copy = false
    @lock.synchronize do
      copy = @new_fs
      @new_fs = false
    end
    copy
  end

  def top_volume?(dir)
    BtrfsDev.list_subvolumes(dir).all? do |subdir|
      Pathname.new("#{dir}/#{subdir}").mountpoint?
    end
  end

  def known?(dir)
    dev_id = File.stat(dir).dev
    @btrfs_devs.any? { |btrfs_dev| btrfs_dev.has_dev?(dev_id) }
  end
end

include Outputs

def fatrace_file_writes(devs)
  # This is a hack to avoid early restarts:
  # new_fs? waits for devs.update! to finish which can be a bit long
  # as it calls the btrfs command multiple times to parse dev properties
  sleep 0.5; devs.new_fs?
  cmd = [ "fatrace", "-f", "W" ]
  extract_write_re = /^[^(]+\([0-9]+\): [ORWC]+ (.*)$/
  loop do
    failed = false
    info("Starting global fatrace thread")
    begin
      last_popen_at = Time.now
      IO.popen(cmd) do |io|
        begin
          while line = io.gets do
            # Skip btrfs commands (defrag mostly)
            next if line.index("btrfs(") == 0
            if match = line.match(extract_write_re)
              file = match[1]
              devs.handle_file_write(file)
            else
              error "Can't extract file from '#{line}'"
            end
            # TODO: Maybe don't check on each pass
            break if Time.now > (last_popen_at + FATRACE_TTL)
            break if devs.new_fs?
          end
        rescue => ex
          error "Error in inner fatrace thread: #{ex}"
        end
      end
    rescue => ex
      failed = true
      error "Error in outer fatrace thread: #{ex}"
    end
    # Arbitrary sleep to avoid CPU load in case of fatrace repeated failure
    if failed
      delay = 60
      info("Fatrace thread waiting #{delay}s before restart")
      sleep delay
    end
  end
end

info "**********************************************"
info "** Starting BTRFS defragmentation scheduler **"
info "**********************************************"
next_dev_update = Time.now
devs = BtrfsDevs.new
devs.update!
Thread.new { fatrace_file_writes(devs) }

loop do
  next_dev_update += FS_DETECT_PERIOD
  now = Time.now
  sleep (next_dev_update - now) if now < next_dev_update
  devs.update!
end
