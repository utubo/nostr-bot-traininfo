#!/usr/local/bin/ruby

# --------------------------------
# Environment
$nostr = true
#$bsky = true # you can set true to post to nostr.
$bsky = true
#$bsky = true # you can set true to post to bluesky.
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
require 'nostr_ruby' if $nostr
require 'bskyrb' if $bsky

# --------------------------------
# Constants
logger = Logger.new("#{__dir__}/log.log", 3)
$URL_BASE = "https://www3.nhk.or.jp/n-data/traffic/train/%s?_=#{Time.now.to_i}"
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
$ALL_CLEAR = "🟢現在、見合わせ・遅延などの情報はありません🚃🎶"
$UPDATES = '🆙更新'
$NO_UPDATES = '🕒現状維持'
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
  logger.info(jsonfile)

  datadir = "#{__dir__}/data"
  cachefile = "#{datadir}/#{jsonfile}"
  cachetext = "#{datadir}/#{jsonfile}".sub(/\.json$/, '.txt')
  mkdir Dir.mkdir(datadir) if ! File.directory?(datadir)
  if !File.file?(cachefile)
    File.open(cachefile, mode = 'w') { |f|
      f.write('{ "channel": { "item": [] } }')
    }
  end
  if !File.file?(cachetext)
    File.open(cachetext, mode = 'w') { |f|
      f.write('')
    }
  end

  # ---------------
  # load Data
  before_json = File.read(cachefile)
  latest_json = URI.open($URL_BASE % jsonfile, :ssl_verify_mode => OpenSSL::SSL::VERIFY_NONE).read
  if before_json == latest_json
    logger.info('not modified.')
    next
  end
  before = JSON.load(before_json)['channel']['item']
  latest = JSON.load(latest_json)['channel']['item']

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
  updates = []
  no_updates = []
  is_all_clear = true
  text_long = ''
  sorted = latest.sort { |a, b| $STS[b['status']].level <=> $STS[a['status']].level }
  sorted.each do |item|
    next if match_any?(item, ignore)

    status = item['status'].dup
    if status != $STS_NORMAL
      is_all_clear = false
    end

    pk = make_pk(item)
    next if status == $STS_NORMAL && before_sts[pk] == $STS_NORMAL
    next if status == $STS_RECOVER && before_sts[pk] == $STS_RECOVER

    text = item['textShort'].dup
    no_upd = text == before_msg[pk]

    shortened = false
    if status == $STS_NORMAL || status == $STS_RECOVER
      text = status.dup
      shortened = true
    elsif status == $STS_SUSPEND
      # The suspended section is important.
    elsif no_upd
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
      text.sub!(/。$/, '') if no_upd
    end

    line = "#{$STS[status].sign}#{item['trainLine']}：#{text}"
    if no_upd
      no_updates << line
    else
      updates << line
      text_long = "#{$STS[status].sign}#{item['trainLine']}：#{item['textLong']}"
    end
  end

  lines = []
  if is_all_clear
    lines << $ALL_CLEAR
  else
    if updates.length == 0
      logger.info('not modified.')
      next
    elsif updates.length == 1
      lines << $UPDATES
      lines << text_long
    else
      lines << $UPDATES
      lines << trancate(updates, $MAX_ROWS)
    end
    if no_updates.length != 0
      lines << $NO_UPDATES
      lines << trancate(no_updates, $MAX_ROWS)
    end
  end

  lines << link_url
  msg = lines.flatten.join("\n")

  if msg == File.read(cachetext, encoding: Encoding::UTF_8)
    logger.info('not modified.')
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
  File.open(cachetext, mode = 'w:UTF-8') { |f|
    f.write(msg)
  }

end

logger.info('end')

