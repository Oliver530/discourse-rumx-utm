# Live validation of plugin.rb against the running Discourse — run this after
# every plugin change (before /admin/upgrade, pointing at the new file) and
# after every Discourse core upgrade (pointing at the deployed file), because
# TopicLinkClickExtension prepends a core model method that core may change.
#
#   scp plugin.rb root@<droplet>:/tmp/plugin_new.rb
#   scp script/validate_live.rb root@<droplet>:/tmp/validate_live.rb
#   ssh root@<droplet> 'docker cp /tmp/plugin_new.rb app:/tmp/plugin_new.rb;
#     docker cp /tmp/validate_live.rb app:/tmp/validate_live.rb;
#     docker exec app bash -c "cd /var/www/discourse && su discourse -c \
#       \"bundle exec rails runner -e production /tmp/validate_live.rb\""'
#
# PLUGIN_RB=/var/www/discourse/plugins/discourse-rumx-utm/plugin.rb validates
# the deployed file instead. Exit 0 = all checks passed.
#
# Loads the plugin body into THIS rails-runner process only (the unicorn
# workers are untouched), stubs `on(...)` so the event handlers can be invoked
# directly, and touches the DB only inside one transaction that is rolled
# back. Expect "already initialized constant" warnings: the module is reopened.
plugin_path = ENV.fetch("PLUGIN_RB", "/tmp/plugin_new.rb")
src = File.read(plugin_path)
body = src[/after_initialize do\n(.*)\nend\s*\z/m, 1] or raise "could not extract after_initialize body"
handlers = {}
ctx = Object.new
ctx.define_singleton_method(:on) { |evt, &blk| handlers[evt] = blk }
ctx.instance_eval(body, plugin_path, 8)

fails = 0
check = ->(name, cond, extra = nil) {
  puts "#{cond ? 'PASS' : 'FAIL'}  #{name}#{extra ? "  -> #{extra}" : ''}"
  fails += 1 unless cond
}


check.("handlers registered: post_process_cooked + post_process_localized_cooked",
       handlers.key?(:post_process_cooked) && handlers.key?(:post_process_localized_cooked), handlers.keys.inspect)

# ---------- 1. fresh cook: linkify + UTM + Market Radar preservation ----------
html = <<~HTML
  <p>Für mich war der RX7295 etwas besser als rx43.</p>
  <p><a href="https://www.amazon.de/dp/B000?tag=rumx-21">Amazon</a></p>
  <p><a href="https://rumx.com/de/rums/43/?utm_source=forum&amp;utm_medium=post&amp;utm_campaign=market_radar&amp;utm_content=RX43">Smith &amp; Cross</a></p>
  <p><a href="https://rumx.com/en/rums/22143/?utm_content=RX22143">Foursquare</a></p>
  <p><a href="https://rumx.com/en/rums/9198/">typed clean rumx link</a></p>
  <p><a href="https://www.rumx.com/best-rums">www no slash</a></p>
  <aside class="quote"><blockquote>quoted RX368 must not link</blockquote></aside>
HTML
doc = Loofah.html5_fragment(html)
handlers[:post_process_cooked].call(doc, nil)
out = doc.to_html
check.("RX7295 linkified clean /en/", out.include?('<a href="https://rumx.com/en/rums/7295/">RX7295</a>'))
check.("rx43 (lowercase) linkified", out.include?('<a href="https://rumx.com/en/rums/43/">rx43</a>'))
check.("RX368 inside aside.quote NOT linkified", !out.include?('rums/368/'))
amz = doc.css("a").find { |a| a["href"].include?("amazon") }["href"]
check.("amazon link gets forum UTM", amz.include?("utm_source=rumx") && amz.include?("utm_campaign=rumx-forum") && amz.include?("tag=rumx-21"), amz)
mr = doc.css("a").find { |a| a["href"].include?("rums/43/") && a["href"].include?("utm") }["href"]
check.("Market Radar UTM PRESERVED (campaign=market_radar, source=forum)",
       mr.include?("utm_campaign=market_radar") && mr.include?("utm_source=forum") && mr.include?("utm_medium=post") && mr.include?("utm_content=RX43"), mr)
fq = doc.css("a").find { |a| a["href"].include?("rums/22143/") }["href"]
check.("rumx link with only utm_content: forum defaults FILLED, content kept",
       fq.include?("utm_content=RX22143") && fq.include?("utm_source=rumx") && fq.include?("utm_campaign=rumx-forum"), fq)
