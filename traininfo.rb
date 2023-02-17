#!/usr/local/bin/ruby

# --------------------------------
# Environment
$test = false
#$test = true # you can set true to stdout insted of post.

# --------------------------------
# Requires

require 'logger'
require 'nostr_ruby'
require 'open-uri'
require 'json'
require 'timeout'
require 'parallel'

# --------------------------------
# Constants
logger = Logger.new("#{__dir__}/log.log", 3)
$URL_BASE = "https://www3.nhk.or.jp/n-data/traffic/train/_JSON_?_=#{Time.now.to_i}"
$MAX_ROWS = 10
$STS_NORMAL = '平常運転'
$STS_SIGN = Hash.new {|hash, key| hash[key] = '🟡'}
$STS_SIGN['平常運転'] = '🟢'
$STS_SIGN['運転再開'] = '🟢'
$STS_SIGN['運転見合わせ'] = '🔴'
$ALL_CLEAR = "#{$STS_SIGN['平常運転']}現在、見合わせ・遅延などの情報はありません。"
$UPDATES = '🆙情報更新'
$NO_UPDATES = '🕒更新なし'
$OVERFLOW = '...他_n_件'

# --------------------------------
# Utils
def make_pk(item)
  item['companyCode'] + '-' + item['trainLineCode']
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
  jsonfile = conf['jsonfile']
  link_url = conf['url']
  logger.info(jsonfile)

  datadir = "#{__dir__}/data"
  cachefile = "#{datadir}/#{jsonfile}"
  mkdir Dir.mkdir(datadir) if ! File.directory?(datadir)
  if !File.file?(cachefile)
    File.open(cachefile, mode = 'w') { |f|
      f.write('{ "channel": { "item": [] } }')
    }
  end

  # ---------------
  # load Data
  before_json = File.read(cachefile)
  latest_json = URI.open($URL_BASE.sub('_JSON_', jsonfile)).read
  if before_json == latest_json
    logger.info('is not modified.')
    next
  end
  before = JSON.load(before_json)['channel']['item']
  latest = JSON.load(latest_json)['channel']['item']

  # ---------------
  # correct before data
  before_sts = Hash.new() {|hash, key| hash[key] = ''}
  before_msg = Hash.new() {|hash, key| hash[key] = ''}
  before.each do |item|
    pk = make_pk(item)
    before_sts[pk] = item['status']
    before_msg[pk] = item['textShort']
  end

  # ---------------
  # make massage
  updates = []
  no_updates = []
  latest.each do |item|
    pk = make_pk(item)
    status = item['status'].dup
    next if status == $STS_NORMAL && before_sts[pk] == $STS_NORMAL

    text = item['textShort'].dup
    no_upd = text == before_msg[pk]

    shortened = false
    if status == '運転見合わせ'
      # The suspended section is important.
    elsif no_upd || status == $STS_NORMAL || status == '運転再開'
      disarray = text.include?('ダイヤが乱れています。')
      if status == '運転状況' || status == '交通障害情報'
        if disarray
          text = 'ダイヤ乱れ'
          shortened = true
        else
          text.sub!(/^[^。]+影響で、/, '')
        end
      else
        text = status.dup
        text << '(ダイヤ乱れあり)' if disarray
        shortened = true
      end
    end
    if !shortened
      if !item['cause'].empty?
        text.sub!(/^[^。]+影響で、/, "(#{item['cause']})")
      end
      text.sub!(/^#{item['trainLine']}は、/, '')
      text.gsub!(/が出ています。/, '。')
      text.gsub!(/となっています。/, '。')
      text.gsub!(/見合わせています。/, '見合わせ。')
      text.gsub!(/運転しています。/, '運転。')
      text.gsub!(/再開しました。/, '再開。')
      text.sub!(/。$/, '') if no_upd
    end

    line = "#{$STS_SIGN[status]}#{item['trainLine']}：#{text}"
    if no_upd
      no_updates << line
    else
      updates << line
    end
  end

  lines = []
  if before.length == latest.length && updates.length == 0
    # 'LastBuildDate' is changed only.
    logger.info('not modified.')
    next
  elsif latest.length == 0
    lines << $ALL_CLEAR
  elsif updates.length != 0
    lines << $UPDATES
    lines << updates.first($MAX_ROWS)
    overflow = updates.length - $MAX_ROWS
    lines << $OVERFLOW.sub('_n_', overflow) if 0 < overflow
  end
  if no_updates.length != 0
    lines << $NO_UPDATES
    lines << no_updates
    overflow = no_updates.length - $MAX_ROWS
    lines << $OVERFLOW.sub('_n_', overflow) if 0 < overflow
  end
  lines << link_url if ! lines.empty?
  msg = lines.flatten.join("\n")
  logger.info(msg)

  # ---------------
  # post
  if $test
    puts msg
  else
    n = Nostr.new({ private_key: private_key })
    event = n.build_note_event(msg)
    Parallel.each(config['relay']) { |relay|
      begin
        Timeout.timeout(config['timeout']) {
          # nostr-ruby/lib/nostr_ruby.rb#test_post
          response = nil
          ws = WebSocket::Client::Simple.connect relay
          ws.on :message do |msg|
            logger.debug("#{relay} #{msg.to_s}")
            response = JSON.parse(msg.data)
            ws.close
          end
          ws.on :open do
            ws.send event.to_json
          end
          while response.nil? do
            sleep 0.1
          end
          response[0] == 'OK'
        }
      rescue Timeout::Error
        logger.warn("#{relay} Timeout")
      rescue => e
        logger.error("#{relay} #{e.to_s}")
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

end

logger.info('end')

