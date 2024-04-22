#!/usr/local/bin/ruby

# --------------------------------
# Environment
$test = false
#$test = true # you can set true to stdout instead of post.

# --------------------------------
# Requires

require 'logger'
require 'open-uri'
require 'openssl'
require 'json'
require 'timeout'
require 'parallel'
require 'ostruct'
require 'time'

# Require these in `reqruire gems for sns` section.
# require 'nostr_ruby'
# require 'bskyrb'

# --------------------------------
# Constants
logger = Logger.new("#{__dir__}/log.log", 3)
$NOW = Time.now
$URL_BASE = "https://www3.nhk.or.jp/n-data/traffic/train/%s?_=#{$NOW.to_i}"
$MAX_ROWS = 10
$STS_NORMAL  = '平常運転'
$STS_RECOVER = '運転再開'
$STS_SUSPEND = '運転見合わせ'
$STS_DELAY   = '列車遅延'
$STS = Hash.new {|hash, key| hash[key] = OpenStruct.new({ sign: '🟡', level: 0 })}
$STS[$STS_NORMAL]  = OpenStruct.new({ sign: '🟢', level: 1 })
$STS[$STS_RECOVER] = OpenStruct.new({ sign: '🟢', level: 2 })
$STS[$STS_SUSPEND] = OpenStruct.new({ sign: '🔴', level: 3 })
$STS['運転計画']   = OpenStruct.new({ sign: 'ℹ️', level: 0 })
$ALL_CLEAR = "🟢現在、見合わせ・遅延などの情報はありません\n🎶🚃🚃🚃🚃🚃🚃🚃🚃🚃..."
$OVERFLOW = '...他%d件'

# --------------------------------
# Utils
def make_pk(item)
  item['companyCode'] + '-' + item['trainLineCode']
end

def match_any?(item, patterns)
  patterns.each do |pattern|
    m = true
    pattern.each do |key, value|
      if item[key] != value
        m = false
        break
      end
    end
    return true if m
  end
  return false
end

def trancate(lines, count)
  l = []
  l << lines.first(count)
  overflow = lines.length - count
  l << ($OVERFLOW % overflow) if 0 < overflow
  return l
end

def to_timestamp(text)
  t = text.gsub(/(^|[^0-9])([0-9][^0-9])/, '\10\2')
  dt = Time.strptime(t, '%m月%d日 %H時%M分')
  dt = dt.next_year(-1) if $NOW < dt
  return dt
end

# --------------------------------
# Main
logger.info('start')