tc = doc.css("a").find { |a| a["href"].start_with?("https://rumx.com/en/rums/9198/") }["href"]
check.("author-typed CLEAN rumx RX-shaped link is left untouched (no UTM)", tc == "https://rumx.com/en/rums/9198/", tc)
ww = doc.css("a").find { |a| a["href"].include?("best-rums") }["href"]
check.("www + missing slash canonicalized and UTM'd", ww.start_with?("https://rumx.com/best-rums/?"), ww)

# ---------- 2. idempotence: re-run both passes on the ALREADY processed doc ----------
before = doc.to_html
handlers[:post_process_localized_cooked].call(doc, nil, nil)
after = doc.to_html
check.("second pass is a no-op (RX anchors stay clean, no nested anchors, no double UTM)", before == after)
check.("no nested anchors", doc.css("a a").empty?)

# ---------- 3. localized handler on a fresh doc ----------
ldoc = Loofah.html5_fragment("<p>Übersetzt: RX5934 und RX368.</p>")
handlers[:post_process_localized_cooked].call(ldoc, nil, nil)
check.("localized handler linkifies", ldoc.css("a").map { |a| a["href"] } == ["https://rumx.com/en/rums/5934/", "https://rumx.com/en/rums/368/"], ldoc.to_html)

# ---------- 4. TopicLinkClick prepend ----------
check.("TopicLinkClick prepended", ::TopicLinkClick.singleton_class.ancestors.include?(::DiscourseRUMXUTM::TopicLinkClickExtension))
tl = TopicLink.where("url ~ ?", '^https://rumx\.com/en/rums/[0-9]+/$').where.not(post_id: nil).order(id: :desc).first
rx_id = tl.url[%r{/rums/(\d+)/}, 1]
post = tl.post
puts "  using topic_link #{tl.id} post #{tl.post_id} topic #{tl.topic_id} url #{tl.url} (author user #{post.user_id})"
ip = "203.0.113.#{rand(2..250)}"
rkey = "link-clicks:#{tl.id}:#{ip}"
Discourse.redis.del(rkey)
created = nil
ActiveRecord::Base.transaction do
  n0 = TopicLinkClick.where(topic_link_id: tl.id).count
  ret = TopicLinkClick.create_from(url: "https://rumx.com/de/rums/#{rx_id}/", post_id: tl.post_id.to_s, topic_id: tl.topic_id.to_s, ip: ip, user_id: nil, guardian: Guardian.new)
  n1 = TopicLinkClick.where(topic_link_id: tl.id).count
  created = (n1 == n0 + 1)
  check.("/de/ click counted against the /en/ TopicLink (anon, fresh ip)", created, "return=#{ret.inspect} before=#{n0} after=#{n1}")
  # author-typed exact /de/ link present in the post -> must NOT be normalized away
  own = TopicLink.create!(topic_id: tl.topic_id, post_id: tl.post_id, user_id: post.user_id, domain: "rumx.com", url: "https://rumx.com/fr/rums/#{rx_id}/", internal: false, link_topic_id: nil, reflection: false, clicks: 0, title: nil, crawled_at: nil, quote: false, extension: nil)
  ip2 = "203.0.113.#{rand(2..250)}"
  Discourse.redis.del("link-clicks:#{own.id}:#{ip2}")
  TopicLinkClick.create_from(url: "https://rumx.com/fr/rums/#{rx_id}/", post_id: tl.post_id.to_s, topic_id: tl.topic_id.to_s, ip: ip2, user_id: nil, guardian: Guardian.new)
  check.("exact /fr/ TopicLink in the post wins over normalization", TopicLinkClick.where(topic_link_id: own.id).count == 1)
  Discourse.redis.del("link-clicks:#{own.id}:#{ip2}")
  raise ActiveRecord::Rollback
end
Discourse.redis.del(rkey)
check.("transaction rolled back (no new click rows persisted)", TopicLinkClick.where(topic_link_id: tl.id, ip_address: ip).count == 0)
# pass-through: non-matching URL must not raise
begin
  TopicLinkClick.create_from(url: "https://rumx.com/de/rums/#{rx_id}/?utm_source=x", post_id: tl.post_id.to_s, topic_id: tl.topic_id.to_s, ip: "203.0.113.1", user_id: nil, guardian: Guardian.new)
  TopicLinkClick.create_from(url: "https://example.org/x", post_id: tl.post_id.to_s, topic_id: tl.topic_id.to_s, ip: "203.0.113.1", user_id: nil, guardian: Guardian.new)
  check.("non-matching urls pass through without raising", true)
rescue => e
  check.("non-matching / malformed urls pass through without raising", false, "#{e.class}: #{e.message}")
end

puts
puts(fails.zero? ? "ALL CHECKS PASSED" : "#{fails} CHECK(S) FAILED")
exit(fails.zero? ? 0 : 1)