config = JSON.parse(File.read("#{__dir__}/config.json"))
$test = $test || config['test']
puts 'test mode' if $test
config['traininfo'].each do |conf|

  # ---------------
  # setup
  private_key = conf['private_key']
  bsky_username = conf['bsky_username']
  bsky_password = conf['bsky_password']
  jsonfile = conf['jsonfile']
  link_url = conf['url']
  ignore = conf['ignore'] || []
  ignore_days = conf['ignore_days'] || 3
  ignore_days_sec = ignore_days * 24 * 60 * 60
  logger.info(jsonfile)

  datadir = "#{__dir__}/data"
  cachefile = "#{datadir}/#{jsonfile}"
  cachedata = "#{datadir}/#{jsonfile}".sub(/\.json$/, '.dat.json')
  mkdir Dir.mkdir(datadir) if ! File.directory?(datadir)
  if !File.file?(cachefile)
    File.open(cachefile, mode = 'w') { |f|
      f.write('{ "channel": { "item": [] } }')
    }
  end
  if !File.file?(cachedata)
    File.open(cachedata, mode = 'w') { |f|
      f.write('{ "history": {}, "last_post": "" }')
    }
  end

  # ---------------
  # reqruire gems for sns
  $nostr = !private_key.empty?
  $bsky = !bsky_username.empty?
  require 'nostr_ruby' if $nostr
  require 'bskyrb' if $bsky

  # ---------------
  # load Data
  before_json = File.read(cachefile)
  latest_json = URI.open($URL_BASE % jsonfile, :ssl_verify_mode => OpenSSL::SSL::VERIFY_NONE).read
  if before_json == latest_json
    logger.info('not modified.(same json)')
    next
  end
  before = JSON.load(before_json)['channel']['item']
  latest = JSON.load(latest_json)['channel']['item']
  before_data = JSON.load(File.read(cachedata))
  latest_data = JSON.load('{ "history": {}, "last_post": "" }')

  # ---------------
  # correct before data
  before_sts = Hash.new() {|hash, key| hash[key] = ''}
  before_msg = Hash.new() {|hash, key| hash[key] = ''}
  before.each do |item|
    next if match_any?(item, ignore)
    pk = make_pk(item)
    before_sts[pk] = item['status']
    before_msg[pk] = item['textShort']
  end

  # ---------------
  # make massage
  is_all_clear = true
  lines = []
  sorted = latest.sort { |a, b|
    $STS[b['status']].level <=> $STS[a['status']].level ||
    to_timestamp(b['pubDate']) <=> to_timestamp(a['pubDate']) ||
    b['trainLineCode'] <=> a['trainLineCode']
  }
  sorted.each do |item|
    next if match_any?(item, ignore)
    infoId = item['infoId']
    if before_data['history'].has_key?(infoId)
      timestamp = before_data['history'][infoId]
      latest_data['history'][infoId] = timestamp
      interval = $NOW - Time.parse(timestamp)
      if ignore_days != 0 && ignore_days_sec < interval
        logger.debug("skip infoId #=> #{infoId}, interval #=> #{interval}sec")
        next
      end
    else
      latest_data['history'][infoId] = $NOW
    end

    status = item['status'].dup
    if status != $STS_NORMAL
      is_all_clear = false
    end

    pk = make_pk(item)
    next if status == $STS_NORMAL && before_sts[pk] == $STS_NORMAL
    next if status == $STS_RECOVER && before_sts[pk] == $STS_RECOVER

    text = item['textShort'].dup
    is_upd = text != before_msg[pk]

    shortened = false
    if status == $STS_NORMAL || status == $STS_RECOVER
      text = status.dup
      shortened = true
    elsif status == $STS_SUSPEND
      # The suspended section is important.
    elsif !is_upd
      if status == $STS_DELAY
        text = status.dup
        shortened = true
      elsif text.include?('ダイヤが乱れています。')
        text = 'ダイヤ乱れ'
        shortened = true
      else
        text.sub!(/^[^。]+影響(など)?で、/, '')
      end
    end
    if !shortened
      if !item['cause'].empty?
        text.sub!(/^[^。]+影響(など)?で、/, "(#{item['cause']})")
      end
      text.sub!(/^#{item['trainLine']}は、/, '')
      text.gsub!(/が出ています。/, '。')
      text.gsub!(/となっています。/, '。')
      text.gsub!(/。(なお|また)、/, '。')
      text.gsub!(/運転しています。/, '運転。')
      text.gsub!(/再開しました。/, '再開。')
      text.gsub!(/を見合わせています。/, '見合わせ。')
      text.gsub!(/を中止しています。/, '中止。')
      text.sub!(/^([^。]*)。$/, '\1')
    end

    trainLine = item['trainLine2'].empty?() ? item['trainLine'] : item['trainLine2']
    line = "#{$STS[status].sign}#{trainLine}：#{text}"
    lines << line
  end

  if is_all_clear
    lines = [$ALL_CLEAR]
  elsif lines.empty?
    logger.info('empty.')
    next
  end
  lines = trancate(lines, $MAX_ROWS)
  lines << link_url
  lines.flatten!
  msg = lines.join("\n")
  if msg == before_data['last_post'] || lines.sort == before_data['last_post'].split("\n").sort
    logger.info('not modified.(same message)')
    next
  end

  # ---------------
  # post
  logger.info("post\n" + msg)
  if $test
    puts msg
  end
  if !$test && $bsky
    credentials = Bskyrb::Credentials.new(bsky_username, bsky_password)
    session = Bskyrb::Session.new(credentials, 'https://bsky.social')
    bsky = Bskyrb::RecordManager.new(session)
    post = bsky.create_post(msg)
    logger.debug("#{bsky_username} #{post}")
  end
  if !$test && $nostr
    n = Nostr.new({ private_key: private_key })
    event = n.build_note_event(msg)
    Parallel.each(config['relay']) { |relay|
      begin
        Timeout.timeout(config['timeout']) {
          # nostr-ruby/lib/nostr_ruby.rb#test_post
          response = nil
          ws = WebSocket::Client::Simple.connect relay
          ws.on :message do |msg|
            response = JSON.parse(msg.data)
            logger.log(
              response[0] == 'OK' ? Logger::DEBUG : Logger::WARN,
              "#{relay} #{msg.to_s}"
            )
            ws.close
          end
          ws.on :open do
            ws.send event.to_json
          end
          while response.nil? do
            sleep 0.1
          end
        }
      rescue Timeout::Error
        logger.warn("#{relay} Timeout")
      rescue Exception => e
        logger.error("#{relay} #{e.message}")
        logger.debug(e)
      end
    }
  end

  # ---------------
  # save cache
  File.open(cachefile.sub(/\.json$/,'.old.json'), mode = 'w') { |f|
    f.write(before_json)
  }
  File.open(cachefile, mode = 'w') { |f|
    f.write(latest_json)
  }
  File.open(cachedata, mode = 'w') { |f|
    latest_data["last_post"] = msg
    f.write(JSON.pretty_generate(latest_data))
  }

end

logger.info('end')

